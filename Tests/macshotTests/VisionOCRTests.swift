import AppKit
import CoreText
import Vision
import Testing
@testable import macshot

/// The macOS 27 CI VM cannot compile Vision's accurate text recognition model
/// (E5RT error), so CI sets MACSHOT_SKIP_ACCURATE_OCR there. The macOS 26 job
/// and a Mac run these tests.
private let accurateOCRAvailable = ProcessInfo.processInfo.environment["MACSHOT_SKIP_ACCURATE_OCR"] == nil

final class VisionOCRTests {
    private nonisolated func line(_ text: String) -> OCRTextObservation {
        OCRTextObservation(text: text, boundingBox: CGRect(x: 0.1, y: 0.2, width: 0.8, height: 0.3))
    }

    private func image(_ text: String) -> CGImage {
        let context = CGContext(data: nil, width: 800, height: 160, bitsPerComponent: 8,
            bytesPerRow: 800 * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 800, height: 160))
        let string = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 38), .foregroundColor: NSColor.black
        ])
        context.textPosition = CGPoint(x: 24, y: 70)
        CTLineDraw(CTLineCreateWithAttributedString(string), context)
        return context.makeImage()!
    }

    // Exercise the full production path from a cold process, including deadlines.
    @Test func testRepeatedRecognitionAndSubstringGeometry() async {
        let image = image("Contact hello@example.com today")
        for attempt in 1...6 {
            let done = TestExpectation(description: "OCR attempt \(attempt)")
            let started = Date()
            VisionOCR.performTextRecognition(cgImage: image) { lines, error in
                #expect(error == nil)
                let text = lines.map(\.text).joined(separator: "\n")
                #expect(text.contains("hello@example.com"), "\(text)")
                if let line = lines.first(where: { $0.text.contains("hello@example.com") }),
                   let range = line.text.range(of: "hello@example.com") {
                    let box = line.boundingBox(for: range)
                    #expect(box != nil)
                    #expect((box?.width ?? 0) > 0)
                    #expect((box?.width ?? 1) < line.boundingBox.width)
                    #expect(CGRect(x: 0, y: 0, width: 1, height: 1).contains(line.boundingBox))
                }
                let elapsed = Date().timeIntervalSince(started)
                #expect(elapsed < 12)
                print("OCR production attempt \(attempt): \(elapsed)s")
                done.fulfill()
            }
            await fulfillment(of: [done], timeout: 12)
        }
    }

    // A fast fallback must not mask the legacy first-succeeds-then-fails bug.
    @Test(.enabled(if: accurateOCRAvailable))
    func testRepeatedRequestsThroughAccurateAPI() async {
        let image = image("Accurate recognition")
        for attempt in 1...6 {
            let done = TestExpectation(description: "primary accurate request \(attempt)")
            _ = VisionOCR.startTextRecognition(cgImage: image, recognitionLevel: .accurate) { result in
                switch result {
                case .failure(let error): Issue.record("Accurate request \(attempt) failed: \(error)")
                case .success(let lines):
                    let text = lines.map(\.text).joined(separator: "\n")
                    #expect(text.contains("Accurate recognition"), "\(text)")
                }
                done.fulfill()
            }
            // This unbounded single-attempt entry point intentionally bypasses
            // recovery. The production deadline is tested independently.
            await fulfillment(of: [done], timeout: 60)
        }
    }

    @Test(.enabled(if: accurateOCRAvailable))
    func testTextRecognitionPreservesCyrillic() async throws {
        let done = TestExpectation(description: "Cyrillic OCR")
        _ = VisionOCR.startTextRecognition(cgImage: image("Привет мир"), recognitionLevel: .accurate) { result in
            switch result {
            case .failure(let error): Issue.record("Cyrillic OCR failed: \(error)")
            case .success(let lines):
                let text = lines.map(\.text).joined(separator: "\n")
                #expect(text.contains("Привет"), "\(text)")
            }
            done.fulfill()
        }
        // Cold accurate model compilation can still take >30s on macOS 27.
        // The production deadline/fallback is exercised separately above.
        await fulfillment(of: [done], timeout: 60)
    }

    @Test func testEmptyAccurateResultRetriesFast() async {
        await assertRetry(for: .success([]))
        await assertRetry(for: .success([line(" \n ")]))
    }

    @Test func testAccurateErrorRetriesFast() async {
        await assertRetry(for: .failure(NSError(domain: "E5RT", code: 13)))
    }

    private func assertRetry(for firstResult: Result<[OCRTextObservation], Error>) async {
        let done = TestExpectation(description: "fast recovery")
        let levels = LockedValue<[VNRequestTextRecognitionLevel]>([])
        OCRRecognitionSession(timeout: 1, startAttempt: { level, callback in
            levels.update { $0.append(level) }
            callback(level == .accurate ? firstResult : .success([self.line("Recovered")]))
            return {}
        }, completion: { observations, error in
            #expect(error == nil)
            #expect(observations.map(\.text) == ["Recovered"])
            #expect(levels.current == [.accurate, .fast])
            done.fulfill()
        }).start()
        await fulfillment(of: [done], timeout: 2)
    }

    @Test func testAccurateSuccessDoesNotRetry() async {
        let done = TestExpectation(description: "accurate success")
        OCRRecognitionSession(timeout: 1, startAttempt: { level, callback in
            #expect(level == .accurate)
            callback(.success([self.line("Recognized")]))
            return {}
        }, completion: { lines, error in
            #expect(error == nil)
            #expect(lines.map(\.text) == ["Recognized"])
            done.fulfill()
        }).start()
        await fulfillment(of: [done], timeout: 2)
    }

    @Test func testTimedOutAttemptIsCancelledAndLateDuplicateResultsAreIgnored() async {
        let done = TestExpectation(description: "fast result delivered once")
        let late = TestExpectation(description: "late primary results delivered")
        let cancelled = TestExpectation(description: "primary cancelled")
        OCRRecognitionSession(timeout: 0.03, startAttempt: { level, callback in
            if level == .accurate {
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.12) {
                    callback(.success([self.line("Obsolete")]))
                    callback(.failure(NSError(domain: "E5RT", code: 13)))
                    late.fulfill()
                }
                return { cancelled.fulfill() }
            }
            callback(.success([self.line("Fast")]))
            callback(.success([self.line("Duplicate")]))
            return {}
        }, completion: { lines, error in
            #expect(error == nil)
            #expect(lines.map(\.text) == ["Fast"])
            done.fulfill()
        }).start()
        await fulfillment(of: [done, cancelled, late], timeout: 2)
        // Drain the serial queue's late callbacks before ending this test.
        let drained = TestExpectation(description: "late callbacks drained")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 1)
    }

    @Test func testBothStalledAttemptsFinishWithTimeout() async {
        let done = TestExpectation(description: "bounded failure")
        let cancelled = TestExpectation(description: "both cancelled")
        cancelled.expectedFulfillmentCount = 2
        let started = Date()
        OCRRecognitionSession(timeout: 0.03, startAttempt: { _, _ in
            return { cancelled.fulfill() }
        }, completion: { lines, error in
            #expect(lines.isEmpty)
            #expect(error is OCRRecognitionSession.Failure)
            #expect(Date().timeIntervalSince(started) < 1)
            done.fulfill()
        }).start()
        await fulfillment(of: [done, cancelled], timeout: 2)
    }

    @Test func testFastEmptyResultDoesNotLoop() async {
        let done = TestExpectation(description: "blank image")
        let attempts = LockedValue(0)
        OCRRecognitionSession(timeout: 1, startAttempt: { _, callback in
            attempts.update { $0 += 1 }
            callback(.success([]))
            return {}
        }, completion: { lines, error in
            #expect(attempts.current == 2)
            #expect(error == nil)
            #expect(lines.isEmpty)
            done.fulfill()
        }).start()
        await fulfillment(of: [done], timeout: 2)
    }

    @Test func testFastFailureIsReportedAfterOneRetry() async {
        let done = TestExpectation(description: "final failure")
        let failure = NSError(domain: "E5RT", code: 13)
        let attempts = LockedValue(0)
        OCRRecognitionSession(timeout: 1, startAttempt: { _, callback in
            attempts.update { $0 += 1 }
            callback(.failure(failure))
            return {}
        }, completion: { lines, error in
            #expect(attempts.current == 2)
            #expect(lines.isEmpty)
            #expect((error as NSError?) == failure)
            done.fulfill()
        }).start()
        await fulfillment(of: [done], timeout: 2)
    }

    @Test func testFastRecognitionWorksAndQRPayloadFallbackRemains() async {
        let done = TestExpectation(description: "fast OCR")
        _ = VisionOCR.startTextRecognition(cgImage: image("Hello World"), recognitionLevel: .fast) { result in
            switch result {
            case .failure(let error): Issue.record("Fast OCR failed: \(error)")
            case .success(let lines): #expect(lines.map(\.text).joined().contains("Hello"))
            }
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 12)
        #expect(OCRScanResult(text: "", qrCodes: [QRCodePayload(value: "https://example.com")]).copyText == "https://example.com")
    }
}
