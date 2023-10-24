import Combine
import UIKit

public class Camera: ObservableObject, CLCameraViewFinderDelegate {
    @Published public private(set) var photo: UIImage?
    @Published public private(set) var isCapturing: Bool = false
    @Published public private(set) var isInitializing: Bool = true
    
    @Published public var isTorchOn: Bool = false {
        didSet { updateViewTorch() }
    }
    
    internal weak var view: CLCameraView? {
        didSet { updateViewTorch() }
    }
    
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
    
    internal func cameraViewFinder(_ camera: CLCameraViewFinder, didCapturePhoto photo: UIImage) {
        self.isCapturing = false
        self.photo = photo
    }
    
    internal func cameraViewFinderDidInitialize() {
        self.isInitializing = false
    }
}
