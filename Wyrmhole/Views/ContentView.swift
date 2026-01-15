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
    }
}

struct ConnectingView: View {
    @EnvironmentObject var connectionManager: ConnectionManager

    var body: some View {
        VStack(spacing: 24) {
            ProgressView()
                .scaleEffect(2)

            Text("Connecting...")
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
