public enum CameraError: Error {
    case noVideoCaptureDevices
    case sessionInputAdditionFailed
    case captureDeviceInitializationFailed(Error)
}
