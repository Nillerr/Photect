public enum CameraError: Error {
    case noVideoCaptureDevices
    case sessionInputAdditionFailed
    case captureDeviceInitializationFailed(Error)
    case detectionFailed(Error)

    /// A photo capture could not be started, or was started and did not produce an image. Carries
    /// the underlying `AVFoundation` error where there is one, and nil where the failure is a
    /// precondition the library refused to violate or a step of the pipeline that reported
    /// nothing but a nil result.
    case captureFailed(Error?)
}
