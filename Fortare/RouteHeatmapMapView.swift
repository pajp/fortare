//
//  RouteHeatmapMapView.swift
//  Fortare
//
//  Created by Rasmus Sten on 3.6.2026.
//

import MapKit
import SwiftUI

struct RouteHeatmapMapView: UIViewRepresentable {
    let overlay: TrafficOverlay?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView(frame: .zero)
        mapView.delegate = context.coordinator
        mapView.pointOfInterestFilter = .excludingAll
        mapView.showsCompass = false
        mapView.showsScale = false
        mapView.showsUserLocation = false
        mapView.isPitchEnabled = false
        mapView.cameraZoomRange = MKMapView.CameraZoomRange(minCenterCoordinateDistance: 450)

        let configuration = MKStandardMapConfiguration(elevationStyle: .flat)
        configuration.emphasisStyle = .muted
        configuration.pointOfInterestFilter = .excludingAll
        mapView.preferredConfiguration = configuration

        context.coordinator.install(overlay, on: mapView)
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        context.coordinator.install(overlay, on: mapView)
    }

    static func dismantleUIView(_ uiView: MKMapView, coordinator: Coordinator) {
        coordinator.clear(from: uiView)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        private var activeOverlay: TrafficOverlay?
        private var activeRenderer: TrafficOverlayRenderer?

        func install(_ overlay: TrafficOverlay?, on mapView: MKMapView) {
            guard activeOverlay !== overlay else { return }
            clear(from: mapView)

            guard let overlay else {
                activeOverlay = nil
                return
            }

            activeOverlay = overlay
            mapView.addOverlay(overlay, level: .aboveRoads)
            mapView.setVisibleMapRect(
                overlay.boundingMapRect,
                edgePadding: UIEdgeInsets(top: 110, left: 38, bottom: 190, right: 38),
                animated: true
            )
        }

        func clear(from mapView: MKMapView) {
            if let activeOverlay {
                mapView.removeOverlay(activeOverlay)
            }
            activeOverlay = nil
            activeRenderer = nil
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let trafficOverlay = overlay as? TrafficOverlay else {
                return MKOverlayRenderer(overlay: overlay)
            }

            let renderer = TrafficOverlayRenderer(overlay: trafficOverlay)
            activeRenderer = renderer
            return renderer
        }
    }
}

struct TrafficSegment {
    let start: MKMapPoint
    let end: MKMapPoint
    let intensity: Double
    let boundingMapRect: MKMapRect

    init(start: MKMapPoint, end: MKMapPoint, intensity: Double) {
        self.start = start
        self.end = end
        self.intensity = intensity
        boundingMapRect = MKMapRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: max(abs(start.x - end.x), 1),
            height: max(abs(start.y - end.y), 1)
        )
        .insetBy(dx: -1_000, dy: -1_000)
    }
}

final class TrafficOverlay: NSObject, MKOverlay {
    let segments: [TrafficSegment]
    let boundingMapRect: MKMapRect
    let coordinate: CLLocationCoordinate2D

    private let tileSize: Double = 65_536
    private let tileIndex: [TileKey: [Int]]

    init(segments: [TrafficSegment]) {
        self.segments = segments

        var rect = MKMapRect.null
        var index: [TileKey: [Int]] = [:]

        for (segmentIndex, segment) in segments.enumerated() {
            rect = rect.union(segment.boundingMapRect)

            let minTileX = Int(floor(segment.boundingMapRect.minX / tileSize))
            let maxTileX = Int(floor(segment.boundingMapRect.maxX / tileSize))
            let minTileY = Int(floor(segment.boundingMapRect.minY / tileSize))
            let maxTileY = Int(floor(segment.boundingMapRect.maxY / tileSize))

            for x in minTileX...maxTileX {
                for y in minTileY...maxTileY {
                    index[TileKey(x: x, y: y), default: []].append(segmentIndex)
                }
            }
        }

        if rect.isNull {
            rect = MKMapRect.world
        }

        tileIndex = index
        let insetX = max(rect.width * 0.08, 800)
        let insetY = max(rect.height * 0.08, 800)
        boundingMapRect = rect.insetBy(dx: -insetX, dy: -insetY)
        coordinate = MKMapPoint(x: boundingMapRect.midX, y: boundingMapRect.midY).coordinate
    }

