import Foundation
import Network
import Combine
import UIKit

/// Handles Bonjour service advertising and discovery using Network.framework
final class BonjourService: ObservableObject {
    // MARK: - Types

    private static let serviceType = "_wyrmhole._tcp"

    enum State {
        case idle
        case browsing
        case advertising
        case browsingAndAdvertising
    }

    // MARK: - Published Properties

    @Published private(set) var discoveredPeers: [Peer] = []
    @Published private(set) var state: State = .idle

    // MARK: - Private Properties

    private var browser: NWBrowser?
    private var listener: NWListener?
    private var browserResults: [NWBrowser.Result] = []
    private let queue = DispatchQueue(label: "com.wyrmhole.bonjour", qos: .userInitiated)

    // Callbacks for incoming connections
    var onIncomingConnection: ((NWConnection) -> Void)?

    // User-configurable display name key
    private static let displayNameKey = "WyrmholeDisplayName"

    /// Returns true if the user has never set a custom display name (first launch)
    var isFirstLaunch: Bool {
        UserDefaults.standard.string(forKey: Self.displayNameKey) == nil
    }

    // Display name for advertising (user-configurable, falls back to device model)
    var displayName: String {
        get {
            UserDefaults.standard.string(forKey: Self.displayNameKey) ?? UIDevice.current.name
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.displayNameKey)
            objectWillChange.send()
            // Restart advertising if active to use the new name
            if listener != nil {
                stopAdvertising()
                startAdvertising()
            }
        }
    }

    // MARK: - Initialization

    init() {}

    deinit {
        stopAll()
    }

    // MARK: - Public Methods

    /// Start browsing for nearby Wyrmhole services
    func startBrowsing() {
        guard browser == nil else { return }

        let parameters = NWParameters()
        parameters.includePeerToPeer = true

        let browser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil), using: parameters)

        browser.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                self?.handleBrowserStateChange(state)
            }
        }

        browser.browseResultsChangedHandler = { [weak self] results, changes in
            DispatchQueue.main.async {
                self?.handleBrowseResultsChanged(results: results, changes: changes)
            }
        }

        browser.start(queue: queue)
        self.browser = browser
        updateState()
    }

    /// Stop browsing for services
    func stopBrowsing() {
        browser?.cancel()
        browser = nil
        browserResults.removeAll()
        discoveredPeers.removeAll()
        updateState()
    }

    /// Start advertising this device as a Wyrmhole service
    func startAdvertising() {
        guard listener == nil else { return }

        do {
            let parameters = NWParameters.tcp
            // Note: We intentionally do NOT set includePeerToPeer on the listener
            // This forces incoming connections over WiFi instead of AWDL, which is
            // more reliable between different iOS versions. Discovery still uses
            // peer-to-peer via the browser, but actual connections go over WiFi.

            let listener = try NWListener(using: parameters)

            // Advertise via Bonjour with device name in TXT record
            let txtRecord = NWTXTRecord(["displayName": displayName])
            listener.service = NWListener.Service(
                name: displayName,
                type: Self.serviceType,
                txtRecord: txtRecord
            )

            listener.stateUpdateHandler = { [weak self] state in
                DispatchQueue.main.async {
                    self?.handleListenerStateChange(state)
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                self?.handleIncomingConnection(connection)
            }

            listener.start(queue: queue)
            self.listener = listener
            updateState()
        } catch {
            print("Failed to start advertising: \(error)")
        }
    }

    /// Stop advertising this device
    func stopAdvertising() {
        listener?.cancel()
        listener = nil
        updateState()
    }

    /// Stop all Bonjour activity
    func stopAll() {
        stopBrowsing()
        stopAdvertising()
    }

    /// Connect to a discovered peer
    func connect(to peer: Peer) -> NWConnection {
        let parameters = NWParameters.tcp
        // Note: We intentionally do NOT set includePeerToPeer on connections
        // This forces connections over WiFi instead of AWDL, which is more
        // reliable between different iOS versions (especially iOS 16 to newer).
        // Discovery still uses peer-to-peer via the browser.

        let connection = NWConnection(to: peer.endpoint, using: parameters)
        return connection
    }

    // MARK: - Private Methods

    private func handleBrowserStateChange(_ state: NWBrowser.State) {
        switch state {
        case .ready:
            print("Browser ready")
        case .failed(let error):
            print("Browser failed: \(error)")
            // Attempt to restart
            browser?.cancel()
            browser = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.startBrowsing()
            }
        case .cancelled:
            print("Browser cancelled")
        default:
            break
        }
    }

    private func handleBrowseResultsChanged(results: Set<NWBrowser.Result>, changes: Set<NWBrowser.Result.Change>) {
        browserResults = Array(results)

        // Convert browser results to Peer objects
        discoveredPeers = results.compactMap { result -> Peer? in
            // Extract the service name
            guard case .service(let name, _, _, _) = result.endpoint else {
                return nil
            }

            // Skip our own service
            if name == displayName && listener != nil {
                return nil
            }

            // Get device name from TXT record if available, otherwise use service name
            var peerName = name
            if case .bonjour(let txtRecord) = result.metadata,
               let nameEntry = txtRecord.getEntry(for: "displayName"),
               case .string(let nameValue) = nameEntry {
                peerName = nameValue
            }

            return Peer(name: peerName, endpoint: result.endpoint)
        }
    }

    private func handleListenerStateChange(_ state: NWListener.State) {
        switch state {
        case .ready:
            if let port = listener?.port {
                print("Listener ready on port \(port)")
            }
        case .failed(let error):
            print("Listener failed: \(error)")
            listener?.cancel()
            listener = nil
        case .cancelled:
            print("Listener cancelled")
        default:
            break
        }
    }

    private func handleIncomingConnection(_ connection: NWConnection) {
        DispatchQueue.main.async { [weak self] in
            self?.onIncomingConnection?(connection)
        }
    }

    private func updateState() {
        let isBrowsing = browser != nil
        let isAdvertising = listener != nil

        switch (isBrowsing, isAdvertising) {
        case (false, false):
            state = .idle
        case (true, false):
            state = .browsing
        case (false, true):
            state = .advertising
        case (true, true):
            state = .browsingAndAdvertising
        }
    }
}
