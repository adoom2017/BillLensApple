import Foundation
@preconcurrency import Vision
import AppKit

public protocol ReceiptTextRecognizing: Sendable {
    func recognizeText(from imageURL: URL) async throws -> String
}

public enum OCRServiceError: LocalizedError {
    case failedToLoadImage
    case noTextRecognized

    public var errorDescription: String? {
        switch self {
        case .failedToLoadImage:
            return "无法读取所选图片。"
        case .noTextRecognized:
            return "图片中未识别到可用文字。"
        }
    }
}

public final class ReceiptOCRService: ReceiptTextRecognizing, @unchecked Sendable {
    public init() {}

    public func recognizeText(from imageURL: URL) async throws -> String {
        AppLogger.log("ocr.start", "image_url=\(imageURL.path)")
        guard
            let image = NSImage(contentsOf: imageURL),
            let data = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: data),
            let cgImage = bitmap.cgImage
        else {
            AppLogger.log("ocr.error", "failed to load image at \(imageURL.path)")
            throw OCRServiceError.failedToLoadImage
        }

        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let lines = (request.results as? [VNRecognizedTextObservation])?
                    .compactMap { $0.topCandidates(1).first?.string.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty } ?? []
                guard !lines.isEmpty else {
                    AppLogger.log("ocr.empty", "no text recognized from \(imageURL.lastPathComponent)")
                    continuation.resume(throwing: OCRServiceError.noTextRecognized)
                    return
                }
                AppLogger.log("ocr.output", lines.joined(separator: "\n"))
                continuation.resume(returning: lines.joined(separator: "\n"))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["zh-Hans", "en-US"]

            let handler = VNImageRequestHandler(cgImage: cgImage)
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try handler.perform([request])
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
