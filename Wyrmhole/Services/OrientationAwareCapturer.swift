import AVFoundation
import UIKit
import WebRTC

/// Custom video capturer that uses UIWindowScene.interfaceOrientation instead of UIDevice.current.orientation
/// This fixes iOS 16 where device orientation is unreliable at app launch
final class OrientationAwareCapturer: RTCVideoCapturer, AVCaptureVideoDataOutputSampleBufferDelegate {

    private let captureSession = AVCaptureSession()
    private let captureQueue = DispatchQueue(label: "com.wyrmhole.capture")
    private var currentDevice: AVCaptureDevice?
    private var currentRotation: RTCVideoRotation = ._0

    override init(delegate: RTCVideoCapturerDelegate) {
        super.init(delegate: delegate)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(orientationDidChange),
            name: UIDevice.orientationDidChangeNotification,
            object: nil
        )

        DispatchQueue.main.async { [weak self] in
            self?.updateRotation()
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func orientationDidChange() {
        DispatchQueue.main.async { [weak self] in
            self?.updateRotation()
        }
    }

    private func updateRotation() {
        currentRotation = calculateVideoRotation()
    }

    func startCapture(with device: AVCaptureDevice, format: AVCaptureDevice.Format, fps: Int) {
        currentDevice = device

        DispatchQueue.main.async { [weak self] in
            self?.updateRotation()
        }

        captureQueue.async { [weak self] in
            self?.setupCaptureSession(device: device, format: format, fps: fps)
        }
    }

    func stopCapture() {
        captureQueue.async { [weak self] in
            self?.captureSession.stopRunning()
        }
    }

    private func setupCaptureSession(device: AVCaptureDevice, format: AVCaptureDevice.Format, fps: Int) {
        captureSession.beginConfiguration()

        captureSession.inputs.forEach { captureSession.removeInput($0) }
        captureSession.outputs.forEach { captureSession.removeOutput($0) }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            if captureSession.canAddInput(input) {
                captureSession.addInput(input)
            }
        } catch {
            print("Failed to create capture input: \(error)")
            captureSession.commitConfiguration()
            return
        }

        do {
            try device.lockForConfiguration()
            device.activeFormat = format

            let frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
            device.activeVideoMinFrameDuration = frameDuration
            device.activeVideoMaxFrameDuration = frameDuration

            device.unlockForConfiguration()
        } catch {
            print("Failed to configure capture device: \(error)")
        }

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        output.setSampleBufferDelegate(self, queue: captureQueue)
        output.alwaysDiscardsLateVideoFrames = true

        if captureSession.canAddOutput(output) {
            captureSession.addOutput(output)
        }

        captureSession.commitConfiguration()
        captureSession.startRunning()
    }

    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let timeStampNs = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)) * Double(NSEC_PER_SEC)

        let rtcPixelBuffer = RTCCVPixelBuffer(pixelBuffer: pixelBuffer)
        let frame = RTCVideoFrame(
            buffer: rtcPixelBuffer,
            rotation: currentRotation,
            timeStampNs: Int64(timeStampNs)
        )

        delegate?.capturer(self, didCapture: frame)
    }

    private func calculateVideoRotation() -> RTCVideoRotation {
        let interfaceOrientation = getInterfaceOrientation()
        let isFrontCamera = currentDevice?.position == .front

        switch interfaceOrientation {
        case .portrait:
            return ._90
        case .portraitUpsideDown:
            return ._270
        case .landscapeLeft:
            return isFrontCamera ? ._0 : ._180
        case .landscapeRight:
            return isFrontCamera ? ._180 : ._0
        case .unknown:
            let bounds = UIScreen.main.bounds
            if bounds.width > bounds.height {
                return isFrontCamera ? ._180 : ._0
            } else {
                return ._90
            }
        @unknown default:
            return ._90
        }
    }

    private func getInterfaceOrientation() -> UIInterfaceOrientation {
        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first else {
            return .unknown
        }
        return windowScene.interfaceOrientation
    }
}
