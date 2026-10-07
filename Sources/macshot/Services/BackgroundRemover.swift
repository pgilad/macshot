import CoreImage
import Vision

/// Cuts the main subject out of a capture with Vision, on this Mac.
nonisolated enum BackgroundRemover {

    enum Failure: Error {
        case noSubject
        case renderFailed
    }

    static let failureMessage = "Background removal failed. No clear subject was found."

    /// The subject of `cgImage` on a transparent background. Runs on a
    /// background thread; the Vision objects never leave it.
    @concurrent
    static func removeBackground(from cgImage: CGImage) async throws -> CGImage {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])
        guard let result = request.results?.first else { throw Failure.noSubject }
        let mask = try result.generateScaledMaskForImage(forInstances: result.allInstances, from: handler)

        let original = CIImage(cgImage: cgImage)
        guard let filter = CIFilter(name: "CIBlendWithMask") else { throw Failure.renderFailed }
        filter.setValue(original, forKey: kCIInputImageKey)
        filter.setValue(CIImage(cvPixelBuffer: mask), forKey: kCIInputMaskImageKey)
        filter.setValue(CIImage(color: .clear).cropped(to: original.extent), forKey: kCIInputBackgroundImageKey)
        guard let output = filter.outputImage,
              let cutout = CIContext().createCGImage(output, from: output.extent)
        else { throw Failure.renderFailed }
        return cutout
    }
}
