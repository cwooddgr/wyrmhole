import SwiftUI

struct ContentView: View {
    @EnvironmentObject var connectionManager: ConnectionManager

    var body: some View {
        Group {
            switch connectionManager.state {
            case .disconnected, .browsing:
                DiscoveryView()
            case .connecting:
                ConnectingView()
            case .connected:
                PortalView()
            }
        }
        .preferredColorScheme(.dark)
        .alert("Wyrmhole closed", isPresented: $connectionManager.remoteDisconnectReceived) {
            Button("OK", role: .cancel) { }
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
