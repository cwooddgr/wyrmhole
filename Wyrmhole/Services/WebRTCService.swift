import Foundation
import UIKit
import AVFoundation
import WebRTC

/// Wrapper around WebRTC for handling peer-to-peer video/audio connections
final class WebRTCService: NSObject, ObservableObject {
    // MARK: - Types

    struct Configuration {
        // For local network, we don't need STUN/TURN servers
        // but we include Google's public STUN server as a fallback
        static let iceServers: [RTCIceServer] = [
            RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"])
        ]

        static let mediaConstraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: ["DtlsSrtpKeyAgreement": "true"]
        )
    }

    enum State {
        case idle
        case creatingOffer
        case awaitingAnswer
        case creatingAnswer
        case connecting
        case connected
        case disconnected
        case failed(Error)
    }

    // MARK: - Published Properties

    @Published private(set) var state: State = .idle
    @Published private(set) var isAudioEnabled: Bool = true
    @Published private(set) var isVideoEnabled: Bool = true

    // MARK: - Callbacks

    var onLocalIceCandidate: ((RTCIceCandidate) -> Void)?
    var onLocalSessionDescription: ((RTCSessionDescription) -> Void)?
    var onConnectionStateChanged: ((State) -> Void)?

    // MARK: - Private Properties

    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        let videoEncoderFactory = RTCDefaultVideoEncoderFactory()
        let videoDecoderFactory = RTCDefaultVideoDecoderFactory()
        return RTCPeerConnectionFactory(
            encoderFactory: videoEncoderFactory,
            decoderFactory: videoDecoderFactory
        )
    }()

    private var peerConnection: RTCPeerConnection?
    private var localVideoTrack: RTCVideoTrack?
    private var localAudioTrack: RTCAudioTrack?
    private var remoteVideoTrack: RTCVideoTrack?

    private var videoCapturer: RTCCameraVideoCapturer?
    private var localVideoView: UIView?
    private var remoteVideoView: UIView?

    private let rtcAudioSession = RTCAudioSession.sharedInstance()

    // MARK: - Initialization

    override init() {
        super.init()
        configureAudioSession()
    }

    // MARK: - Public Methods

    /// Set up the peer connection and local media
    func setup() {
        let config = RTCConfiguration()
        config.iceServers = Configuration.iceServers
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherContinually

        // For local network, prioritize local candidates
        config.iceTransportPolicy = .all

        let constraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: nil
        )

        guard let peerConnection = Self.factory.peerConnection(
            with: config,
            constraints: constraints,
            delegate: self
        ) else {
            state = .failed(WebRTCError.failedToCreatePeerConnection)
            return
        }

        self.peerConnection = peerConnection
        setupLocalMedia()
    }

    /// Create an offer to send to the remote peer
    func createOffer() {
        guard let peerConnection = peerConnection else { return }

        state = .creatingOffer

        let constraints = RTCMediaConstraints(
            mandatoryConstraints: [
                "OfferToReceiveAudio": "true",
                "OfferToReceiveVideo": "true"
            ],
            optionalConstraints: nil
        )

        peerConnection.offer(for: constraints) { [weak self] sdp, error in
            guard let self = self else { return }

            if let error = error {
                DispatchQueue.main.async {
                    self.state = .failed(error)
                }
                return
            }

            guard let sdp = sdp else { return }

            peerConnection.setLocalDescription(sdp) { error in
                if let error = error {
                    DispatchQueue.main.async {
                        self.state = .failed(error)
                    }
                    return
                }

                DispatchQueue.main.async {
                    self.state = .awaitingAnswer
                    self.onLocalSessionDescription?(sdp)
                }
            }
        }
    }

    /// Handle an incoming offer and create an answer
    func handleOffer(_ sdp: RTCSessionDescription) {
        guard let peerConnection = peerConnection else { return }

        state = .creatingAnswer

        peerConnection.setRemoteDescription(sdp) { [weak self] error in
            guard let self = self else { return }

            if let error = error {
                DispatchQueue.main.async {
                    self.state = .failed(error)
                }
                return
            }

            self.createAnswer()
        }
    }

    /// Handle an incoming answer
    func handleAnswer(_ sdp: RTCSessionDescription) {
        guard let peerConnection = peerConnection else { return }

        peerConnection.setRemoteDescription(sdp) { [weak self] error in
            if let error = error {
                DispatchQueue.main.async {
                    self?.state = .failed(error)
                }
            }
        }
    }

    /// Add a received ICE candidate
    func addIceCandidate(_ candidate: RTCIceCandidate) {
        peerConnection?.add(candidate) { error in
            if let error = error {
                print("Failed to add ICE candidate: \(error)")
            }
        }
    }

    /// Attach a view to display the local video
    func attachLocalVideoView(_ view: UIView) {
        localVideoView = view

        // Remove any existing renderer
        view.subviews.forEach { $0.removeFromSuperview() }

        let renderer = RTCMTLVideoView(frame: view.bounds)
        renderer.videoContentMode = .scaleAspectFill
        renderer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(renderer)

        localVideoTrack?.add(renderer)
    }

    /// Attach a view to display the remote video
    func attachRemoteVideoView(_ view: UIView) {
        remoteVideoView = view

        // Remove any existing renderer
        view.subviews.forEach { $0.removeFromSuperview() }

        let renderer = RTCMTLVideoView(frame: view.bounds)
        renderer.videoContentMode = .scaleAspectFill
        renderer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(renderer)

        remoteVideoTrack?.add(renderer)
    }

    /// Toggle audio on/off
    func toggleAudio() {
        isAudioEnabled.toggle()
        localAudioTrack?.isEnabled = isAudioEnabled
    }

    /// Toggle video on/off
    func toggleVideo() {
        isVideoEnabled.toggle()
        localVideoTrack?.isEnabled = isVideoEnabled
    }

    /// Clean up and close the connection
    func close() {
        videoCapturer?.stopCapture()
        peerConnection?.close()
        peerConnection = nil
        localVideoTrack = nil
        localAudioTrack = nil
        remoteVideoTrack = nil
        state = .disconnected
    }

    // MARK: - Private Methods

    private func configureAudioSession() {
        let audioSession = AVAudioSession.sharedInstance()
        rtcAudioSession.lockForConfiguration()
        do {
            try audioSession.setCategory(.playAndRecord, mode: .videoChat, options: [.defaultToSpeaker, .allowBluetooth])
            try audioSession.setActive(true)
        } catch {
            print("Failed to configure audio session: \(error)")
        }
        rtcAudioSession.unlockForConfiguration()
    }

    private func setupLocalMedia() {
        setupLocalAudio()
        setupLocalVideo()
    }

    private func setupLocalAudio() {
        let audioConstraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: nil
        )
        let audioSource = Self.factory.audioSource(with: audioConstraints)
        let audioTrack = Self.factory.audioTrack(with: audioSource, trackId: "audio0")

        peerConnection?.add(audioTrack, streamIds: ["stream0"])
        localAudioTrack = audioTrack
    }

    private func setupLocalVideo() {
        let videoSource = Self.factory.videoSource()

        #if targetEnvironment(simulator)
        // Use a test pattern for simulator
        #else
        let capturer = RTCCameraVideoCapturer(delegate: videoSource)
        videoCapturer = capturer

        // Find the front camera
        guard let frontCamera = RTCCameraVideoCapturer.captureDevices().first(where: {
            $0.position == .front
        }) else {
            print("No front camera found")
            return
        }

        // Find a suitable format (prefer 720p for balance of quality and performance)
        let formats = RTCCameraVideoCapturer.supportedFormats(for: frontCamera)
        let targetWidth: Int32 = 1280
        let targetHeight: Int32 = 720

        guard let format = formats.first(where: { format in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return dimensions.width == targetWidth && dimensions.height == targetHeight
        }) ?? formats.last else {
            print("No suitable video format found")
            return
        }

        // Target 30fps for good quality
        let fps = min(format.videoSupportedFrameRateRanges.first?.maxFrameRate ?? 30, 30)

        capturer.startCapture(with: frontCamera, format: format, fps: Int(fps))
        #endif

        let videoTrack = Self.factory.videoTrack(with: videoSource, trackId: "video0")
        peerConnection?.add(videoTrack, streamIds: ["stream0"])
        localVideoTrack = videoTrack
    }

    private func createAnswer() {
        guard let peerConnection = peerConnection else { return }

        let constraints = RTCMediaConstraints(
            mandatoryConstraints: [
                "OfferToReceiveAudio": "true",
                "OfferToReceiveVideo": "true"
            ],
            optionalConstraints: nil
        )

        peerConnection.answer(for: constraints) { [weak self] sdp, error in
            guard let self = self else { return }

            if let error = error {
                DispatchQueue.main.async {
                    self.state = .failed(error)
                }
                return
            }

            guard let sdp = sdp else { return }

            peerConnection.setLocalDescription(sdp) { error in
                if let error = error {
                    DispatchQueue.main.async {
                        self.state = .failed(error)
                    }
                    return
                }

                DispatchQueue.main.async {
                    self.state = .connecting
                    self.onLocalSessionDescription?(sdp)
                }
            }
        }
    }
}

