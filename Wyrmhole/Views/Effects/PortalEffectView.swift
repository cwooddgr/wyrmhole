import SwiftUI
import UIKit

/// A UIViewRepresentable that wraps a CAEmitterLayer particle effect for the portal iris animation
struct PortalEffectView: UIViewRepresentable {
    let isOpening: Bool
    let isAnimating: Bool
    let onAnimationComplete: () -> Void

    static let animationDuration: TimeInterval = 1.5

    func makeUIView(context: Context) -> PortalEffectUIView {
        let view = PortalEffectUIView()
        view.onAnimationComplete = onAnimationComplete
        return view
    }

    func updateUIView(_ uiView: PortalEffectUIView, context: Context) {
        if isAnimating {
            uiView.requestAnimation(isOpening: isOpening)
        }
    }
}

class PortalEffectUIView: UIView {
    private var emitterLayer: CAEmitterLayer?
    private var irisLayer: CAShapeLayer?
    private var displayLink: CADisplayLink?
    private var animationStartTime: CFTimeInterval = 0
    private var animationIsOpening: Bool = true
    private var hasStartedAnimation = false
    private var maxRadius: CGFloat = 0
    private var pendingAnimation: Bool = false
    private var pendingIsOpening: Bool = true

    var onAnimationComplete: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black  // Start with black background for opening
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        // Update layer frames if they exist
        irisLayer?.frame = bounds
        emitterLayer?.frame = bounds
        emitterLayer?.emitterPosition = CGPoint(x: bounds.midX, y: bounds.midY)

