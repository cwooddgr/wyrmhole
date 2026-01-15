import SwiftUI
import UIKit

struct PortalView: View {
    @EnvironmentObject var connectionManager: ConnectionManager
    @State private var showControls = false
    @State private var controlsTimer: Timer?

    var body: some View {
        ZStack {
            // Remote video (full screen)
            RemoteVideoView(webRTCService: connectionManager.webRTCService)
                .ignoresSafeArea()

            // Local video (picture-in-picture style, small corner)
            VStack {
                HStack {
                    Spacer()
                    LocalVideoView(webRTCService: connectionManager.webRTCService)
                        .frame(width: 150, height: 200)
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
            // Top bar with connection info
            HStack {
                if let peer = connectionManager.connectedPeer {
                    Label(peer.name, systemImage: "ipad")
                        .font(.headline)
                        .foregroundColor(.white)
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

            // Bottom bar with disconnect button
            HStack {
                Spacer()
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
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        webRTCService?.attachRemoteVideoView(uiView)
    }
}

struct LocalVideoView: UIViewRepresentable {
    let webRTCService: WebRTCService?

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .darkGray
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        webRTCService?.attachLocalVideoView(uiView)
    }
}

#Preview {
    PortalView()
        .environmentObject(ConnectionManager())
}
