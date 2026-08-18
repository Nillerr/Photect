import Vision
import UIKit
import XCTest
@testable import Photect

private final class CameraViewFinderDelegateSpy: CLCameraViewFinderDelegate {
    var initializeCount = 0
    var failures: [CameraError] = []

    var onFailure: ((CameraError) -> Void)?

    func imageForSimulatorInCameraViewFinder(_ camera: CLCameraViewFinder) -> UIImage? {
        return nil
    }

    func boundingBoxForSimulatorInCameraViewFinder(_ camera: CLCameraViewFinder) -> CGRect? {
        return nil
    }

    func cameraViewFinder(_ camera: CLCameraViewFinder, didCapturePhoto photo: UIImage) {
        // Nothing
    }

    func cameraViewFinderDidInitialize() {
        initializeCount += 1
    }

    func cameraViewFinderDidFail(with error: CameraError) {
        failures.append(error)
        onFailure?(error)
    }
}

final class CLCameraViewFinderDetectionTests: XCTestCase {
    /// A request handler over data that is not a decodable image, so `perform` fails.
    private func throwingHandler() -> VNImageRequestHandler {
        return VNImageRequestHandler(data: Data([0x00, 0x01, 0x02, 0x03]), options: [:])
    }

    /// Documents the Vision behaviour the recovery has to tolerate: `perform` both invokes the
    /// request's completion handler with the error and throws, so the failure is observed twice
    /// and must only be counted once.
    func testThrowingPerformAlsoInvokesTheCompletionHandler() {
        var completionCount = 0

        let request = VNDetectDocumentSegmentationRequest { _, error in
            completionCount += 1
            XCTAssertNotNil(error)
        }

        XCTAssertThrowsError(try throwingHandler().perform([request]))
        XCTAssertEqual(completionCount, 1)
    }

    func testThrowingPerformReleasesTheDetectionLatch() {
        let finder = CLCameraViewFinder()

        XCTAssertTrue(finder.checkDetection())
        XCTAssertTrue(finder.isDetecting)

        finder.detectDocument(using: throwingHandler())

        XCTAssertFalse(finder.isDetecting, "A throw from perform must not leave the latch set")
        XCTAssertEqual(finder.consecutiveDetectionFailures, 1)
    }

    func testSingleFailureDoesNotReachTheDelegate() {
        let delegate = CameraViewFinderDelegateSpy()

        let finder = CLCameraViewFinder()
        finder.delegate = delegate

        finder.detectDocument(using: throwingHandler())

        let expectation = expectation(description: "main queue drained")
        DispatchQueue.main.async { expectation.fulfill() }
        wait(for: [expectation], timeout: 1)

        XCTAssertEqual(delegate.failures.count, 0)
        XCTAssertEqual(delegate.initializeCount, 0)
    }

    func testContinuousFailureReportsToTheDelegateOnce() {
        let delegate = CameraViewFinderDelegateSpy()

        let expectation = expectation(description: "cameraViewFinderDidFail")
        delegate.onFailure = { _ in expectation.fulfill() }

        let finder = CLCameraViewFinder()
        finder.delegate = delegate

        for _ in 0..<(CLCameraViewFinder.maximumConsecutiveDetectionFailures + 2) {
            finder.detectDocument(using: throwingHandler())
        }

        wait(for: [expectation], timeout: 1)

        XCTAssertEqual(delegate.failures.count, 1, "The delegate is told once per run of failures")

        switch delegate.failures.first {
        case .detectionFailed:
            break
        default:
            XCTFail("Expected CameraError.detectionFailed, got \(String(describing: delegate.failures.first))")
        }
    }

    func testSuccessResetsTheFailureCounter() {
        let delegate = CameraViewFinderDelegateSpy()

        let finder = CLCameraViewFinder()
        finder.delegate = delegate

        let justUnderTheBound = CLCameraViewFinder.maximumConsecutiveDetectionFailures - 1

        for _ in 0..<justUnderTheBound {
            finder.detectDocument(using: throwingHandler())
        }

        XCTAssertEqual(finder.consecutiveDetectionFailures, justUnderTheBound)

        finder.detectionDidSucceed()

        XCTAssertEqual(finder.consecutiveDetectionFailures, 0)

        for _ in 0..<justUnderTheBound {
            finder.detectDocument(using: throwingHandler())
        }

        let expectation = expectation(description: "main queue drained")
        DispatchQueue.main.async { expectation.fulfill() }
        wait(for: [expectation], timeout: 1)

        XCTAssertEqual(delegate.failures.count, 0, "Flaky frames must not accumulate across a success")
    }
}
