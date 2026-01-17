import Foundation
import Network
import Combine

/// Manages the overall connection lifecycle between two Wyrmhole devices
@MainActor
final class ConnectionManager: ObservableObject {
    // MARK: - Types

    enum State: Equatable {
        case disconnected
        case browsing
        case connecting
        case connected

        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.disconnected, .disconnected),
                 (.browsing, .browsing),
                 (.connecting, .connecting),
                 (.connected, .connected):
                return true
            default:
                return false
            }
        }
    }

    // MARK: - Published Properties

    @Published private(set) var state: State = .disconnected
    @Published private(set) var discoveredPeers: [Peer] = []
    @Published private(set) var connectedPeer: Peer?
    @Published private(set) var signalStrength: Int = 3 // 0-3
    @Published var remoteDisconnectReceived = false

    // MARK: - Public Properties

    private(set) var webRTCService: WebRTCService?

    /// The display name shown to other devices
    var displayName: String {
        get { bonjourService.displayName }
        set { bonjourService.displayName = newValue }
    }

    // MARK: - Private Properties

    private let bonjourService = BonjourService()
    private var signalingConnection: NWConnection?
    private var cancellables = Set<AnyCancellable>()

    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 5
    private var reconnectWorkItem: DispatchWorkItem?
    private var lastConnectedPeer: Peer?
    private var wasInitiator = false

    // MARK: - Initialization

    init() {
        setupBindings()
    }

    // MARK: - Public Methods

    /// Start browsing for nearby Wyrmhole devices
    func startBrowsing() {
        bonjourService.startBrowsing()
        state = .browsing
    }

    /// Stop browsing for devices
    func stopBrowsing() {
        bonjourService.stopBrowsing()
        if state == .browsing {
            state = .disconnected
        }
    }

    /// Start advertising this device to others
    func startAdvertising() {
        bonjourService.startAdvertising()
    }

    /// Stop advertising this device
    func stopAdvertising() {
        bonjourService.stopAdvertising()
    }

    /// Connect to a discovered peer
    func connect(to peer: Peer) {
        state = .connecting
        lastConnectedPeer = peer
        reconnectAttempts = 0
        wasInitiator = true

        // Create signaling connection
        let connection = bonjourService.connect(to: peer)
        setupSignalingConnection(connection, isInitiator: true)
        signalingConnection = connection
        connection.start(queue: .main)

        connectedPeer = peer
    }

    /// Disconnect from the current peer
    func disconnect() {
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        reconnectAttempts = maxReconnectAttempts // Prevent auto-reconnect

        // Notify the other peer of graceful disconnect before closing
        sendSignalingMessage(.disconnect)

        cleanupConnection()
        state = .disconnected
        connectedPeer = nil
    }

    // MARK: - Private Methods

    private func setupBindings() {
        // Bind discovered peers from Bonjour service
        bonjourService.$discoveredPeers
            .receive(on: DispatchQueue.main)
            .assign(to: &$discoveredPeers)

        // Handle incoming connections
        bonjourService.onIncomingConnection = { [weak self] connection in
            Task { @MainActor in
                self?.handleIncomingConnection(connection)
            }
        }
    }

    private func handleIncomingConnection(_ connection: NWConnection) {
        guard state != .connected else {
            // Already connected, reject
            connection.cancel()
            return
        }

        state = .connecting
        wasInitiator = false

        // Extract peer info from connection
        let peerName: String
        if case .service(let name, _, _, _) = connection.endpoint {
            peerName = name
        } else {
            peerName = "Unknown Device"
        }

        let peer = Peer(name: peerName, endpoint: connection.endpoint)
        connectedPeer = peer
        lastConnectedPeer = peer
        reconnectAttempts = 0

        setupSignalingConnection(connection, isInitiator: false)
        signalingConnection = connection
        connection.start(queue: .main)
    }

    private func setupSignalingConnection(_ connection: NWConnection, isInitiator: Bool) {
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                self?.handleConnectionStateChange(state, isInitiator: isInitiator)
            }
        }
    }

    private func handleConnectionStateChange(_ connectionState: NWConnection.State, isInitiator: Bool) {
        switch connectionState {
        case .ready:
            print("Signaling connection ready")
            // Set up WebRTC first so it's ready to handle incoming messages
            setupWebRTC(isInitiator: isInitiator)
            // Then start receiving signaling messages
            if let connection = signalingConnection {
                receiveSignalingMessage(from: connection)
            }

        case .failed(let error):
            print("Signaling connection failed: \(error)")
            handleConnectionFailure()

        case .cancelled:
            print("Signaling connection cancelled")

        default:
            break
        }
    }

    private func setupWebRTC(isInitiator: Bool) {
        let webRTC = WebRTCService()

        webRTC.onLocalSessionDescription = { [weak self] sdp in
            self?.sendSignalingMessage(.sdp(sdp))
        }

        webRTC.onLocalIceCandidate = { [weak self] candidate in
            self?.sendSignalingMessage(.iceCandidate(candidate))
        }

        webRTC.onConnectionStateChanged = { [weak self] state in
            Task { @MainActor in
                self?.handleWebRTCStateChange(state)
            }
        }

        webRTC.setup()
        webRTCService = webRTC

        if isInitiator {
            webRTC.createOffer()
        }
    }

    private func handleWebRTCStateChange(_ webRTCState: WebRTCService.State) {
        switch webRTCState {
        case .connected:
            state = .connected
            reconnectAttempts = 0

        case .disconnected:
            handleConnectionFailure()

        case .failed:
            handleConnectionFailure()

        default:
            break
        }
    }

    private func handleConnectionFailure() {
        // Only the initiator should attempt to reconnect
        // The non-initiator should wait for a new incoming connection
        guard wasInitiator else {
            print("Connection failed (non-initiator), returning to disconnected state")
            cleanupConnection()
            state = .disconnected
            connectedPeer = nil
            return
        }

        guard reconnectAttempts < maxReconnectAttempts else {
            print("Max reconnection attempts reached, giving up")
            cleanupConnection()
            state = .disconnected
            connectedPeer = nil
            return
        }

        reconnectAttempts += 1
        print("Connection failed, attempting reconnect (\(reconnectAttempts)/\(maxReconnectAttempts))")

        cleanupConnection()

        // Exponential backoff for reconnect
        let delay = pow(2.0, Double(reconnectAttempts - 1))
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self = self, let peer = self.lastConnectedPeer else { return }
                self.connect(to: peer)
            }
        }
        reconnectWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func cleanupConnection() {
        webRTCService?.close()
        webRTCService = nil
        signalingConnection?.cancel()
        signalingConnection = nil
    }

    // MARK: - Signaling Protocol

    private enum SignalingMessage: Codable {
        case sdp(RTCSessionDescriptionWrapper)
        case iceCandidate(RTCIceCandidateWrapper)
        case disconnect

        static func sdp(_ sdp: RTCSessionDescription) -> SignalingMessage {
            .sdp(RTCSessionDescriptionWrapper(sdp))
        }

        static func iceCandidate(_ candidate: RTCIceCandidate) -> SignalingMessage {
            .iceCandidate(RTCIceCandidateWrapper(candidate))
        }
    }

    private func sendSignalingMessage(_ message: SignalingMessage) {
        guard let connection = signalingConnection else { return }

        do {
            let data = try JSONEncoder().encode(message)
            let lengthData = withUnsafeBytes(of: UInt32(data.count).bigEndian) { Data($0) }

            connection.send(content: lengthData + data, completion: .contentProcessed { error in
                if let error = error {
                    print("Failed to send signaling message: \(error)")
                }
            })
        } catch {
            print("Failed to encode signaling message: \(error)")
        }
    }

    private func receiveSignalingMessage(from connection: NWConnection) {
        // Don't receive if connection is no longer active
        guard connection.state == .ready else {
            print("Connection not ready, stopping receive loop")
            return
        }

        // First, read the length prefix (4 bytes)
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }

            if let error = error {
                print("Error receiving message length: \(error)")
                // Only stop if connection is no longer valid
                if connection.state != .ready {
                    return
                }
                // Otherwise continue trying to receive
                self.receiveSignalingMessage(from: connection)
                return
            }

            guard let lengthData = data, lengthData.count == 4 else {
                if !isComplete && connection.state == .ready {
                    self.receiveSignalingMessage(from: connection)
                }
                return
            }

            let length = lengthData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }

            // Now read the message body
            connection.receive(minimumIncompleteLength: Int(length), maximumLength: Int(length)) { data, _, _, error in
                if let error = error {
                    print("Error receiving message body: \(error)")
                    // Continue receiving if connection is still valid
                    if connection.state == .ready {
                        self.receiveSignalingMessage(from: connection)
                    }
                    return
                }

                if let data = data {
                    Task { @MainActor in
                        self.handleSignalingData(data)
                    }
                }

                // Continue receiving
                if connection.state == .ready {
                    self.receiveSignalingMessage(from: connection)
                }
            }
        }
    }

    private func handleSignalingData(_ data: Data) {
        do {
            let message = try JSONDecoder().decode(SignalingMessage.self, from: data)

            switch message {
            case .sdp(let wrapper):
                let sdp = wrapper.toRTCSessionDescription()
                if sdp.type == .offer {
                    webRTCService?.handleOffer(sdp)
                } else if sdp.type == .answer {
                    webRTCService?.handleAnswer(sdp)
                }

            case .iceCandidate(let wrapper):
                let candidate = wrapper.toRTCIceCandidate()
                webRTCService?.addIceCandidate(candidate)

            case .disconnect:
                // Remote peer disconnected gracefully - don't attempt reconnection
                print("Remote peer disconnected gracefully")
                reconnectWorkItem?.cancel()
                reconnectWorkItem = nil
                reconnectAttempts = maxReconnectAttempts
                cleanupConnection()
                state = .disconnected
                connectedPeer = nil
                remoteDisconnectReceived = true
            }
        } catch {
            print("Failed to decode signaling message: \(error)")
        }
    }
}

