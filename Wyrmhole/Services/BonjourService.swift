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

    // Device name for advertising
    private var deviceName: String {
        UIDevice.current.name
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
            parameters.includePeerToPeer = true

            // Add TLS for security (optional, can be removed for simplicity)
            // parameters.defaultProtocolStack.applicationProtocols.insert(NWProtocolTLS.Options(), at: 0)

            let listener = try NWListener(using: parameters)

            // Advertise via Bonjour
            listener.service = NWListener.Service(
                name: deviceName,
                type: Self.serviceType
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
        parameters.includePeerToPeer = true

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
            if name == deviceName && listener != nil {
                return nil
            }

            return Peer(name: name, endpoint: result.endpoint)
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
