//
//  ContentView.swift
//  Fortare
//
//  Created by Rasmus Sten on 3.6.2026.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var store = RouteHeatmapStore()
    @State private var isChoosingRange = false
    @State private var selectedRangeIndex = ImportWindow.presets.firstIndex(of: .default) ?? 4
    @State private var selectedWorkoutMode: WorkoutImportMode = .biking

    var body: some View {
        ZStack {
            RouteHeatmapMapView(overlay: store.overlay)
                .ignoresSafeArea()

            LinearGradient(
                colors: [
                    .black.opacity(0.28),
                    .black.opacity(0.05),
                    .black.opacity(0.24)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            if store.isLoading {
                SyncingIndicator(progress: store.importProgress)
                    .transition(.scale(scale: 0.88).combined(with: .opacity))
            } else {
                VStack(spacing: 0) {
                    VStack(alignment: .trailing, spacing: 12) {
                        HStack {
                            Spacer()

                            SoftActionButton(
                                title: "Import",
                                isBusy: false
                            ) {
                                isChoosingRange.toggle()
                            }
                        }

                        if isChoosingRange {
                            ImportRangePanel(
                                selectedIndex: $selectedRangeIndex,
                                selectedWorkoutMode: $selectedWorkoutMode,
                                presets: ImportWindow.presets
                            ) {
                                let window = ImportWindow.presets[selectedRangeIndex]
                                isChoosingRange = false
                                Task { await store.loadRoutes(window: window, workoutMode: selectedWorkoutMode) }
                            }
                            .transition(.scale(scale: 0.94, anchor: .topTrailing).combined(with: .opacity))
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 14)

                    Spacer()

                    HStack {
                        bottomPanel
                            .frame(maxWidth: 520)

                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 18)
                }
                .transition(.opacity)
            }
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.84), value: store.isLoading)
        .task {
            await store.loadRoutes(workoutMode: selectedWorkoutMode)
        }
    }

    private var bottomPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(
                columns: [
                    GridItem(.flexible(minimum: 66), alignment: .leading),
                    GridItem(.flexible(minimum: 66), alignment: .leading),
                    GridItem(.flexible(minimum: 66), alignment: .leading),
                    GridItem(.flexible(minimum: 66), alignment: .leading)
                ],
                alignment: .leading,
                spacing: 10
            ) {
                metric(value: "\(store.routeCount)", label: "routes")
                metric(value: store.distanceText, label: "km")
                metric(value: "\(store.daysWithSessions)", label: "days")
                metric(value: store.averageDistanceText, label: "avg km")
            }

            HeatScaleView()
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.black.opacity(0.54))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(.white.opacity(0.09), lineWidth: 1)
                )
                .shadow(color: .cyan.opacity(0.22), radius: 24, y: 14)
        }
    }

    private func metric(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value)
                .font(.system(size: 22, weight: .black, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.68)
                .contentTransition(.numericText())

            Text(label)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.56))
                .lineLimit(1)
        }
        .frame(minWidth: 66, alignment: .leading)
    }
}

private struct ImportRangePanel: View {
    @Binding var selectedIndex: Int
    @Binding var selectedWorkoutMode: WorkoutImportMode

