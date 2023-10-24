import SwiftUI

public struct CameraViewFinder: View {
    public let camera: Camera
    
    @State private var isMounted: Bool = true
    
    public init(camera: Camera) {
        self.camera = camera
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            if isMounted {
                CameraViewFinderRepresentable(camera: camera)
            }
        }
        .onAppear {
            isMounted = true
        }
        .onDisappear {
            isMounted = false
        }
    }
}