// MARK: - Codable Wrappers for WebRTC Types

import WebRTC

struct RTCSessionDescriptionWrapper: Codable {
    let type: String
    let sdp: String

    init(_ rtc: RTCSessionDescription) {
        switch rtc.type {
        case .offer: type = "offer"
        case .prAnswer: type = "pranswer"
        case .answer: type = "answer"
        case .rollback: type = "rollback"
        @unknown default: type = "unknown"
        }
        sdp = rtc.sdp
    }

    func toRTCSessionDescription() -> RTCSessionDescription {
        let sdpType: RTCSdpType
        switch type {
        case "offer": sdpType = .offer
        case "pranswer": sdpType = .prAnswer
        case "answer": sdpType = .answer
        case "rollback": sdpType = .rollback
        default: sdpType = .offer
        }
        return RTCSessionDescription(type: sdpType, sdp: sdp)
    }
}

struct RTCIceCandidateWrapper: Codable {
    let sdp: String
    let sdpMLineIndex: Int32
    let sdpMid: String?

    init(_ rtc: RTCIceCandidate) {
        sdp = rtc.sdp
        sdpMLineIndex = rtc.sdpMLineIndex
        sdpMid = rtc.sdpMid
    }

    func toRTCIceCandidate() -> RTCIceCandidate {
        RTCIceCandidate(sdp: sdp, sdpMLineIndex: sdpMLineIndex, sdpMid: sdpMid)
    }
}
