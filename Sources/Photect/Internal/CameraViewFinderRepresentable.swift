import SwiftUI

internal struct CameraViewFinderRepresentable: UIViewRepresentable {
    internal let camera: Camera
    
    func makeUIView(context: Context) -> CLCameraViewFinder {
        let view = CLCameraViewFinder()
        camera.view = view
        
        view.delegate = camera
        view.start()
        
        return view
    }
    
    func updateUIView(_ view: CLCameraViewFinder, context: Context) {
        // Nothing
    }
    
    static func dismantleUIView(_ view: CLCameraViewFinder, coordinator: Void) {
        view.stop()
    }
}
