import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Vision

public struct ProcessedScreenshot: Sendable {
    public let imageData: Data
    public let thumbnailData: Data
    public let ocrText: String
    public let ocrStatus: ScreenshotOCRStatus
}

public enum ScreenshotImageError: Error, LocalizedError {
    case invalidImage
    case inputTooLarge
    case tooManyPixels
    case outputTooLarge

    public var errorDescription: String? {
        switch self {
        case .invalidImage: "The image could not be read."
        case .inputTooLarge: "The image exceeds the 25 MB import limit."
        case .tooManyPixels: "The image exceeds the 16 megapixel import limit."
        case .outputTooLarge: "The image could not be compressed to the storage limit."
        }
    }
}

public enum ScreenshotImageProcessor {
    private static let inputLimit = 25_000_000
    private static let pixelLimit = 16_000_000
    private static let imageLimit = 10_000_000
    private static let thumbnailLimit = 128_000

    public static func process(_ input: Data) throws -> ProcessedScreenshot {
        guard !input.isEmpty else { throw ScreenshotImageError.invalidImage }
        guard input.count <= inputLimit else { throw ScreenshotImageError.inputTooLarge }
        guard let source = CGImageSourceCreateWithData(input as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { throw ScreenshotImageError.invalidImage }
        guard width <= pixelLimit / height else { throw ScreenshotImageError.tooManyPixels }

        let maxDimension = min(4096, max(width, height))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceShouldCache: false
        ]
        guard let oriented = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let flattened = flatten(oriented) else { throw ScreenshotImageError.invalidImage }
        let imageData = try boundedJPEG(flattened, limit: imageLimit)
        let thumbnail = try boundedJPEG(flattened, limit: thumbnailLimit, initialMaxDimension: 384)
        let text: String
        let status: ScreenshotOCRStatus
        do {
            text = try recognizeText(in: imageData)
            status = .succeeded
        } catch {
            text = ""
            status = .failed
        }
        return ProcessedScreenshot(imageData: imageData, thumbnailData: thumbnail,
                                   ocrText: text, ocrStatus: status)
    }

    public static func recognizeText(in normalizedJPEG: Data) throws -> String {
        guard let source = CGImageSourceCreateWithData(normalizedJPEG as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ScreenshotImageError.invalidImage
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }

    private static func flatten(_ image: CGImage) -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: image.width, height: image.height,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    private static func boundedJPEG(_ image: CGImage, limit: Int, initialMaxDimension: Int? = nil) throws -> Data {
        var current = image
        if let maxDimension = initialMaxDimension, max(current.width, current.height) > maxDimension {
            guard let resized = resize(current, maxDimension: maxDimension) else { throw ScreenshotImageError.invalidImage }
            current = resized
        }
        for _ in 0..<8 {
            for quality in [0.82, 0.65, 0.45, 0.25] {
                let output = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
                    throw ScreenshotImageError.invalidImage
                }
                CGImageDestinationAddImage(destination, current, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
                guard CGImageDestinationFinalize(destination) else { throw ScreenshotImageError.invalidImage }
                if output.length <= limit { return output as Data }
            }
            guard let smaller = resize(current, maxDimension: max(1, Int(Double(max(current.width, current.height)) * 0.75))) else {
                throw ScreenshotImageError.invalidImage
            }
            current = smaller
        }
        throw ScreenshotImageError.outputTooLarge
    }

    private static func resize(_ image: CGImage, maxDimension: Int) -> CGImage? {
        let scale = min(1, Double(maxDimension) / Double(max(image.width, image.height)))
        let width = max(1, Int(Double(image.width) * scale))
        let height = max(1, Int(Double(image.height) * scale))
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
