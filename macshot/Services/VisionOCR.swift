@preconcurrency import Vision

struct QRCodePayload: Equatable, Sendable {
    let value: String

    var url: URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }
        return url
    }
}

struct OCRScanResult: Sendable {
    let text: String
    let qrCodes: [QRCodePayload]

    var copyText: String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return text }
        return qrCodes.map(\.value).joined(separator: "\n")
    }
}

enum VisionOCR {

    /// All consumers share the same recovery path, including geometry-based tools.
    nonisolated static func performTextRecognition(
        cgImage: CGImage,
        completionHandler: @escaping ([OCRTextObservation], Error?) -> Void
    ) {
        OCRRecognitionSession(timeout: 10, startAttempt: { level, completion in
            startTextRecognition(cgImage: cgImage, recognitionLevel: level, completion: completion)
        }, completion: completionHandler).start()
    }

    nonisolated static func performTextAndQRCodeRecognition(
        cgImage: CGImage,
        completionHandler: @escaping (OCRScanResult) -> Void
    ) {
        performTextRecognition(cgImage: cgImage) { observations, _ in
            let text = observations.map(\.text).joined(separator: "\n")
            let qrCodes = detectQRCodes(cgImage: cgImage)
            completionHandler(OCRScanResult(text: text, qrCodes: qrCodes))
        }
    }

    /// Starts exactly one attempt. Cancellation is best effort: the session's
    /// deadline does not wait for Vision to acknowledge it or finish compiling.
    nonisolated static func startTextRecognition(
        cgImage: CGImage,
        recognitionLevel: VNRequestTextRecognitionLevel,
        completion: @escaping (Result<[OCRTextObservation], Error>) -> Void
    ) -> () -> Void {
        let task = Task.detached(priority: .userInitiated) {
            do {
                var request = RecognizeTextRequest()
                request.recognitionLevel = recognitionLevel == .accurate ? .accurate : .fast
                request.usesLanguageCorrection = true
                request.automaticallyDetectsLanguage = true
                let observations = try await request.perform(on: cgImage)
                let lines = observations.compactMap { observation -> OCRTextObservation? in
                    guard let candidate = observation.topCandidates(1).first else { return nil }
                    return OCRTextObservation(text: candidate.string,
                        boundingBox: observation.boundingBox.cgRect,
                        substringBounds: { candidate.boundingBox(for: $0)?.boundingBox.cgRect })
                }
                completion(.success(lines))
            } catch {
                completion(.failure(error))
            }
        }
        return { task.cancel() }
    }

    nonisolated static func detectQRCodes(cgImage: CGImage) -> [QRCodePayload] {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr, .microQR]

        do {
            try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
        } catch {
            return []
        }

        var seen = Set<String>()
        return (request.results ?? []).compactMap { observation -> QRCodePayload? in
            guard observation.symbology == .qr || observation.symbology == .microQR,
                  let value = observation.payloadStringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty,
                  seen.insert(value).inserted else {
                return nil
            }
            return QRCodePayload(value: value)
        }
    }

}

/// Normalized bottom-left geometry from either Vision API. Keep substring boxes
/// for PII redaction, which must not lose precision during the API migration.
struct OCRTextObservation: @unchecked Sendable {
    let text: String
    let boundingBox: CGRect
    nonisolated(unsafe) private let substringBounds: (Range<String.Index>) -> CGRect?

    nonisolated init(text: String, boundingBox: CGRect,
                     substringBounds: @escaping (Range<String.Index>) -> CGRect? = { _ in nil }) {
        self.text = text
        self.boundingBox = boundingBox
        self.substringBounds = substringBounds
    }

    nonisolated func boundingBox(for range: Range<String.Index>) -> CGRect? {
        substringBounds(range)
    }
}

/// Serializes deadlines and results so an abandoned attempt can never complete
/// the caller twice or replace the fast retry's result. A task group would wait
/// for an uncooperative Vision task at scope exit, defeating the timeout.
final class OCRRecognitionSession: @unchecked Sendable {
    typealias AttemptCompletion = (Result<[OCRTextObservation], Error>) -> Void
    typealias StartAttempt = (VNRequestTextRecognitionLevel, @escaping AttemptCompletion) -> () -> Void

    enum Failure: LocalizedError {
        case timedOut
        var errorDescription: String? { "Text recognition timed out. Please try again." }
    }

    private let queue = DispatchQueue(label: "com.sw33tlie.macshot.ocr", qos: .userInitiated)
    private let timeout: TimeInterval
    nonisolated(unsafe) private let startAttempt: StartAttempt
    nonisolated(unsafe) private var completion: (([OCRTextObservation], Error?) -> Void)?
    nonisolated(unsafe) private var generation = 0
    nonisolated(unsafe) private var deadline: DispatchSourceTimer?
    nonisolated(unsafe) private var cancelAttempt: (() -> Void)?

    nonisolated init(timeout: TimeInterval, startAttempt: @escaping StartAttempt,
         completion: @escaping ([OCRTextObservation], Error?) -> Void) {
        self.timeout = timeout
        self.startAttempt = startAttempt
        self.completion = completion
    }

    nonisolated func start() {
        queue.async { self.begin(level: .accurate) }
    }

    nonisolated private func begin(level: VNRequestTextRecognitionLevel) {
        generation += 1
        let attempt = generation
        // The deadline owns the session until the attempt settles, even when
        // a broken engine never calls its completion. Worker callbacks are weak.
        let deadline = DispatchSource.makeTimerSource(queue: queue)
        deadline.schedule(deadline: .now() + timeout)
        deadline.setEventHandler {
            self.receive(.failure(Failure.timedOut), attempt: attempt, level: level)
        }
        self.deadline = deadline
        deadline.resume()
        cancelAttempt = startAttempt(level) { [weak self] result in
            guard let self else { return }
            self.queue.async { self.receive(result, attempt: attempt, level: level) }
        }
    }

    nonisolated private func receive(_ result: Result<[OCRTextObservation], Error>,
                         attempt: Int, level: VNRequestTextRecognitionLevel) {
        guard completion != nil, attempt == generation else { return }
        generation += 1 // Discard late results even while the next attempt starts.
        // Release the timer's ownership immediately, including captured pixels.
        deadline?.setEventHandler {}
        deadline?.cancel()
        deadline = nil
        let cancellation = cancelAttempt
        cancelAttempt = nil

        if case .failure(let error) = result, error is Failure { cancellation?() }
        switch result {
        case .success(let observations):
            if level == .accurate,
               !observations.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                begin(level: .fast)
            } else {
                finish(observations, error: nil)
            }
        case .failure(let error):
            if level == .accurate {
                begin(level: .fast)
            } else {
                finish([], error: error)
            }
        }
    }

    nonisolated private func finish(_ observations: [OCRTextObservation], error: Error?) {
        let callback = completion
        completion = nil
        // Consumer work (QR detection, annotation rendering) cannot block deadlines.
        DispatchQueue.global(qos: .userInitiated).async { callback?(observations, error) }
    }
}
