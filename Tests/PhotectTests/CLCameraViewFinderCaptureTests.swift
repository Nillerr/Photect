import AVFoundation
import UIKit
import XCTest
@testable import Photect

private final class CaptureDelegateSpy: CLCameraViewFinderDelegate {
    var photos: [UIImage] = []
    var captureFailures: [CameraError] = []

    func imageForSimulatorInCameraViewFinder(_ camera: CLCameraViewFinder) -> UIImage? {
        return nil
    }

    func boundingBoxForSimulatorInCameraViewFinder(_ camera: CLCameraViewFinder) -> CGRect? {
        return nil
    }

    func cameraViewFinder(_ camera: CLCameraViewFinder, didCapturePhoto photo: UIImage) {
        photos.append(photo)
    }

    func cameraViewFinder(_ camera: CLCameraViewFinder, didFailToCapturePhoto error: CameraError) {
        captureFailures.append(error)
    }

    func cameraViewFinderDidInitialize() {
        // Nothing
    }

    func cameraViewFinderDidFail(with error: CameraError) {
        // Nothing
    }
}

private struct CaptureConnectionStub: CLCaptureConnection {
    var isActive: Bool
    var isEnabled: Bool
}

private final class CameraViewStub: CLCameraView {
    var isTorchOn: Bool = false
    var captureCount = 0

    func capture() {
        captureCount += 1
    }
}

final class CLCameraViewFinderCaptureTests: XCTestCase {
    /// A photo the pipeline can decode, crop and convert.
    private func decodablePhotoData() throws -> Data {
        let size = CGSize(width: 16, height: 16)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }

        return try XCTUnwrap(image.jpegData(compressionQuality: 1))
    }

    private func assertCaptureFailed(_ error: CameraError?, file: StaticString = #filePath, line: UInt = #line) {
        switch error {
        case .captureFailed:
            break
        default:
            XCTFail("Expected CameraError.captureFailed, got \(String(describing: error))", file: file, line: line)
        }
    }

    func testCaptureIsRefusedWithoutAVideoConnection() {
        XCTAssertFalse(CLCameraViewFinder.canCapture(over: nil), "A missing connection is the crashing case")
    }

    func testCaptureIsRefusedOverAnInactiveOrDisabledConnection() {
        XCTAssertFalse(CLCameraViewFinder.canCapture(over: CaptureConnectionStub(isActive: false, isEnabled: true)))
        XCTAssertFalse(CLCameraViewFinder.canCapture(over: CaptureConnectionStub(isActive: true, isEnabled: false)))
        XCTAssertFalse(CLCameraViewFinder.canCapture(over: CaptureConnectionStub(isActive: false, isEnabled: false)))
    }

    func testCaptureIsPermittedOverAnActiveAndEnabledConnection() {
        XCTAssertTrue(CLCameraViewFinder.canCapture(over: CaptureConnectionStub(isActive: true, isEnabled: true)))
    }

#if targetEnvironment(simulator)
    func testCaptureWithoutASimulationImageReportsFailure() {
        let delegate = CaptureDelegateSpy()

        let finder = CLCameraViewFinder()
        finder.delegate = delegate

        finder.capture()

        XCTAssertEqual(delegate.photos.count, 0)
        XCTAssertEqual(delegate.captureFailures.count, 1, "A capture that produces nothing must still be reported")
        assertCaptureFailed(delegate.captureFailures.first)
    }
