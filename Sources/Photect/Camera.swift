import Combine
import UIKit

public class Camera: ObservableObject, CLCameraViewFinderDelegate {
    @Published public var photo: UIImage?
    
    @Published public private(set) var isCapturing: Bool = false
    @Published public private(set) var isInitializing: Bool = true
    
    @Published public private(set) var error: CameraError? = nil
    
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
        self.isCapturing = true
        self.view?.capture()
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
        self.photo = photo
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
