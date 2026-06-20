import AppKit
import AVFoundation

/// Плавающий круглый «пузырь» с живым превью камеры.
/// Это настоящее окно на экране — оно включается в запись через exceptingWindows,
/// поэтому камера попадает в видео «сбоку» без покадрового композитинга.
final class CameraBubble: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private(set) var panel: NSPanel!
    private let queue = DispatchQueue(label: "screenshotka.camera")
    private let firstFrameLock = NSLock()
    private var firstFrameContinuation: CheckedContinuation<Void, Never>?
    private var previewLayer: AVCaptureVideoPreviewLayer?

    var windowNumber: Int { panel?.windowNumber ?? 0 }

    init?(deviceID: String?, near rect: CGRect) {
        guard let device = (deviceID.flatMap { AVCaptureDevice(uniqueID: $0) }) ?? AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else { return nil }

        super.init()

        session.beginConfiguration()
        session.sessionPreset = .high
        if session.canAddInput(input) { session.addInput(input) }
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
        session.commitConfiguration()

        let size: CGFloat = 150
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: size, height: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isMovableByWindowBackground = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let view = NSView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        view.wantsLayer = true
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        preview.cornerRadius = size / 2
        preview.masksToBounds = true
        preview.borderWidth = 3
        preview.borderColor = NSColor(white: 1, alpha: 0.9).cgColor
        view.layer?.addSublayer(preview)
        previewLayer = preview
        applyMirrorPreview()
        p.contentView = view

        // Левый-нижний угол области (внутри, чтобы попасть в кадр).
        let margin: CGFloat = 16
        p.setFrameOrigin(NSPoint(x: rect.minX + margin, y: rect.minY + margin))
        p.orderFrontRegardless()
        self.panel = p
    }

    func start() async {
        await withCheckedContinuation { continuation in
            firstFrameLock.lock()
            firstFrameContinuation = continuation
            firstFrameLock.unlock()

            queue.async { [weak self] in self?.session.startRunning() }
            DispatchQueue.main.async { [weak self] in self?.applyMirrorPreview() }
            queue.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.finishFirstFrameWait()
            }
        }
    }

    private func applyMirrorPreview() {
        guard let connection = previewLayer?.connection, connection.isVideoMirroringSupported else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = true
    }

    private func finishFirstFrameWait() {
        firstFrameLock.lock()
        let continuation = firstFrameContinuation
        firstFrameContinuation = nil
        firstFrameLock.unlock()
        continuation?.resume()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        finishFirstFrameWait()
    }

    func stop() {
        finishFirstFrameWait()
        queue.async { [weak self] in self?.session.stopRunning() }
        panel?.orderOut(nil)
        panel = nil
    }
}
