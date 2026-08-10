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
    @Published private(set) var daysWithSessions = 0
    @Published private(set) var isLoading = false
    @Published private(set) var importProgress = 0.0
    @Published private(set) var statusText = "Import bicycle workouts from Apple Health to paint every ridden route into one animated heat overlay."

    private let importer = HealthRouteImporter()

    var distanceText: String {
        let kilometers = totalDistance / 1_000
        return kilometers >= 100 ? "\(Int(kilometers.rounded()))" : String(format: "%.1f", kilometers)
    }

    var averageDistanceText: String {
        guard routeCount > 0 else { return "0.0" }

        let kilometers = totalDistance / Double(routeCount) / 1_000
        return kilometers >= 100 ? "\(Int(kilometers.rounded()))" : String(format: "%.1f", kilometers)
    }

    func loadRoutes(window: ImportWindow = .default, workoutMode: WorkoutImportMode = .biking) async {
        guard !isLoading else { return }

        isLoading = true
        importProgress = 0
        statusText = "Requesting Health access..."

        do {
            let routes = try await importer.loadRoutes(since: window.startDate, workoutMode: workoutMode) { [weak self] completed, total in
                guard let self else { return }
                importProgress = total == 0 ? 0 : Double(completed) / Double(total)
                statusText = total == 0 ? "Scanning \(window.title.lowercased())..." : "Importing \(completed) of \(total) \(workoutMode.progressName)..."
            }
            let result = RouteHeatmapBuilder.makeOverlay(from: routes)
            overlay = result.overlay
            routeCount = routes.count
            totalDistance = result.distance
            daysWithSessions = Set(routes.map { Calendar.current.startOfDay(for: $0.date) }).count
            importProgress = 1
            statusText = routes.isEmpty
                ? "No outdoor \(workoutMode.routeDescription) were found in Apple Health for \(window.title.lowercased())."
                : "\(routes.count) route\(routes.count == 1 ? "" : "s") loaded."
        } catch {
            statusText = error.localizedDescription
        }

        isLoading = false
    }
}

struct ImportedRoute {
    let date: Date
    let coordinates: [CLLocationCoordinate2D]
}

enum WorkoutImportMode: CaseIterable, Identifiable {
    case biking
    case walking
    case bikingAndWalking

    var id: Self { self }

    var title: String {
        switch self {
        case .biking:
            "Biking"
        case .walking:
            "Walking"
        case .bikingAndWalking:
            "Biking+Walking"
        }
    }

    var activityTypes: [HKWorkoutActivityType] {
        switch self {
        case .biking:
            [.cycling]
        case .walking:
            [.walking]
        case .bikingAndWalking:
            [.cycling, .walking]
        }
    }

    var progressName: String {
        switch self {
        case .biking:
            "rides"
        case .walking:
            "walks"
        case .bikingAndWalking:
            "workouts"
        }
    }