#endif

    func testUndecodablePhotoDataReportsFailure() {
        let delegate = CaptureDelegateSpy()

        let finder = CLCameraViewFinder()
        finder.delegate = delegate

        finder.withCaptureOutcome {
            finder.captureOutcome(forPhotoData: Data([0x00, 0x01, 0x02, 0x03]))
        }

        XCTAssertEqual(delegate.photos.count, 0)
        XCTAssertEqual(delegate.captureFailures.count, 1, "An undecodable photo must reach the delegate")
        assertCaptureFailed(delegate.captureFailures.first)
    }

    func testDecodablePhotoDataDeliversThePhotoExactlyOnce() throws {
        let delegate = CaptureDelegateSpy()

        let finder = CLCameraViewFinder()
        finder.delegate = delegate

        let data = try decodablePhotoData()

        finder.withCaptureOutcome {
            finder.captureOutcome(forPhotoData: data)
        }

        XCTAssertEqual(delegate.photos.count, 1, "A successful capture is delivered once")
        XCTAssertEqual(delegate.captureFailures.count, 0)
    }

    /// Runs the main queue to the point where the callbacks under test have been delivered.
    private func drainTheMainQueue() {
        let expectation = expectation(description: "main queue drained")
        DispatchQueue.main.async { expectation.fulfill() }
        wait(for: [expectation], timeout: 1)
    }

    func testCaptureThatNeverDeliversAPhotoIsReportedByTheBackstop() {
        let delegate = CaptureDelegateSpy()

        let finder = CLCameraViewFinder()
        finder.delegate = delegate
        finder.beginCapture(id: 7)

        finder.captureDidFinish(resolving: 7, error: nil)
        drainTheMainQueue()

        XCTAssertEqual(delegate.photos.count, 0)
        XCTAssertEqual(delegate.captureFailures.count, 1, "An aborted capture must not be left unreported")
        assertCaptureFailed(delegate.captureFailures.first)
    }

    func testBackstopIsSilentOnceThePhotoHasBeenDelivered() throws {
        let delegate = CaptureDelegateSpy()

        let finder = CLCameraViewFinder()
        finder.delegate = delegate
        finder.beginCapture(id: 7)

        let data = try decodablePhotoData()
        finder.withCaptureOutcome(resolving: 7) {
            finder.captureOutcome(forPhotoData: data)
        }

        finder.captureDidFinish(resolving: 7, error: nil)
        drainTheMainQueue()

        XCTAssertEqual(delegate.photos.count, 1, "The photo is delivered once")
        XCTAssertEqual(delegate.captureFailures.count, 0, "The backstop must not report a resolved capture")
    }

    func testPhotoIsSilentOnceTheBackstopHasReported() throws {
        let delegate = CaptureDelegateSpy()

        let finder = CLCameraViewFinder()
        finder.delegate = delegate
        finder.beginCapture(id: 7)

        finder.captureDidFinish(resolving: 7, error: nil)
        drainTheMainQueue()

        let data = try decodablePhotoData()
        finder.withCaptureOutcome(resolving: 7) {
            finder.captureOutcome(forPhotoData: data)
        }

        XCTAssertEqual(delegate.captureFailures.count, 1)
        XCTAssertEqual(delegate.photos.count, 0, "A capture already reported must not be reported again")
    }

    func testHandedOffCaptureTellsTheDelegateNothing() {
        let delegate = CaptureDelegateSpy()

        let finder = CLCameraViewFinder()
        finder.delegate = delegate

        finder.withCaptureOutcome { .handedOff }

        XCTAssertEqual(delegate.photos.count, 0, "An in-flight capture reports its own outcome later")
        XCTAssertEqual(delegate.captureFailures.count, 0)
    }
}

final class CameraCaptureStateTests: XCTestCase {
    func testCaptureFailureReleasesTheCapturingStateWithoutFailingTheCamera() {
        let camera = Camera()
        let view = CameraViewStub()
        camera.view = view

        let finder = CLCameraViewFinder()

        camera.capture()
        XCTAssertTrue(camera.isCapturing)
        XCTAssertEqual(view.captureCount, 1)

        camera.cameraViewFinder(finder, didFailToCapturePhoto: .captureFailed(nil))

        XCTAssertFalse(camera.isCapturing, "A failed capture must re-enable the shutter")
        XCTAssertNotNil(camera.captureError)
        XCTAssertNil(camera.error, "A capture failure must not tear the view finder down")
        XCTAssertTrue(camera.isInitializing, "A capture failure is not an initialization outcome")
    }

    func testRetryingAfterAFailedCaptureClearsTheCaptureError() {
        let camera = Camera()
        let view = CameraViewStub()
        camera.view = view

        let finder = CLCameraViewFinder()

        camera.capture()
        camera.cameraViewFinder(finder, didFailToCapturePhoto: .captureFailed(nil))
        XCTAssertNotNil(camera.captureError)

        camera.capture()

        XCTAssertNil(camera.captureError, "A retry starts clean")
        XCTAssertTrue(camera.isCapturing)
        XCTAssertEqual(view.captureCount, 2)
    }

    func testSuccessfulCaptureReleasesTheCapturingStateAndDeliversThePhoto() {
        let camera = Camera()
        let view = CameraViewStub()
        camera.view = view

        let finder = CLCameraViewFinder()
        let photo = UIImage()

        camera.capture()
        XCTAssertTrue(camera.isCapturing)

        camera.cameraViewFinder(finder, didCapturePhoto: photo)

        XCTAssertFalse(camera.isCapturing)
        XCTAssertNil(camera.captureError)
        XCTAssertNil(camera.error)
        XCTAssertTrue(camera.photo === photo)
    }

    func testCaptureWithoutAViewReportsFailureInsteadOfLatching() {
        let camera = Camera()

        camera.capture()

        XCTAssertFalse(camera.isCapturing, "A capture with no view has nothing to clear the latch")
        XCTAssertNotNil(camera.captureError)
        XCTAssertNil(camera.error)
    }
}
