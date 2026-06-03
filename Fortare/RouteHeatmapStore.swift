//
//  RouteHeatmapStore.swift
//  Fortare
//
//  Created by Rasmus Sten on 3.6.2026.
//

import Combine
import CoreLocation
import Foundation
import HealthKit
import MapKit

@MainActor
final class RouteHeatmapStore: ObservableObject {
    @Published private(set) var overlay: TrafficOverlay?
    @Published private(set) var routeCount = 0
    @Published private(set) var totalDistance: CLLocationDistance = 0
    @Published private(set) var isLoading = false
    @Published private(set) var importProgress = 0.0
    @Published private(set) var statusText = "Import bicycle workouts from Apple Health to paint every ridden route into one animated heat overlay."

    private let importer = HealthRouteImporter()

    var distanceText: String {
        let kilometers = totalDistance / 1_000
        return kilometers >= 100 ? "\(Int(kilometers.rounded()))" : String(format: "%.1f", kilometers)
    }

    func loadRoutes(window: ImportWindow = .default) async {
        guard !isLoading else { return }

        isLoading = true
        importProgress = 0
        statusText = "Requesting Health access..."

        do {
            let routes = try await importer.loadCyclingRoutes(since: window.startDate) { [weak self] completed, total in
                guard let self else { return }
                importProgress = total == 0 ? 0 : Double(completed) / Double(total)
                statusText = total == 0 ? "Scanning \(window.title.lowercased())..." : "Importing \(completed) of \(total) rides..."
            }
            let result = RouteHeatmapBuilder.makeOverlay(from: routes)
            overlay = result.overlay
            routeCount = routes.count
            totalDistance = result.distance
            importProgress = 1
            statusText = routes.isEmpty
                ? "No outdoor cycling routes were found in Apple Health for \(window.title.lowercased())."
                : "\(routes.count) route\(routes.count == 1 ? "" : "s") loaded."
        } catch {
            statusText = error.localizedDescription
        }

        isLoading = false
    }
}

struct ImportWindow: Equatable {
    let title: String
    let days: Int?

    nonisolated static let presets: [ImportWindow] = [
        ImportWindow(title: "Today", days: 0),
        ImportWindow(title: "1 day", days: 1),
        ImportWindow(title: "2 days", days: 2),
        ImportWindow(title: "7 days", days: 7),
        ImportWindow(title: "14 days", days: 14),
        ImportWindow(title: "30 days", days: 30),
        ImportWindow(title: "90 days", days: 90),
        ImportWindow(title: "180 days", days: 180),
        ImportWindow(title: "1 year", days: 365),
        ImportWindow(title: "2 years", days: 730),
        ImportWindow(title: "All time", days: nil)
    ]

    nonisolated static let `default` = ImportWindow(title: "14 days", days: 14)

    var startDate: Date? {
        guard let days else { return nil }

        if days == 0 {
            return Calendar.current.startOfDay(for: .now)
        }

        return Calendar.current.date(byAdding: .day, value: -days, to: .now)
    }
}

final class HealthRouteImporter {
    private let healthStore = HKHealthStore()

    func loadCyclingRoutes(
        since startDate: Date?,
        progress: @escaping @MainActor (_ completed: Int, _ total: Int) -> Void
    ) async throws -> [[CLLocationCoordinate2D]] {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw RouteImportError.healthUnavailable
        }

        try await requestAuthorization()
        let workouts = try await cyclingWorkouts(since: startDate)
        var allRoutes: [[CLLocationCoordinate2D]] = []

        progress(0, workouts.count)

        for (index, workout) in workouts.enumerated() {
            let routes = try await workoutRoutes(for: workout)
            for route in routes {
                let locations = try await locations(for: route)
                let coordinates = simplified(locations.map(\.coordinate))
                if coordinates.count > 1 {
                    allRoutes.append(coordinates)
                }
            }

            progress(index + 1, workouts.count)
        }

        return allRoutes
    }

    private func requestAuthorization() async throws {
        let readTypes: Set<HKObjectType> = [
            HKObjectType.workoutType(),
            HKSeriesType.workoutRoute()
        ]

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            healthStore.requestAuthorization(toShare: [], read: readTypes) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: RouteImportError.authorizationDenied)
                }
            }
        }
    }

    private func cyclingWorkouts(since startDate: Date?) async throws -> [HKWorkout] {
        try await withCheckedThrowingContinuation { continuation in
            var predicates = [HKQuery.predicateForWorkouts(with: .cycling)]
            if let startDate {
                predicates.append(HKQuery.predicateForSamples(withStart: startDate, end: nil, options: .strictEndDate))
            }

            let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
            let query = HKSampleQuery(
                sampleType: .workoutType(),
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sort]
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: samples as? [HKWorkout] ?? [])
                }
            }

            healthStore.execute(query)
        }
    }

    private func workoutRoutes(for workout: HKWorkout) async throws -> [HKWorkoutRoute] {
        try await withCheckedThrowingContinuation { continuation in
            let predicate = HKQuery.predicateForObjects(from: workout)
            let query = HKSampleQuery(
                sampleType: HKSeriesType.workoutRoute(),
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: samples as? [HKWorkoutRoute] ?? [])
                }
            }

            healthStore.execute(query)
        }
    }

    private func locations(for route: HKWorkoutRoute) async throws -> [CLLocation] {
        try await withCheckedThrowingContinuation { continuation in
            var collected: [CLLocation] = []
            let query = HKWorkoutRouteQuery(route: route) { _, locations, done, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                collected.append(contentsOf: locations ?? [])

                if done {
                    continuation.resume(returning: collected)
                }
            }

            healthStore.execute(query)
        }
    }

    private func simplified(_ coordinates: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
        var result: [CLLocationCoordinate2D] = []
        var previous: CLLocation?

        for coordinate in coordinates where CLLocationCoordinate2DIsValid(coordinate) {
            let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            if previous == nil || location.distance(from: previous!) > 10 {
                result.append(coordinate)
                previous = location
            }
        }

        return result
    }
}

