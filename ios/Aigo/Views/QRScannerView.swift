import AVFoundation
import SwiftUI
import UIKit

/// Full-screen QR scanner sheet with a cancel button.
struct QRScannerSheet: View {
    let onCode: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var problem: String?

    var body: some View {
        ZStack(alignment: .bottom) {
            QRScannerView(onCode: onCode, onError: { message in
                problem = message
            })
            .ignoresSafeArea()

            VStack(spacing: 12) {
                Text(problem ?? "Point the camera at the QR code on your PC.")
                    .font(.callout)
                    .foregroundStyle(Theme.text)
                    .multilineTextAlignment(.center)
                    .padding(12)
                    .background(Theme.bg.opacity(0.85), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(OutlineButtonStyle())
            }
            .padding(20)
        }
        .background(Color.black.ignoresSafeArea())
    }
}

struct QRScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    let onError: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerViewController {
        let vc = ScannerViewController()
        vc.onCode = onCode
        vc.onError = onError
        return vc
    }

    func updateUIViewController(_ uiViewController: ScannerViewController, context: Context) {}
}

final class ScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    var onError: ((String) -> Void)?

    private let captureSession = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var finished = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configure()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                Task { @MainActor [weak self] in
                    if granted {
                        self?.configure()
                    } else {
                        self?.onError?("Camera access is off. Allow it in Settings, or enter the details by hand.")
                    }
                }
            }
        default:
            onError?("Camera access is off. Allow it in Settings, or enter the details by hand.")
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        let session = captureSession
        DispatchQueue.global(qos: .userInitiated).async {
            if session.isRunning {
                session.stopRunning()
            }
        }
    }

    private func configure() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              captureSession.canAddInput(input) else {
            onError?("No camera is available. Enter the details by hand.")
            return
        }
        captureSession.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard captureSession.canAddOutput(output) else {
            onError?("The camera can't scan codes right now.")
            return
        }
        captureSession.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
        if output.availableMetadataObjectTypes.contains(.qr) {
            output.metadataObjectTypes = [.qr]
        }
        let layer = AVCaptureVideoPreviewLayer(session: captureSession)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        previewLayer = layer
        let session = captureSession
        DispatchQueue.global(qos: .userInitiated).async {
            session.startRunning()
        }
    }

    nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput,
                                    didOutput metadataObjects: [AVMetadataObject],
                                    from connection: AVCaptureConnection) {
        let value = (metadataObjects.first as? AVMetadataMachineReadableCodeObject)?.stringValue
        guard let value = value else { return }
        Task { @MainActor [weak self] in
            self?.deliver(value)
        }
    }

    private func deliver(_ value: String) {
        guard !finished else { return }
        finished = true
        let session = captureSession
        DispatchQueue.global(qos: .userInitiated).async {
            session.stopRunning()
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        onCode?(value)
    }
}
