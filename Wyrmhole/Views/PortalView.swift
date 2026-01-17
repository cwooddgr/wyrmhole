import SwiftUI
import UIKit

struct PortalView: View {
    @EnvironmentObject var connectionManager: ConnectionManager
    @State private var showControls = false
    @State private var controlsTimer: Timer?

    var body: some View {
        GeometryReader { geometry in
            let isLandscape = geometry.size.width > geometry.size.height
            let previewWidth: CGFloat = isLandscape ? 200 : 120
            let previewHeight: CGFloat = isLandscape ? 150 : 160

            ZStack {
                // Remote video (full screen)
                RemoteVideoView(webRTCService: connectionManager.webRTCService)
                    .ignoresSafeArea()

                // Local video (picture-in-picture style, small corner)
                VStack {
                    HStack {
                        Spacer()
                        LocalVideoView(webRTCService: connectionManager.webRTCService)
                            .frame(width: previewWidth, height: previewHeight)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.white.opacity(0.3), lineWidth: 1)
                            )
                            .shadow(radius: 10)
                            .padding()
                    }
                    Spacer()
                }

                // Controls overlay
                if showControls {
                    controlsOverlay
                }

                // Persistent mute indicator (only when controls are hidden)
                if connectionManager.isAudioMuted && !showControls {
                    VStack {
                        HStack {
                            Image(systemName: "mic.slash.fill")
                                .font(.caption)
                                .foregroundColor(.white)
                                .padding(8)
                                .background(Color.red.opacity(0.8))
                                .clipShape(Circle())
                            Spacer()
                        }
                        .padding()
                        Spacer()
                    }
                }

                // Persistent peer name at bottom (always visible)
                if let peer = connectionManager.connectedPeer {
                    VStack {
                        Spacer()
                        Text(peer.name)
                            .font(.title3.weight(.medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(
                                Capsule()
                                    .fill(Color.black.opacity(0.5))
                            )
                            .padding(.bottom, showControls ? 120 : 40)
                            .animation(.easeInOut(duration: 0.2), value: showControls)
                    }
                }
            }
        }
        .persistentSystemOverlays(.hidden)
        .statusBarHidden(true)
        .onTapGesture {
            showControlsTemporarily()
        }
        .onAppear {
            // Keep screen awake
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            controlsTimer?.invalidate()
        }
    }

    private var controlsOverlay: some View {
        VStack {
            // Top bar with mute indicator and signal strength
            HStack {
                if connectionManager.isAudioMuted {
                    Image(systemName: "mic.slash.fill")
                        .font(.caption)
                        .foregroundColor(.white)
                        .padding(8)
                        .background(Color.red.opacity(0.8))
                        .clipShape(Circle())
                }
                Spacer()
                connectionQualityIndicator
            }
            .padding()
            .background(
                LinearGradient(
                    colors: [Color.black.opacity(0.7), Color.clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )

            Spacer()

            // Bottom bar with controls
            HStack(spacing: 24) {
                Spacer()

                // Mute button
                Button {
                    connectionManager.toggleMute()
                } label: {
                    Image(systemName: connectionManager.isAudioMuted ? "mic.slash" : "mic")
                        .font(.title2)
                        .foregroundColor(.white)
                        .padding()
                        .background(connectionManager.isAudioMuted ? Color.orange : Color.gray.opacity(0.6))
                        .clipShape(Circle())
                }

                // End button
                Button {
                    connectionManager.disconnect()
                } label: {
                    Label("End", systemImage: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(.white)
                        .padding()
                        .background(Color.red)
                        .clipShape(Capsule())
                }

                Spacer()
            }
            .padding()
            .background(
                LinearGradient(
                    colors: [Color.clear, Color.black.opacity(0.7)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
    }

    private var connectionQualityIndicator: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { index in
                RoundedRectangle(cornerRadius: 2)
                    .fill(index < connectionManager.signalStrength ? Color.green : Color.gray)
                    .frame(width: 4, height: CGFloat(8 + index * 4))
            }
        }
    }

    private func showControlsTemporarily() {
        showControls = true
        controlsTimer?.invalidate()
        controlsTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { _ in
            withAnimation {
                showControls = false
            }
        }
    }
}

// MARK: - Video Views (UIKit wrappers for WebRTC video)

struct RemoteVideoView: UIViewRepresentable {
    let webRTCService: WebRTCService?

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        // Attach immediately when view is created
        webRTCService?.attachRemoteVideoView(view)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // Only re-attach if not already attached (subview count check)
        if uiView.subviews.isEmpty {
            webRTCService?.attachRemoteVideoView(uiView)
        }
    }
}

struct LocalVideoView: UIViewRepresentable {
    let webRTCService: WebRTCService?

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .darkGray
        // Attach immediately when view is created
        webRTCService?.attachLocalVideoView(view)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // Only re-attach if not already attached (subview count check)
        if uiView.subviews.isEmpty {
            webRTCService?.attachLocalVideoView(uiView)
        }
    }
}

#Preview {
    PortalView()
        .environmentObject(ConnectionManager())
}
