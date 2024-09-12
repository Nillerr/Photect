import SwiftUI

internal struct CameraViewFinderRepresentable: UIViewRepresentable {
    internal let camera: Camera
    
    func makeUIView(context: Context) -> CLCameraViewFinder {
        let view = CLCameraViewFinder()
        view.delegate = camera
        view.start()
        
        camera.view = view
        
        return view
    }
    
    func updateUIView(_ view: CLCameraViewFinder, context: Context) {
        // Nothing
    }
    
    static func dismantleUIView(_ view: CLCameraViewFinder, coordinator: Void) {
        view.stop()
    }
}