    let presets: [ImportWindow]
    let importAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .lastTextBaseline) {
                Text("Range")
                    .font(.system(size: 12, weight: .black, design: .rounded))
                    .foregroundStyle(.white.opacity(0.46))

                Spacer()

                Text(presets[selectedIndex].title)
                    .font(.system(size: 22, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
            }

            RangePresetSlider(selectedIndex: $selectedIndex, count: presets.count)

            HStack {
                Text("Today")
                Spacer()
                Text("All")
            }
            .font(.system(size: 11, weight: .black, design: .rounded))
            .foregroundStyle(.white.opacity(0.44))

            HStack {
                Text("Workout")
                    .font(.system(size: 13, weight: .black, design: .rounded))
                    .foregroundStyle(.white.opacity(0.82))

                Spacer()

                Picker("Workout", selection: $selectedWorkoutMode) {
                    ForEach(WorkoutImportMode.allCases) { mode in
                        Text(mode.title)
                            .tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .tint(.white)
            }

            Button(action: importAction) {
                Text("Start")
                    .font(.system(size: 15, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        LinearGradient(
                            colors: [.cyan, .blue, .purple, .pink],
                            startPoint: .leading,
                            endPoint: .trailing
                        ),
                        in: Capsule()
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .frame(width: 254)
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.black.opacity(0.62))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(.white.opacity(0.1), lineWidth: 1)
                )
                .shadow(color: .purple.opacity(0.28), radius: 26, y: 14)
        }
    }
}

private struct RangePresetSlider: View {
    @Binding var selectedIndex: Int

    let count: Int

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let denominator = CGFloat(max(count - 1, 1))
            let progress = CGFloat(selectedIndex) / denominator
            let thumbX = progress * width

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.13))
                    .frame(height: 10)

                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [.cyan, .blue, .purple, .pink],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: thumbX, height: 10)

                ForEach(0..<count, id: \.self) { index in
                    Circle()
                        .fill(index <= selectedIndex ? .white.opacity(0.82) : .white.opacity(0.24))
                        .frame(width: index == selectedIndex ? 8 : 5, height: index == selectedIndex ? 8 : 5)
                        .offset(x: (CGFloat(index) / denominator) * width - 3)
                }

                Circle()
                    .fill(.white)
                    .frame(width: 24, height: 24)
                    .shadow(color: .cyan.opacity(0.6), radius: 10)
                    .offset(x: thumbX - 12)
            }
            .frame(height: 28)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        selectedIndex = index(for: value.location.x, width: width)
                    }
            )
        }
        .frame(height: 28)
    }

    private func index(for location: CGFloat, width: CGFloat) -> Int {
        let clamped = min(max(location / max(width, 1), 0), 1)
        return min(max(Int((clamped * CGFloat(count - 1)).rounded()), 0), count - 1)
    }
}

private struct SoftActionButton: View {
    let title: String
    let isBusy: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(.white.opacity(0.2))
                        .frame(width: 20, height: 20)

                    Circle()
                        .trim(from: 0, to: isBusy ? 0.68 : 1)
                        .stroke(.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .frame(width: 12, height: 12)
                        .rotationEffect(.degrees(isBusy ? 270 : 0))
                        .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: isBusy)
                }

                Text(title)
                    .font(.system(size: 15, weight: .black, design: .rounded))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background {
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [.cyan, .blue, .purple, .pink],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .shadow(color: .cyan.opacity(0.7), radius: 24)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct SyncingIndicator: View {
    let progress: Double

    @State private var rotation = 0.0

    var body: some View {
        VStack(spacing: 22) {
            ZStack {
                Circle()
                    .fill(.black.opacity(0.46))
                    .frame(width: 150, height: 150)
                    .shadow(color: .cyan.opacity(0.6), radius: 38)

                Circle()
                    .stroke(.white.opacity(0.14), lineWidth: 16)
                    .frame(width: 106, height: 106)

                Circle()
                    .trim(from: 0, to: 0.72)
                    .stroke(
                        AngularGradient(
                            colors: [.cyan, .blue, .purple, .pink, .cyan],
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: 16, lineCap: .round)
                    )
                    .frame(width: 106, height: 106)
                    .rotationEffect(.degrees(rotation))
                    .shadow(color: .cyan.opacity(0.75), radius: 16)

                Circle()
                    .trim(from: 0, to: min(max(progress, 0), 1))
                    .stroke(.white, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .frame(width: 64, height: 64)
                    .rotationEffect(.degrees(-90))

                Text("\(Int((min(max(progress, 0), 1) * 100).rounded()))")
                    .font(.system(size: 24, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.12))

                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [.cyan, .blue, .purple, .pink],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: proxy.size.width * min(max(progress, 0), 1))
                        .shadow(color: .pink.opacity(0.55), radius: 14)
                }
            }
            .frame(width: 190, height: 12)
        }
        .onAppear {
            rotation = 360
        }
        .animation(.linear(duration: 1.15).repeatForever(autoreverses: false), value: rotation)
        .animation(.spring(response: 0.35, dampingFraction: 0.78), value: progress)
    }
}

private struct HeatScaleView: View {
    var body: some View {
        VStack(spacing: 7) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [.blue, .cyan, .green, .yellow, .orange, .red],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .shadow(color: .red.opacity(0.45), radius: 16)

                    Capsule()
                        .fill(.white.opacity(0.55))
                        .frame(width: max(10, proxy.size.width * 0.05))
                        .blur(radius: 5)
                        .offset(x: proxy.size.width * 0.74)
                }
            }
            .frame(height: 12)

            HStack {
                Text("rare")
                Spacer()
                Text("most trafficked")
            }
            .font(.system(size: 11, weight: .black, design: .rounded))
            .foregroundStyle(.white.opacity(0.5))
        }
    }
}

#Preview {
    ContentView()
}
