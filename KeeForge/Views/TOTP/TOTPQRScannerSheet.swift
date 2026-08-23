#if os(iOS)
import AVFoundation
import CryptoKit
import SwiftUI
import VisionKit

/// Camera sheet for TOTP enrollment: scans QR codes with VisionKit's
/// `DataScannerViewController` and calls `onScan` with the first payload that
/// parses as a supported `otpauth://` URI. Non-enrollment QR codes show a
/// transient hint and scanning continues.
struct TOTPQRScannerSheet: View {
    let onScan: (OTPAuthURI) -> Void

    private enum Availability {
        case checking
        case available
        case cameraAccessDenied
        case unsupported
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var availability: Availability = .checking
    @State private var didComplete = false
    @State private var showsInvalidCodeHint = false
    /// Digest, not the payload: a rejected QR code can carry a secret (HOTP,
    /// Steam) that must not be retained just to debounce the hint.
    @State private var lastInvalidPayloadHash: SHA256Digest?
    @State private var hintDismissTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Group {
                switch availability {
                case .checking:
                    ProgressView()
                case .available:
                    scannerContent
                case .cameraAccessDenied:
                    cameraAccessDeniedView
                case .unsupported:
                    ContentUnavailableView(
                        "QR code scanning isn't available on this device.",
                        systemImage: "camera"
                    )
                }
            }
            .navigationTitle("Scan QR Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .accessibilityIdentifier("entry-edit.totp.scan-cancel")
                }
            }
            .task {
                await determineAvailability()
            }
            // Re-check when the user comes back from Settings after changing
            // camera access; the denied state must not be terminal.
            .onChange(of: scenePhase) { _, newPhase in
                guard newPhase == .active else { return }
                Task {
                    await determineAvailability()
                }
            }
            .onDisappear {
                hintDismissTask?.cancel()
            }
        }
    }

    private var scannerContent: some View {
        ZStack(alignment: .bottom) {
            TOTPQRScannerRepresentable(
                onScannedPayload: handleScannedPayload,
                onStartFailed: { availability = .unsupported }
            )
            .ignoresSafeArea()

            if showsInvalidCodeHint {
                Text("Not a verification-code QR code")
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 24)
                    .transition(.opacity)
            }
        }
        .animation(.default, value: showsInvalidCodeHint)
    }

    private var cameraAccessDeniedView: some View {
        ContentUnavailableView {
            Label("Camera Access Needed", systemImage: "camera")
        } description: {
            Text("Allow camera access in Settings to scan verification-code QR codes.")
        } actions: {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
        }
    }

    private func determineAvailability() async {
        guard DataScannerViewController.isSupported else {
            availability = .unsupported
            return
        }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            // Authorized but unavailable is a device/system limitation, not a
            // permission problem; sending the user to Settings would be a lie.
            availability = DataScannerViewController.isAvailable ? .available : .unsupported
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            availability = granted ? .available : .cameraAccessDenied
        default:
            availability = .cameraAccessDenied
        }
    }

    private func handleScannedPayload(_ payload: String) {
        guard didComplete == false else { return }

        if let uri = try? OTPAuthURI(string: payload) {
            didComplete = true
            onScan(uri)
            dismiss()
            return
        }

        // Debounce: the tracked code re-reports while it stays in frame, so
        // an already-hinted payload does not restart the hint.
        let payloadHash = SHA256.hash(data: Data(payload.utf8))
        guard payloadHash != lastInvalidPayloadHash || showsInvalidCodeHint == false else { return }
        lastInvalidPayloadHash = payloadHash
        showsInvalidCodeHint = true
        hintDismissTask?.cancel()
        hintDismissTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard Task.isCancelled == false else { return }
            showsInvalidCodeHint = false
        }
    }
}

private struct TOTPQRScannerRepresentable: UIViewControllerRepresentable {
    let onScannedPayload: (String) -> Void
    let onStartFailed: () -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        context.coordinator.onScannedPayload = onScannedPayload
        context.coordinator.onStartFailed = onStartFailed
        context.coordinator.startScanningIfNeeded(scanner)
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        coordinator.cancelPendingStart()
        scanner.stopScanning()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onScannedPayload: onScannedPayload, onStartFailed: onStartFailed)
    }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var onScannedPayload: (String) -> Void
        var onStartFailed: () -> Void
        private var startTask: Task<Void, Never>?

        init(onScannedPayload: @escaping (String) -> Void, onStartFailed: @escaping () -> Void) {
            self.onScannedPayload = onScannedPayload
            self.onStartFailed = onStartFailed
        }

        /// `startScanning()` fails while the scanner is not yet on screen, so
        /// the attempt hops to a main-actor task (after the current update
        /// pass) and gets one delayed retry; any later update retries again.
        /// Only a still-failing final attempt reports failure, which the sheet
        /// surfaces as the "isn't available on this device" state instead of a
        /// frozen preview.
        func startScanningIfNeeded(_ scanner: DataScannerViewController) {
            guard scanner.isScanning == false, startTask == nil else { return }
            startTask = Task { @MainActor [weak self, weak scanner] in
                defer { self?.startTask = nil }
                for delay in [Duration.zero, .milliseconds(300)] {
                    try? await Task.sleep(for: delay)
                    guard Task.isCancelled == false, let scanner, scanner.isScanning == false else { return }
                    if (try? scanner.startScanning()) != nil { return }
                }
                guard Task.isCancelled == false else { return }
                self?.onStartFailed()
            }
        }

        func cancelPendingStart() {
            startTask?.cancel()
            startTask = nil
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            for item in addedItems {
                if case .barcode(let barcode) = item, let payload = barcode.payloadStringValue {
                    onScannedPayload(payload)
                }
            }
        }
    }
}
#endif