        // If we have a pending animation and now have valid bounds, start it
        if pendingAnimation && bounds.width > 0 && bounds.height > 0 {
            pendingAnimation = false
            startAnimation(isOpening: pendingIsOpening)
        }
    }

    func requestAnimation(isOpening: Bool) {
        guard !hasStartedAnimation else { return }

        // If bounds aren't ready yet, defer the animation
        if bounds.width == 0 || bounds.height == 0 {
            pendingAnimation = true
            pendingIsOpening = isOpening
            return
        }

        startAnimation(isOpening: isOpening)
    }

    private func startAnimation(isOpening: Bool) {
        guard !hasStartedAnimation else { return }
        hasStartedAnimation = true
        animationIsOpening = isOpening

        // Calculate max radius to cover corners
        maxRadius = sqrt(pow(bounds.width / 2, 2) + pow(bounds.height / 2, 2)) * 1.2
        let center = CGPoint(x: bounds.midX, y: bounds.midY)

        // For opening, we started with black background, now switch to iris layer
        backgroundColor = .clear

        // Create the iris layer - a black shape with a circular hole
        let iris = CAShapeLayer()
        iris.frame = bounds
        iris.fillColor = UIColor.black.cgColor
        iris.fillRule = .evenOdd
        layer.addSublayer(iris)
        irisLayer = iris

        // Set initial iris state
        let initialRadius: CGFloat = isOpening ? 0.1 : maxRadius
        updateIris(center: center, radius: initialRadius)

        // Create and configure the emitter layer
        let emitter = CAEmitterLayer()
        emitter.frame = bounds
        emitter.emitterPosition = center
        emitter.emitterShape = .circle
        emitter.emitterMode = .outline
        emitter.renderMode = .additive

        // Set initial emitter size
        let initialEmitterRadius: CGFloat = isOpening ? 1 : maxRadius
        emitter.emitterSize = CGSize(width: initialEmitterRadius * 2, height: initialEmitterRadius * 2)

        // Create spark particle cell with a name for dynamic updates
        let sparkCell = createSparkCell()
        sparkCell.name = "spark"
        emitter.emitterCells = [sparkCell]

        layer.addSublayer(emitter)
        emitterLayer = emitter

        // Start the display link for manual animation
        animationStartTime = CACurrentMediaTime()
        displayLink = CADisplayLink(target: self, selector: #selector(updateAnimation))
        displayLink?.add(to: .main, forMode: .common)
    }

    @objc private func updateAnimation() {
        let elapsed = CACurrentMediaTime() - animationStartTime
        let duration = PortalEffectView.animationDuration
        var progress = min(elapsed / duration, 1.0)

        // Apply easeInOut timing function
        progress = easeInOut(progress)

        let center = CGPoint(x: bounds.midX, y: bounds.midY)

        // Calculate current radius based on progress
        let currentRadius: CGFloat
        if animationIsOpening {
            currentRadius = maxRadius * progress
        } else {
            currentRadius = maxRadius * (1.0 - progress)
        }

        // Update emitter position and size - emitter ring at current radius
        // emitterSize.width is the diameter of the circle for .circle shape
        emitterLayer?.emitterPosition = center
        emitterLayer?.emitterSize = CGSize(width: max(currentRadius * 2, 2), height: max(currentRadius * 2, 2))

        // Scale birth rate with circumference to ensure full edge coverage
        // Circumference = 2πr, so we need many more particles as radius grows
        let baseBirthRate: Float = 500
        let scaledBirthRate = max(baseBirthRate, Float(currentRadius) * 10)
        emitterLayer?.setValue(scaledBirthRate, forKeyPath: "emitterCells.spark.birthRate")

        // Iris and emitter expand together at the same radius
        updateIris(center: center, radius: currentRadius)

        // Fade out particles near the end of animation
        if progress > 0.85 {
            let fadeProgress = (progress - 0.85) / 0.15
            emitterLayer?.opacity = Float(1.0 - fadeProgress)
        }

        // Check if animation is complete
        if elapsed >= duration {
            displayLink?.invalidate()
            displayLink = nil

            // Small delay to let final particles fade
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.onAnimationComplete?()
            }
        }
    }

    private func easeInOut(_ t: Double) -> Double {
        return t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
    }

    private func updateIris(center: CGPoint, radius: CGFloat) {
        guard bounds.width > 0 && bounds.height > 0 else { return }

        // Create a path that fills the whole view with a circular hole cut out
        let path = UIBezierPath(rect: bounds)
        let circlePath = UIBezierPath(arcCenter: center, radius: max(radius, 1), startAngle: 0, endAngle: .pi * 2, clockwise: true)
        path.append(circlePath)
        irisLayer?.path = path.cgPath
    }

    private func createSparkCell() -> CAEmitterCell {
        let cell = CAEmitterCell()

        // Particle appearance
        cell.contents = createSparkImage().cgImage
        cell.birthRate = 300
        cell.lifetime = 0.3  // Short lifetime so particles stay near the edge
        cell.lifetimeRange = 0.1

        // Color - fire/spark tones
        cell.color = UIColor(red: 1.0, green: 0.6, blue: 0.2, alpha: 1.0).cgColor
        cell.redRange = 0.2
        cell.greenRange = 0.3
        cell.blueRange = 0.1

        // Movement - particles should move outward at roughly the iris expansion rate
        // Iris expands at ~maxRadius/duration = ~700/1.5 = ~467 pts/sec at peak
        // But we want particles to stay near the edge, so give them similar velocity
        // with some randomness for a "spray" effect
        cell.emissionLongitude = 0  // Outward from circle center
        cell.emissionRange = .pi / 4  // 45 degree spread
        cell.velocity = 450  // Match iris expansion rate
        cell.velocityRange = 100  // Some variation

        // Size - larger particles for better edge coverage
        cell.scale = 0.8
        cell.scaleRange = 0.3
        cell.scaleSpeed = -1.0  // Shrink as they move

        // Opacity - fade out
        cell.alphaSpeed = -2.5

        return cell
    }

    private func createSparkImage() -> UIImage {
        let size = CGSize(width: 64, height: 64)
        let renderer = UIGraphicsImageRenderer(size: size)

        return renderer.image { context in
            // Create a radial gradient for the spark
            let colors = [
                UIColor.white.cgColor,
                UIColor(red: 1.0, green: 0.8, blue: 0.4, alpha: 1.0).cgColor,
                UIColor(red: 1.0, green: 0.5, blue: 0.0, alpha: 0.0).cgColor
            ]

            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let locations: [CGFloat] = [0.0, 0.3, 1.0]

            if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: locations) {
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                context.cgContext.drawRadialGradient(
                    gradient,
                    startCenter: center,
                    startRadius: 0,
                    endCenter: center,
                    endRadius: size.width / 2,
                    options: []
                )
            }
        }
    }

    deinit {
        displayLink?.invalidate()
    }
}

#Preview {
    ZStack {
        Color.blue
        PortalEffectView(isOpening: true, isAnimating: true, onAnimationComplete: {})
    }
}
