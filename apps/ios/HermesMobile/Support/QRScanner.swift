@preconcurrency import AVFoundation
import SwiftUI
import UIKit

/// A live camera preview that scans QR codes and reports the first decoded
/// string back to SwiftUI.
///

/// Wraps `AVCaptureSession` + `AVCaptureMetadataOutput` (QR object type) behind
/// a `UIViewRepresentable`. The owning view (``QRScannerView``) handles camera
/// permission gating, the torch toggle, and the success transition; this type is
/// just the capture surface.
///

/// Concurrency: `AVCaptureSession.startRunning()` blocks, so it runs on a
/// dedicated serial queue, never the main actor. The metadata delegate callback
/// is `nonisolated` and hops to the main actor to deliver the payload. Camera
/// usage is already declared (`NSCameraUsageDescription`), shared with the photo
/// and document-scan paths.
struct QRCameraView: UIViewRepresentable {
    /// Called once with the decoded payload of the first QR code seen. The
    /// coordinator latches after the first hit so a steady code doesn't fire
    /// repeatedly; the owning view tears the scanner down on success.
    let onScan: (String) -> Void
    /// Called if the camera can't be configured (no device, input/output add
    /// failed). The owning view surfaces a fallback.
    var onError: ((String) -> Void)? = nil
    /// Whether the torch should be on. Bound from the owning view's toggle.
    let torchOn: Bool

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        context.coordinator.configure(previewView: view)
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        context.coordinator.setTorch(torchOn)
    }

    static func dismantleUIView(_ uiView: PreviewView, coordinator: Coordinator) {
        coordinator.stop()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onScan: onScan, onError: onError)
    }

    // MARK: - Preview view (its layer IS the AVCaptureVideoPreviewLayer)

    /// A `UIView` whose backing layer is an `AVCaptureVideoPreviewLayer`, so the
    /// preview fills the view and resizes with it automatically.
    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

        var previewLayer: AVCaptureVideoPreviewLayer {
            // Safe: layerClass guarantees this cast.
            layer as! AVCaptureVideoPreviewLayer  // swiftlint:disable:this force_cast
        }
    }

    // MARK: - Coordinator (capture session owner + metadata delegate)

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        private let onScan: (String) -> Void
        private let onError: ((String) -> Void)?

        private let session = AVCaptureSession()
        /// Serial queue for blocking session start/stop and torch toggles.
        private let sessionQueue = DispatchQueue(label: "hermes.qrscanner.session")
        private weak var captureDevice: AVCaptureDevice?
        /// Latches true once a code is delivered so we report exactly once.
        private var didScan = false

        init(onScan: @escaping (String) -> Void, onError: ((String) -> Void)?) {
            self.onScan = onScan
            self.onError = onError
        }

        /// Build the input/output graph and start running. Idempotent-safe: only
        /// called once from `makeUIView`.
        @MainActor func configure(previewView: PreviewView) {
            previewView.previewLayer.session = session
            previewView.previewLayer.videoGravity = .resizeAspectFill

            guard let device = AVCaptureDevice.default(for: .video) else {
                onError?("No camera available on this device.")
                return
            }
            captureDevice = device

            let input: AVCaptureDeviceInput
            do {
                input = try AVCaptureDeviceInput(device: device)
            } catch {
                onError?("Couldn't access the camera.")
                return
            }

            session.beginConfiguration()
            guard session.canAddInput(input) else {
                session.commitConfiguration()
                onError?("Couldn't start the camera.")
                return
            }
            session.addInput(input)

            let metadataOutput = AVCaptureMetadataOutput()
            guard session.canAddOutput(metadataOutput) else {
                session.commitConfiguration()
                onError?("Couldn't read QR codes on this device.")
                return
            }
            session.addOutput(metadataOutput)
            metadataOutput.setMetadataObjectsDelegate(self, queue: .main)
            // Set availableMetadataObjectTypes AFTER adding the output, or .qr
            // isn't yet in the available set and the assignment is dropped.
            metadataOutput.metadataObjectTypes = [.qr]
            session.commitConfiguration()

            sessionQueue.async { [session] in
                if !session.isRunning { session.startRunning() }
            }
        }

        /// Stop the running session (called on dismantle).
        func stop() {
            sessionQueue.async { [session] in
                if session.isRunning { session.stopRunning() }
            }
        }

        /// Toggle the torch if the device supports it. No-op otherwise.
        func setTorch(_ on: Bool) {
            guard let device = captureDevice, device.hasTorch, device.isTorchAvailable else {
                return
            }
            sessionQueue.async {
                do {
                    try device.lockForConfiguration()
                    device.torchMode = on ? .on : .off
                    device.unlockForConfiguration()
                } catch {
                    // Torch is best-effort; ignore lock failures.
                }
            }
        }

        // MARK: AVCaptureMetadataOutputObjectsDelegate

        /// Delegate fires on the main queue (set above). Deliver the first QR
        /// payload exactly once.
        func metadataOutput(
            _ output: AVCaptureMetadataOutput,
            didOutput metadataObjects: [AVMetadataObject],
            from connection: AVCaptureConnection
        ) {
            guard !didScan else { return }
            guard
                let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                object.type == .qr,
                let payload = object.stringValue,
                !payload.isEmpty
            else { return }

            didScan = true
            onScan(payload)
        }
    }
}

// MARK: - Permission helper

/// Thin async wrapper over `AVCaptureDevice` camera-authorization so the view
/// can `await` the current/just-granted state without juggling callbacks.
enum CameraPermission {
    enum Status: Equatable {
        case authorized
        case denied
        case undetermined
    }

    /// The current authorization status mapped to our three-state model.
    static var current: Status {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .authorized
        case .denied, .restricted: return .denied
        case .notDetermined: return .undetermined
        @unknown default: return .denied
        }
    }

    /// Request access if undetermined; returns the resolved status.
    static func request() async -> Status {
        switch current {
        case .authorized: return .authorized
        case .denied: return .denied
        case .undetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            return granted ? .authorized : .denied
        }
    }
}