    var routeDescription: String {
        switch self {
        case .biking:
            "biking routes"
        case .walking:
            "walking routes"
        case .bikingAndWalking:
            "biking or walking routes"
        }
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

    func loadRoutes(
        since startDate: Date?,
        workoutMode: WorkoutImportMode,
        progress: @escaping @MainActor (_ completed: Int, _ total: Int) -> Void
    ) async throws -> [ImportedRoute] {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw RouteImportError.healthUnavailable
        }

        try await requestAuthorization()
        let workouts = try await workouts(since: startDate, workoutMode: workoutMode)
        var allRoutes: [ImportedRoute] = []

        progress(0, workouts.count)

        for (index, workout) in workouts.enumerated() {
            let routes = try await workoutRoutes(for: workout)
            for route in routes {
                let locations = try await locations(for: route)
                let coordinates = simplified(locations.map(\.coordinate))
                if coordinates.count > 1 {
                    allRoutes.append(ImportedRoute(date: workout.startDate, coordinates: coordinates))
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

    private func workouts(since startDate: Date?, workoutMode: WorkoutImportMode) async throws -> [HKWorkout] {
        try await withCheckedThrowingContinuation { continuation in
            let activityPredicate = NSCompoundPredicate(
                orPredicateWithSubpredicates: workoutMode.activityTypes.map { HKQuery.predicateForWorkouts(with: $0) }
            )
            var predicates: [NSPredicate] = [activityPredicate]
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
    private static let mergeRadius = 10.0

    static func makeOverlay(from routes: [ImportedRoute]) -> (overlay: TrafficOverlay?, distance: CLLocationDistance) {
        let clusteredRoutes = clusteredRoutes(from: routes.map(\.coordinates))
        var segmentKeys: [String] = []
        for route in clusteredRoutes {
            segmentKeys.append(contentsOf: routeSegmentKeys(route))
        }

        let counts = Dictionary(grouping: segmentKeys, by: { $0 }).mapValues(\.count)
        let normalizationCount = percentile(Array(counts.values), percentile: 0.92)
        var segments: [TrafficSegment] = []
        var totalDistance: CLLocationDistance = 0

        for route in clusteredRoutes {
            for pair in zip(route, route.dropFirst()) {
                guard pair.0.clusterID != pair.1.clusterID else { continue }

                let distance = CLLocation(latitude: pair.0.coordinate.latitude, longitude: pair.0.coordinate.longitude)
                    .distance(from: CLLocation(latitude: pair.1.coordinate.latitude, longitude: pair.1.coordinate.longitude))
                guard distance > 0, distance < 2_000 else { continue }

                let rawCount = counts[segmentKey(pair.0, pair.1)] ?? 1
                let weight = min(1, Double(rawCount) / Double(normalizationCount))
                segments.append(
                    TrafficSegment(
                        start: MKMapPoint(pair.0.coordinate),
                        end: MKMapPoint(pair.1.coordinate),
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

    private static func clusteredRoutes(from routes: [[CLLocationCoordinate2D]]) -> [[ClusteredPoint]] {
        var points: [RoutePoint] = []
        var routePointIndexes = Array(repeating: [Int](), count: routes.count)

        for (routeIndex, route) in routes.enumerated() {
            for coordinate in route {
                guard CLLocationCoordinate2DIsValid(coordinate) else { continue }

                let point = RoutePoint(coordinate: coordinate)
                routePointIndexes[routeIndex].append(points.count)
                points.append(point)
            }
        }

        guard !points.isEmpty else { return [] }

        var clusters: [PointCluster] = []
        var buckets: [BucketKey: [Int]] = [:]
        var pointClusterIDs = Array(repeating: 0, count: points.count)

        for (index, point) in points.enumerated() {
            let key = bucketKey(for: point)
            var bestClusterID: Int?
            var bestDistance = Double.greatestFiniteMagnitude

            for x in (key.x - 1)...(key.x + 1) {
                for y in (key.y - 1)...(key.y + 1) {
                    for clusterID in buckets[BucketKey(x: x, y: y), default: []] {
                        let distance = clusters[clusterID].distance(to: point)
                        if distance <= mergeRadius, distance < bestDistance {
                            bestClusterID = clusterID
                            bestDistance = distance
                        }
                    }
                }
            }

            if let bestClusterID {
                clusters[bestClusterID].add(point)
                pointClusterIDs[index] = bestClusterID
            } else {
                let clusterID = clusters.count
                clusters.append(PointCluster(seed: point))
                buckets[key, default: []].append(clusterID)
                pointClusterIDs[index] = clusterID
            }
        }

        return routePointIndexes.map { pointIndexes in
            var route: [ClusteredPoint] = []
            var previousClusterID: Int?

            for pointIndex in pointIndexes {
                let clusterID = pointClusterIDs[pointIndex]
                guard clusterID != previousClusterID else { continue }

                route.append(ClusteredPoint(clusterID: clusterID, coordinate: clusters[clusterID].coordinate))
                previousClusterID = clusterID
            }

            return route
        }
    }

    private static func routeSegmentKeys(_ route: [ClusteredPoint]) -> [String] {
        zip(route, route.dropFirst()).map { segmentKey($0.0, $0.1) }
    }

    private static func segmentKey(_ first: ClusteredPoint, _ second: ClusteredPoint) -> String {
        let firstID = first.clusterID
        let secondID = second.clusterID
        return firstID < secondID ? "\(firstID)-\(secondID)" : "\(secondID)-\(firstID)"
    }

    private static func bucketKey(for point: RoutePoint) -> BucketKey {
        BucketKey(
            x: Int(floor(point.x / mergeRadius)),
            y: Int(floor(point.y / mergeRadius))
        )
    }

    private static func percentile(_ values: [Int], percentile: Double) -> Int {
        guard !values.isEmpty else { return 1 }

        let sorted = values.sorted()
        let index = min(sorted.count - 1, max(0, Int(Double(sorted.count - 1) * percentile)))
        return max(sorted[index], 1)
    }
}

private struct ClusteredPoint {
    let clusterID: Int
    let coordinate: CLLocationCoordinate2D
}

private struct RoutePoint {
    let coordinate: CLLocationCoordinate2D
    let x: Double
    let y: Double

    init(coordinate: CLLocationCoordinate2D) {
        self.coordinate = coordinate
        let latitudeRadians = coordinate.latitude * .pi / 180
        x = coordinate.longitude * 111_320 * max(cos(latitudeRadians), 0.15)
        y = coordinate.latitude * 111_320
    }

    func distance(to other: RoutePoint) -> Double {
        hypot(x - other.x, y - other.y)
    }
}

private struct BucketKey: Hashable {
    let x: Int
    let y: Int
}

private struct PointCluster {
    private let seedX: Double
    private let seedY: Double
    private var latitude = 0.0
    private var longitude = 0.0
    private var count = 0.0

    init(seed: RoutePoint) {
        seedX = seed.x
        seedY = seed.y
        add(seed)
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude / count, longitude: longitude / count)
    }

    mutating func add(_ point: RoutePoint) {
        latitude += point.coordinate.latitude
        longitude += point.coordinate.longitude
        count += 1
    }

    func distance(to point: RoutePoint) -> Double {
        hypot(seedX - point.x, seedY - point.y)
    }
}