enum RouteImportError: LocalizedError {
    case authorizationDenied
    case healthUnavailable

    var errorDescription: String? {
        switch self {
        case .authorizationDenied:
            "Apple Health access was not granted. Enable workout route access in Settings to import bicycle routes."
        case .healthUnavailable:
            "Apple Health data is not available on this device."
        }
    }
}

struct RouteHeatmapBuilder {
    private static let snapDistance = 10.0

    static func makeOverlay(from routes: [[CLLocationCoordinate2D]]) -> (overlay: TrafficOverlay?, distance: CLLocationDistance) {
        var segmentKeys: [String] = []
        for route in routes {
            segmentKeys.append(contentsOf: routeSegmentKeys(snappedRoute(route)))
        }

        let counts = Dictionary(grouping: segmentKeys, by: { $0 }).mapValues(\.count)
        let normalizationCount = percentile(Array(counts.values), percentile: 0.92)
        var segments: [TrafficSegment] = []
        var totalDistance: CLLocationDistance = 0

        for route in routes {
            let snapped = snappedRoute(route)
            for pair in zip(snapped, snapped.dropFirst()) {
                guard pair.0.latitude != pair.1.latitude || pair.0.longitude != pair.1.longitude else { continue }

                let distance = CLLocation(latitude: pair.0.latitude, longitude: pair.0.longitude)
                    .distance(from: CLLocation(latitude: pair.1.latitude, longitude: pair.1.longitude))
                guard distance > 0, distance < 2_000 else { continue }

                let rawCount = counts[segmentKey(pair.0, pair.1)] ?? 1
                let weight = min(1, Double(rawCount) / Double(normalizationCount))
                segments.append(
                    TrafficSegment(
                        start: MKMapPoint(pair.0),
                        end: MKMapPoint(pair.1),
                        intensity: weight
                    )
                )
                totalDistance += distance
            }
        }

        guard !segments.isEmpty else {
            return (nil, 0)
        }

        return (TrafficOverlay(segments: segments), totalDistance)
    }

    private static func snappedRoute(_ route: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
        var snapped: [CLLocationCoordinate2D] = []
        var lastKey: String?

        for coordinate in route {
            let point = snappedCoordinate(coordinate)
            let key = cellKey(point)

            if key != lastKey {
                snapped.append(point)
                lastKey = key
            }
        }

        return snapped
    }

    private static func routeSegmentKeys(_ route: [CLLocationCoordinate2D]) -> [String] {
        zip(route, route.dropFirst()).map { segmentKey($0.0, $0.1) }
    }

    private static func segmentKey(_ first: CLLocationCoordinate2D, _ second: CLLocationCoordinate2D) -> String {
        let firstCell = cellKey(first)
        let secondCell = cellKey(second)
        return firstCell < secondCell ? "\(firstCell)-\(secondCell)" : "\(secondCell)-\(firstCell)"
    }

    private static func cellKey(_ coordinate: CLLocationCoordinate2D) -> String {
        let latitude = Int((coordinate.latitude * 111_320 / snapDistance).rounded())
        let longitudeScale = max(cos(coordinate.latitude * .pi / 180), 0.15)
        let longitude = Int((coordinate.longitude * 111_320 * longitudeScale / snapDistance).rounded())
        return "\(latitude):\(longitude)"
    }

    private static func snappedCoordinate(_ coordinate: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        let latitudeUnits = (coordinate.latitude * 111_320 / snapDistance).rounded()
        let snappedLatitude = latitudeUnits * snapDistance / 111_320
        let longitudeScale = max(cos(snappedLatitude * .pi / 180), 0.15)
        let longitudeUnits = (coordinate.longitude * 111_320 * longitudeScale / snapDistance).rounded()
        let snappedLongitude = longitudeUnits * snapDistance / (111_320 * longitudeScale)

        return CLLocationCoordinate2D(latitude: snappedLatitude, longitude: snappedLongitude)
    }

    private static func percentile(_ values: [Int], percentile: Double) -> Int {
        guard !values.isEmpty else { return 1 }

        let sorted = values.sorted()
        let index = min(sorted.count - 1, max(0, Int(Double(sorted.count - 1) * percentile)))
        return max(sorted[index], 1)
    }
}
