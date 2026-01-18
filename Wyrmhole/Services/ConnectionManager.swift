import Foundation
import Network
import Combine

/// Portal transition animation state
enum PortalTransitionState: Equatable {
    case closed
    case opening
    case open
    case closing
}

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
    @Published private(set) var isAudioMuted: Bool = false
    @Published var portalTransitionState: PortalTransitionState = .closed

    // MARK: - Public Properties

    private(set) var webRTCService: WebRTCService?

    /// The display name shown to other devices
    var displayName: String {
        get { bonjourService.displayName }
        set { bonjourService.displayName = newValue }
    }

    /// Returns true if this is the first app launch (user hasn't set a display name)
    var isFirstLaunch: Bool {
        bonjourService.isFirstLaunch
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
    private let connectionQueue = DispatchQueue(label: "com.wyrmhole.connection", qos: .userInitiated)

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
        connection.start(queue: connectionQueue)

        connectedPeer = peer
    }

    /// Disconnect from the current peer (triggers closing animation first)
    func disconnect() {
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        reconnectAttempts = maxReconnectAttempts // Prevent auto-reconnect

        // Notify the other peer of graceful disconnect before closing
        sendSignalingMessage(.disconnect)

        // Trigger closing animation - completeDisconnect will be called when animation finishes
        portalTransitionState = .closing
    }

    /// Called by PortalTransitionView when closing animation completes
    func completeDisconnect() {
        cleanupConnection()
        state = .disconnected
        connectedPeer = nil
        portalTransitionState = .closed
    }

    /// Toggle microphone mute
    func toggleMute() {
        webRTCService?.toggleAudio()
        isAudioMuted.toggle()
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

        // Dismiss any "Wyrmhole closed" dialog that may be showing
        remoteDisconnectReceived = false

        state = .connecting
        wasInitiator = false

        // Create peer with placeholder name - will be updated when we receive hello message
        let peer = Peer(name: "Connecting...", endpoint: connection.endpoint)
        connectedPeer = peer
        lastConnectedPeer = peer
        reconnectAttempts = 0

        setupSignalingConnection(connection, isInitiator: false)
        signalingConnection = connection
        connection.start(queue: connectionQueue)
    }

    private var connectionTimeoutItem: DispatchWorkItem?

    private func setupSignalingConnection(_ connection: NWConnection, isInitiator: Bool) {
        // Set up connection timeout for stuck connections
        connectionTimeoutItem?.cancel()
        let timeoutItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            if self.signalingConnection?.state != .ready {
                print("Connection timeout - connection stuck in preparing state")
                DispatchQueue.main.async {
                    self.handleConnectionFailure()
                }
            }
        }
        connectionTimeoutItem = timeoutItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: timeoutItem)

        connection.stateUpdateHandler = { [weak self] state in
            print("Signaling connection state: \(state)")
            DispatchQueue.main.async {
                self?.connectionTimeoutItem?.cancel()
                self?.handleConnectionStateChange(state, isInitiator: isInitiator)
            }
        }

        // Log path updates to debug interface selection
        connection.pathUpdateHandler = { path in
            print("Connection path update: \(path.status), interfaces: \(path.availableInterfaces.map { $0.name })")
        }
    }

    private func handleConnectionStateChange(_ connectionState: NWConnection.State, isInitiator: Bool) {
        switch connectionState {
        case .ready:
            print("Signaling connection ready")
            // Send our display name to the peer
            sendSignalingMessage(.hello(displayName))
            // Set up WebRTC first so it's ready to handle incoming messages
            setupWebRTC(isInitiator: isInitiator)
            // Then start receiving signaling messages
            if let connection = signalingConnection {
                receiveSignalingMessage(from: connection)
            }

        case .failed(let error):
            print("Signaling connection failed: \(error)")
            // For non-initiator, if signaling fails before WebRTC is set up,
            // we need to fully clean up since there's no retry mechanism
            if !wasInitiator && webRTCService == nil {
                print("Non-initiator signaling failed before WebRTC setup, cleaning up")
                cleanupConnection()
                state = .disconnected
                connectedPeer = nil
                return
            }
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
            print("WebRTC state changed: \(state)")
            DispatchQueue.main.async {
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
        // The non-initiator keeps signaling open and waits for initiator to retry
        guard wasInitiator else {
            print("Connection failed (non-initiator), keeping signaling open for initiator retry")
            // Only clean up WebRTC, keep signaling connection open
            webRTCService?.close()
            webRTCService = nil
            // Don't change state or close signaling - let initiator retry
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

        // Only clean up WebRTC, keep signaling connection for retry
        webRTCService?.close()
        webRTCService = nil

        // Exponential backoff for reconnect, then set up WebRTC again
        let delay = pow(2.0, Double(reconnectAttempts - 1))
        let workItem = DispatchWorkItem { [weak self] in
            DispatchQueue.main.async {
                guard let self = self, self.signalingConnection?.state == .ready else {
                    // Signaling connection lost, do full reconnect
                    self?.cleanupConnection()
                    if let peer = self?.lastConnectedPeer {
                        self?.connect(to: peer)
                    }
                    return
                }
                // Signaling still good, just retry WebRTC
                print("Retrying WebRTC setup over existing signaling connection")
                self.setupWebRTC(isInitiator: true)
            }
        }
        reconnectWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func cleanupConnection() {
        connectionTimeoutItem?.cancel()
        connectionTimeoutItem = nil
        webRTCService?.close()
        webRTCService = nil
        signalingConnection?.cancel()
        signalingConnection = nil
    }

    // MARK: - Signaling Protocol

    private enum SignalingMessage: Codable {
        case hello(String)  // Exchange display names
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
        guard let connection = signalingConnection else {
            print("Cannot send signaling message - no connection")
            return
        }

        print("Sending signaling message: \(message)")
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
                    DispatchQueue.main.async {
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
            print("Received signaling message: \(message)")

            switch message {
            case .hello(let peerName):
                // Update the connected peer's name
                print("Received hello from: \(peerName)")
                if let currentPeer = connectedPeer {
                    connectedPeer = Peer(id: currentPeer.id, name: peerName, endpoint: currentPeer.endpoint)
                }

            case .sdp(let wrapper):
                let sdp = wrapper.toRTCSessionDescription()
                print("Received SDP type: \(sdp.type.rawValue) (0=offer, 1=pranswer, 2=answer)")
                if sdp.type == .offer {
                    // If we don't have a WebRTC service (e.g., after a retry), create one
                    if webRTCService == nil {
                        print("Received offer but no WebRTC service, creating new one (non-initiator)")
                        setupWebRTC(isInitiator: false)
                    }
                    print("Handling offer with WebRTC service: \(webRTCService != nil)")
                    webRTCService?.handleOffer(sdp)
                } else if sdp.type == .answer {
                    print("Handling answer with WebRTC service: \(webRTCService != nil)")
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
                remoteDisconnectReceived = true
                // Trigger closing animation - completeDisconnect will be called when animation finishes
                portalTransitionState = .closing
            }
        } catch {
            print("Failed to decode signaling message: \(error)")
            if let str = String(data: data, encoding: .utf8) {
                print("Raw message data: \(str)")
            }
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
