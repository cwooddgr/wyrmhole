import SwiftUI

struct DiscoveryView: View {
    @EnvironmentObject var connectionManager: ConnectionManager
    @State private var isEditingName = false
    @State private var editedName = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if connectionManager.discoveredPeers.isEmpty {
                    emptyStateView
                } else {
                    peerListView
                }
            }
            .navigationTitle("Wyrmhole")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    HStack(spacing: 8) {
                        Text(connectionManager.displayName)
                            .foregroundColor(.secondary)
                            .padding(.leading, 8)
                        Button {
                            editedName = connectionManager.displayName
                            isEditingName = true
                        } label: {
                            Image(systemName: "pencil")
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            .sheet(isPresented: $isEditingName) {
                NavigationStack {
                    Form {
                        Section {
                            TextField("Display Name", text: $editedName)
                        } footer: {
                            Text("This name is shown to other devices")
                        }
                    }
                    .navigationTitle("Your Display Name")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") {
                                isEditingName = false
                            }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Save") {
                                let trimmed = editedName.trimmingCharacters(in: .whitespacesAndNewlines)
                                if !trimmed.isEmpty {
                                    connectionManager.displayName = trimmed
                                }
                                isEditingName = false
                            }
                        }
                    }
                }
                .presentationDetents([.medium])
            }
            .onAppear {
                // Show name dialog on first launch
                if connectionManager.isFirstLaunch {
                    editedName = connectionManager.displayName
                    isEditingName = true
                }
            }
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            AnimatedDashedCircle()
                .frame(width: 64, height: 64)

            Text("Looking for nearby Wyrmholes...")
                .font(.headline)
                .foregroundColor(.secondary)

            Text("Make sure another device is running Wyrmhole")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.95))
    }

    private var peerListView: some View {
        List(connectionManager.discoveredPeers) { peer in
            Button {
                connectionManager.connect(to: peer)
            } label: {
                HStack {
                    Image(systemName: "ipad")
                        .font(.title2)
                        .foregroundColor(.blue)

                    VStack(alignment: .leading) {
                        Text(peer.name)
                            .font(.headline)
                        Text("Tap to connect")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 8)
            }
            .listRowBackground(Color.black.opacity(0.8))
        }
        .listStyle(.plain)
        .background(Color.black)
        .scrollContentBackground(.hidden)
    }
}

// MARK: - Animated Dashed Circle

struct AnimatedDashedCircle: View {
    private let segmentCount = 8
    private let gapFraction = 0.3
    @State private var hiddenSegment = 0

    let timer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            ForEach(0..<segmentCount, id: \.self) { index in
                CircleSegment(
                    startAngle: angle(for: index),
                    endAngle: angle(for: index) + segmentAngle,
                    lineWidth: 3
                )
                .stroke(Color.secondary, lineWidth: 3)
                .opacity(hiddenSegment == index ? 0 : 1)
                .animation(.easeInOut(duration: 0.3), value: hiddenSegment)
            }
        }
        .onReceive(timer) { _ in
            hiddenSegment = (hiddenSegment + 1) % segmentCount
        }
    }

    private var segmentAngle: Angle {
        .degrees(360.0 / Double(segmentCount) * (1 - gapFraction))
    }

    private func angle(for index: Int) -> Angle {
        .degrees(Double(index) * 360.0 / Double(segmentCount))
    }
}

struct CircleSegment: Shape {
    var startAngle: Angle
    var endAngle: Angle
    var lineWidth: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2 - lineWidth / 2
        path.addArc(
            center: center,
            radius: radius,
            startAngle: startAngle - .degrees(90),
            endAngle: endAngle - .degrees(90),
            clockwise: false
        )
        return path
    }
}

#Preview {
    DiscoveryView()
        .environmentObject(ConnectionManager())
}
