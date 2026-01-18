import SwiftUI

/// Wrapper view that orchestrates the portal iris transition effect
struct PortalTransitionView: View {
    @EnvironmentObject var connectionManager: ConnectionManager
    @State private var transitionState: PortalTransitionState = .closed
    @State private var showEffect = true

    var body: some View {
        ZStack {
            // The actual portal view (video)
            PortalView()
                .opacity(transitionState == .closed ? 0 : 1)

            // Portal effect overlay
            if showEffect {
                PortalEffectView(
                    isOpening: transitionState == .opening,
                    isAnimating: transitionState == .opening || transitionState == .closing,
                    onAnimationComplete: handleAnimationComplete
                )
                .allowsHitTesting(false)
            }
        }
        .onAppear {
            // Start opening animation when view appears
            startOpeningAnimation()
        }
        .onChange(of: connectionManager.portalTransitionState) { newState in
            if newState == .closing && (transitionState == .open || transitionState == .opening) {
                startClosingAnimation()
            }
        }
    }

    private func startOpeningAnimation() {
        transitionState = .opening
        showEffect = true
    }

    private func startClosingAnimation() {
        transitionState = .closing
        showEffect = true
    }

    private func handleAnimationComplete() {
        switch transitionState {
        case .opening:
            transitionState = .open
            // Remove the effect layer for clean video view
            showEffect = false

        case .closing:
            transitionState = .closed
            // Notify connection manager that closing animation is complete
            connectionManager.completeDisconnect()

        default:
            break
        }
    }
}

#Preview {
    PortalTransitionView()
        .environmentObject(ConnectionManager())
}
