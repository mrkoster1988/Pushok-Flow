import AVFoundation
import ImageIO
import PhotosUI
import SwiftUI
import Vision
import VisionKit

enum QRImport {
    static func decode(_ data: Data) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            guard data.count <= 32 * 1024 * 1024,
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways:true,
                    kCGImageSourceCreateThumbnailWithTransform:true,
                    kCGImageSourceThumbnailMaxPixelSize:2400
                  ] as CFDictionary) else { throw AccessError.invalid }
            let request = VNDetectBarcodesRequest()
            request.symbologies = [.qr]
            try VNImageRequestHandler(cgImage: image).perform([request])
            let values = Set((request.results ?? []).compactMap(\.payloadStringValue))
            guard values.count == 1, let value = values.first else { throw AccessError.invalid }
            return value
        }.value
    }
}
struct QRScanner: UIViewControllerRepresentable {
    let onRead: (String) -> Void
    let onFailure: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced, recognizesMultipleItems: false, isGuidanceEnabled: true, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        DispatchQueue.main.async {
            do { try scanner.startScanning() } catch { onFailure() }
        }
        return scanner
    }
    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}
    static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) { controller.stopScanning() }
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let parent: QRScanner
        var done = false
        init(_ parent: QRScanner) { self.parent = parent }
        func dataScanner(_ scanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !done else { return }
            for case .barcode(let barcode) in addedItems {
                if let value = barcode.payloadStringValue {
                    done = true; scanner.stopScanning(); parent.onRead(value); return
                }
            }
        }
        func dataScanner(_ scanner: DataScannerViewController, becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) {
            if !done { done = true; parent.onFailure() }
        }
    }
}
