import AVFoundation
import SwiftUI

struct PairingView: View {
    @Environment(SnapshotSyncCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss
    @State private var manualCode = ""
    @State private var error: String?
    @State private var scannerAuthorized = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    Text("Scan the QR code shown in **CodexBar → Settings → iPhone Sync** on your Mac, or paste the pairing code.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)

                    QRScannerView { code in self.tryPair(code) }
                        .frame(height: 260)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .strokeBorder(.white.opacity(0.15), lineWidth: 1))
                        .overlay(alignment: .bottom) {
                            Text("Point at the QR code")
                                .font(.caption)
                                .padding(6)
                                .background(.ultraThinMaterial, in: Capsule())
                                .padding(8)
                        }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("OR ENTER CODE")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        HStack {
                            TextField("cbp1.…", text: self.$manualCode)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .font(.system(.footnote, design: .monospaced))
                                .padding(10)
                                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10))
                            Button("Pair") { self.tryPair(self.manualCode) }
                                .buttonStyle(.glassProminent)
                                .disabled(self.manualCode.isEmpty)
                        }
                    }
                    .padding(.horizontal)

                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                .padding(.vertical)
            }
            .navigationTitle("Pair a Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { self.dismiss() } }
            }
        }
    }

    private func tryPair(_ code: String) {
        do {
            try self.coordinator.pair(code: code)
            self.dismiss()
        } catch {
            self.error = "That code isn't valid. Make sure you copied the whole code."
        }
    }
}

/// Live camera QR scanner. Falls back to a placeholder when the camera is unavailable or denied,
/// so manual code entry always works.
struct QRScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let controller = ScannerController()
        controller.onCode = self.onCode
        return controller
    }

    func updateUIViewController(_: ScannerController, context _: Context) {}

    final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var onCode: ((String) -> Void)?
        nonisolated(unsafe) private let session = AVCaptureSession()
        private var didEmit = false

        /// Camera session start must run off the main thread; `nonisolated(unsafe)` lets us hand the
        /// session to a background queue without a Sendable wrapper (AVCaptureSession is thread-safe).
        private func startCapture() {
            let session = self.session
            DispatchQueue.global(qos: .userInitiated).async {
                session.startRunning()
            }
        }

        override func viewDidLoad() {
            super.viewDidLoad()
            self.view.backgroundColor = .black
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard granted else { return }
                DispatchQueue.main.async { self?.configure() }
            }
        }

        private func configure() {
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  self.session.canAddInput(input) else { return }
            self.session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard self.session.canAddOutput(output) else { return }
            self.session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]

            let preview = AVCaptureVideoPreviewLayer(session: self.session)
            preview.videoGravity = .resizeAspectFill
            preview.frame = self.view.bounds
            self.view.layer.addSublayer(preview)
            self.startCapture()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            self.view.layer.sublayers?.first?.frame = self.view.bounds
        }

        nonisolated func metadataOutput(
            _: AVCaptureMetadataOutput,
            didOutput objects: [AVMetadataObject],
            from _: AVCaptureConnection)
        {
            guard let obj = objects.first as? AVMetadataMachineReadableCodeObject,
                  let value = obj.stringValue else { return }
            // Only the Sendable String crosses into the actor. Delegate queue is `.main` (set below).
            MainActor.assumeIsolated {
                guard !self.didEmit else { return }
                self.didEmit = true
                self.session.stopRunning()
                self.onCode?(value)
            }
        }
    }
}
