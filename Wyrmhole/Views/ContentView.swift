import SwiftUI

struct ContentView: View {
    @EnvironmentObject var connectionManager: ConnectionManager

    var body: some View {
        ZStack {
            Group {
                switch connectionManager.state {
                case .disconnected, .browsing:
                    DiscoveryView()
                case .connecting:
                    ConnectingView()
                case .connected:
                    PortalTransitionView()
                }
            }

            // Toast message for remote disconnect
            if connectionManager.remoteDisconnectReceived {
                VStack {
                    Spacer()
                    Text("Wyrmhole closed")
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(
                            Capsule()
                                .fill(Color.black.opacity(0.8))
                        )
                        .padding(.bottom, 100)
                }
                .transition(.opacity)
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        withAnimation {
                            connectionManager.remoteDisconnectReceived = false
                        }
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .onChange(of: connectionManager.state) { newState in
            // Start browsing/advertising when not connected, stop when connected
            if newState == .connected {
                connectionManager.stopBrowsing()
                connectionManager.stopAdvertising()
            } else if newState == .disconnected || newState == .browsing {
                // Restart browsing/advertising if we're back to discovery state
                connectionManager.startBrowsing()
                connectionManager.startAdvertising()
            }
        }
        .onAppear {
            // Start browsing/advertising when app appears (if not connected)
            if connectionManager.state != .connected {
                connectionManager.startBrowsing()
                connectionManager.startAdvertising()
            }
        }
    }
}

struct ConnectingView: View {
    @EnvironmentObject var connectionManager: ConnectionManager

    var body: some View {
        VStack(spacing: 24) {
            ProgressView()
                .scaleEffect(2)

            Text("Opening Wyrmhole...")
                .font(.title2)
                .foregroundColor(.secondary)

            Button("Cancel") {
                connectionManager.disconnect()
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }
}

#Preview {
    ContentView()
        .environmentObject(ConnectionManager())
}
