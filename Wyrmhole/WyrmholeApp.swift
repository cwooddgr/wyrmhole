import SwiftUI
import UIKit

@main
struct WyrmholeApp: App {
    @StateObject private var connectionManager = ConnectionManager()

    init() {
        // Start generating device orientation notifications as early as possible
        // This helps ensure correct camera orientation on first launch
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(connectionManager)
        }
    }
}
