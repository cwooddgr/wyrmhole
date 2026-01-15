import SwiftUI

struct DiscoveryView: View {
    @EnvironmentObject var connectionManager: ConnectionManager
    @State private var isAdvertising = false

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
                    Toggle(isOn: $isAdvertising) {
                        Label(
                            isAdvertising ? "Visible" : "Hidden",
                            systemImage: isAdvertising ? "eye" : "eye.slash"
                        )
                    }
                    .toggleStyle(.button)
                    .onChange(of: isAdvertising) { newValue in
                        if newValue {
                            connectionManager.startAdvertising()
                        } else {
                            connectionManager.stopAdvertising()
                        }
                    }
                }
            }
            .onAppear {
                connectionManager.startBrowsing()
            }
            .onDisappear {
                connectionManager.stopBrowsing()
                connectionManager.stopAdvertising()
            }
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "circle.dashed")
                .font(.system(size: 64))
                .foregroundColor(.secondary)

            Text("Looking for nearby Wyrmholes...")
                .font(.headline)
                .foregroundColor(.secondary)

            Text("Make sure another device is running Wyrmhole\nand is set to Visible")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            if !isAdvertising {
                Button("Make this device visible") {
                    isAdvertising = true
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 8)
            }
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

#Preview {
    DiscoveryView()
        .environmentObject(ConnectionManager())
}