// MARK: - RTCPeerConnectionDelegate

extension WebRTCService: RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        print("Signaling state changed: \(stateChanged.rawValue)")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        print("Stream added: \(stream.streamId)")

        DispatchQueue.main.async { [weak self] in
            if let videoTrack = stream.videoTracks.first {
                self?.remoteVideoTrack = videoTrack

                // Attach to view if already set
                if let view = self?.remoteVideoView {
                    self?.attachRemoteVideoView(view)
                }
            }
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {
        print("Stream removed: \(stream.streamId)")
    }

    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {
        print("Negotiation needed")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        print("ICE connection state changed: \(newState.rawValue)")

        DispatchQueue.main.async { [weak self] in
            switch newState {
            case .connected, .completed:
                self?.state = .connected
            case .disconnected:
                self?.state = .disconnected
            case .failed:
                self?.state = .failed(WebRTCError.iceConnectionFailed)
            case .closed:
                self?.state = .disconnected
            default:
                break
            }
            self?.onConnectionStateChanged?(self?.state ?? .disconnected)
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        print("ICE gathering state changed: \(newState.rawValue)")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        print("Generated ICE candidate: \(candidate.sdp)")
        DispatchQueue.main.async { [weak self] in
            self?.onLocalIceCandidate?(candidate)
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {
        print("Removed \(candidates.count) ICE candidates")
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        print("Data channel opened: \(dataChannel.label)")
    }
}

// MARK: - Errors

enum WebRTCError: LocalizedError {
    case failedToCreatePeerConnection
    case iceConnectionFailed

    var errorDescription: String? {
        switch self {
        case .failedToCreatePeerConnection:
            return "Failed to create peer connection"
        case .iceConnectionFailed:
            return "ICE connection failed"
        }
    }
}
