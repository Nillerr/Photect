import Combine
import UIKit

public class Camera: ObservableObject, CLCameraViewFinderDelegate {
    @Published public var photo: UIImage?
    
    @Published public private(set) var isCapturing: Bool = false
    @Published public private(set) var isInitializing: Bool = true
    
    /// A failure of the view finder itself, and terminal: it is cleared only by a later
    /// initialization. Consumers treat it as "this camera cannot be presented".
    @Published public private(set) var error: CameraError? = nil

    /// A failure of the last capture. Unlike `error` this is recoverable — the view finder is
    /// still live and the next `capture()` may well succeed — so it is cleared when a capture is
    /// started and when one succeeds, and it is deliberately not published into `error`.
    @Published public private(set) var captureError: CameraError? = nil
    
    @Published public var isTorchOn: Bool = false {
        didSet { updateViewTorch() }
    }
    
    internal weak var view: CLCameraView? {
        didSet { updateViewTorch() }
    }
    
    public var simulatorImage: UIImage?
    public var simulatorBoundingBox: CGRect?
    
    public init() {
        // Nothing
    }
    
    private func updateViewTorch() {
        view?.isTorchOn = isTorchOn
    }
    
    public func capture() {
        self.captureError = nil
        self.isCapturing = true

        guard let view = self.view else {
            // The view is weak and the view finder may already have been dismantled. Setting the
            // capturing state with nothing to clear it would disable the shutter permanently.
            print("No camera view to capture with")
            return captureDidFail(with: .captureFailed(nil))
        }

        view.capture()
    }
    
    public func reset() {
        self.photo = nil
    }
    
    func imageForSimulatorInCameraViewFinder(_ camera: CLCameraViewFinder) -> UIImage? {
        return self.simulatorImage
    }
    
    func boundingBoxForSimulatorInCameraViewFinder(_ camera: CLCameraViewFinder) -> CGRect? {
        return self.simulatorBoundingBox
    }
    
    internal func cameraViewFinder(_ camera: CLCameraViewFinder, didCapturePhoto photo: UIImage) {
        self.isCapturing = false
        self.captureError = nil
        self.photo = photo
    }
    
    internal func cameraViewFinder(_ camera: CLCameraViewFinder, didFailToCapturePhoto error: CameraError) {
        print("cameraViewFinderDidFailToCapturePhoto", error)
        captureDidFail(with: error)
    }

    /// Releases the capturing state and publishes the failure as a capture failure. It must not
    /// touch `error`: consumers remove the view finder when `error` is set, and only
    /// `cameraViewFinderDidInitialize()` clears it, so a view finder that is still perfectly
    /// usable would be torn down with no way back.
    private func captureDidFail(with error: CameraError) {
        self.isCapturing = false
        self.captureError = error
    }

    internal func cameraViewFinderDidInitialize() {
        self.isInitializing = false
        self.error = nil
    }
    
    internal func cameraViewFinderDidFail(with error: CameraError) {
        print("cameraViewFinderDidFail", error)
        self.isInitializing = false
        self.error = error
    }
}
