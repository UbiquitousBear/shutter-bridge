import SwiftUI
import UIKit
import Vision
import VisionKit

/// Day 9: scans the pairing QR code the camera shows (`Network → Cnct./PC Remote → Smartphone Connect`) with
/// VisionKit's DataScannerViewController and hands back the first QR payload. The payload carries the Wi-Fi
/// password: the caller parses it with CameraQRCode and never logs or saves it.
struct QRScannerView: UIViewControllerRepresentable {
    let onPayload: (String) -> Void
    let onFailure: (String) -> Void

    /// Why scanning can't start on this device right now, or nil if it can.
    @MainActor static var unavailableReason: String? {
        if !DataScannerViewController.isSupported {
            return "this iPhone doesn't support DataScannerViewController (needs an A12 chip or later)"
        }
        if !DataScannerViewController.isAvailable {
            return "camera access is denied or restricted (Settings → SB Spike → Camera, or Screen Time)"
        }
        return nil
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onPayload: onPayload, onFailure: onFailure)
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        context.coordinator.onPayload = onPayload
        context.coordinator.onFailure = onFailure
        guard !scanner.isScanning, !context.coordinator.finished else { return }
        do {
            try scanner.startScanning()
        } catch {
            context.coordinator.fail("startScanning failed: \(error)")
        }
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        if scanner.isScanning { scanner.stopScanning() }
    }

    /// DataScannerViewControllerDelegate is main-actor isolated, like this class.
    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var onPayload: (String) -> Void
        var onFailure: (String) -> Void
        private(set) var finished = false

        init(onPayload: @escaping (String) -> Void, onFailure: @escaping (String) -> Void) {
            self.onPayload = onPayload
            self.onFailure = onFailure
            super.init()
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            deliverFirstPayload(in: addedItems, from: dataScanner)
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didUpdate updatedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            deliverFirstPayload(in: updatedItems, from: dataScanner)
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didRemove removedItems: [RecognizedItem], allItems: [RecognizedItem]) {}

        func dataScannerDidZoom(_ dataScanner: DataScannerViewController) {}

        func dataScanner(_ dataScanner: DataScannerViewController, didTapOn item: RecognizedItem) {
            deliverFirstPayload(in: [item], from: dataScanner)
        }

        func dataScanner(_ dataScanner: DataScannerViewController, becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) {
            fail("the scanner became unavailable: \(error)")
        }

        private func deliverFirstPayload(in items: [RecognizedItem], from scanner: DataScannerViewController) {
            guard !finished else { return }
            for item in items {
                guard case .barcode(let barcode) = item, let payload = barcode.payloadStringValue, !payload.isEmpty else { continue }
                finished = true
                scanner.stopScanning()
                onPayload(payload)
                return
            }
        }

        func fail(_ message: String) {
            guard !finished else { return }
            finished = true
            onFailure(message)
        }
    }
}

/// The scanner in a sheet, with Cancel and a hint about where the camera shows its code.
struct QRScannerSheet: View {
    let onPayload: (String) -> Void
    let onFailure: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            QRScannerView(onPayload: onPayload, onFailure: onFailure)
                .ignoresSafeArea(edges: .bottom)
                .overlay(alignment: .bottom) {
                    Text("On the camera: Network → Cnct./PC Remote → Smartphone Connect shows the code.")
                        .font(.footnote)
                        .padding(10)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
                        .padding()
                }
                .navigationTitle("Scan camera QR code")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", action: onCancel)
                    }
                }
        }
    }
}