    func visibleSegments(in mapRect: MKMapRect) -> [TrafficSegment] {
        let expanded = mapRect.insetBy(dx: -2_000, dy: -2_000)
        let minTileX = Int(floor(expanded.minX / tileSize))
        let maxTileX = Int(floor(expanded.maxX / tileSize))
        let minTileY = Int(floor(expanded.minY / tileSize))
        let maxTileY = Int(floor(expanded.maxY / tileSize))
        var seen = Set<Int>()
        var visible: [TrafficSegment] = []

        for x in minTileX...maxTileX {
            for y in minTileY...maxTileY {
                guard let segmentIndexes = tileIndex[TileKey(x: x, y: y)] else { continue }

                for index in segmentIndexes where !seen.contains(index) {
                    let segment = segments[index]
                    if expanded.intersects(segment.boundingMapRect) {
                        visible.append(segment)
                        seen.insert(index)
                    }
                }
            }
        }

        return visible
    }
}

private struct TileKey: Hashable {
    let x: Int
    let y: Int
}

final class TrafficOverlayRenderer: MKOverlayRenderer {
    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard let overlay = overlay as? TrafficOverlay else { return }

        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setShouldAntialias(true)
        context.setBlendMode(.normal)

        let visibleSegments = overlay.visibleSegments(in: mapRect)
        let samplingStride = max(1, Int(ceil(Double(visibleSegments.count) / 16_000.0)))

        for (index, segment) in visibleSegments.enumerated() where index.isMultiple(of: samplingStride) {
            let start = point(for: segment.start)
            let end = point(for: segment.end)
            let color = heatColor(segment.intensity, alpha: 0.72)
            let glowColor = heatColor(segment.intensity, alpha: 0.06)
            let roadWidth = MKRoadWidthAtZoomScale(zoomScale)
            let baseWidth = max(roadWidth * 0.38, 0.65 / zoomScale)
            let hotBoost = CGFloat(segment.intensity) * max(roadWidth * 0.52, 0.55 / zoomScale)

            strokeLine(from: start, to: end, width: (baseWidth + hotBoost) * 1.65, color: glowColor, in: context)
            strokeLine(from: start, to: end, width: baseWidth + hotBoost, color: color, in: context)
        }
    }

    private func strokeLine(from start: CGPoint, to end: CGPoint, width: CGFloat, color: UIColor, in context: CGContext) {
        context.beginPath()
        context.move(to: start)
        context.addLine(to: end)
        context.setLineWidth(width)
        context.setStrokeColor(color.cgColor)
        context.strokePath()
    }

    private func heatColor(_ value: Double, alpha: CGFloat) -> UIColor {
        let stops: [(CGFloat, UIColor)] = [
            (0.00, UIColor(red: 0.00, green: 0.19, blue: 1.00, alpha: alpha)),
            (0.28, UIColor(red: 0.00, green: 0.94, blue: 1.00, alpha: alpha)),
            (0.50, UIColor(red: 0.14, green: 1.00, blue: 0.33, alpha: alpha)),
            (0.72, UIColor(red: 1.00, green: 0.95, blue: 0.00, alpha: alpha)),
            (0.86, UIColor(red: 1.00, green: 0.43, blue: 0.00, alpha: alpha)),
            (1.00, UIColor(red: 1.00, green: 0.00, blue: 0.10, alpha: alpha))
        ]

        let clamped = CGFloat(min(max(value, 0), 1))
        guard let upperIndex = stops.firstIndex(where: { $0.0 >= clamped }) else {
            return stops.last!.1
        }

        if upperIndex == 0 {
            return stops[0].1
        }

        let lower = stops[upperIndex - 1]
        let upper = stops[upperIndex]
        let local = (clamped - lower.0) / max(upper.0 - lower.0, 0.001)
        return lower.1.blended(withFraction: local, of: upper.1) ?? upper.1
    }

}

private extension UIColor {
    func blended(withFraction fraction: CGFloat, of color: UIColor) -> UIColor? {
        var startRed: CGFloat = 0
        var startGreen: CGFloat = 0
        var startBlue: CGFloat = 0
        var startAlpha: CGFloat = 0
        var endRed: CGFloat = 0
        var endGreen: CGFloat = 0
        var endBlue: CGFloat = 0
        var endAlpha: CGFloat = 0

        guard getRed(&startRed, green: &startGreen, blue: &startBlue, alpha: &startAlpha),
              color.getRed(&endRed, green: &endGreen, blue: &endBlue, alpha: &endAlpha) else {
            return nil
        }

        let clamped = min(max(fraction, 0), 1)
        return UIColor(
            red: startRed + (endRed - startRed) * clamped,
            green: startGreen + (endGreen - startGreen) * clamped,
            blue: startBlue + (endBlue - startBlue) * clamped,
            alpha: startAlpha + (endAlpha - startAlpha) * clamped
        )
    }
}
