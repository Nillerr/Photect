# Photect

Easy document detection for SwiftUI

Photect drives an AVFoundation camera session, uses Vision
(`VNDetectDocumentSegmentationRequest`) to find a document's edges in the live feed, and
crops the captured photo to those edges before handing it back.

## Requirements

- Swift tools version 5.9
- iOS 15+

## Installation

Add the package dependency:

```swift
.package(url: "https://github.com/Nillerr/Photect.git", from: "1.0.0")
```

and depend on it from your target:

```swift
.target(
    name: "YourTarget",
    dependencies: ["Photect"]
)
```

## Usage

```swift
import Photect
import SwiftUI

struct ContentView: View {
    @StateObject private var camera = Camera()

    var body: some View {
        ZStack(alignment: .bottom) {
            if camera.error == nil {
                CameraViewFinder(camera: camera)
            }

            Button("Capture") {
                camera.capture()
            }
        }
    }
}
```

`Camera` is an `ObservableObject`:

- `photo: UIImage?` — the last captured photo, cropped to the detected document edges if one
  was found. Set once `capture()` finishes processing.
- `isCapturing: Bool` — `true` from the moment `capture()` is called until the photo finishes
  processing.
- `isInitializing: Bool` — `true` until the first document is detected, or until detection has
  failed 20 times in a row, whichever comes first.
- `error: CameraError?` — set if the camera failed to start, or after 20 consecutive detection
  failures. Photect does not recover from this on its own; observe it and present a fallback in
  place of `CameraViewFinder`, as the example above does.
- `isTorchOn: Bool` — toggles the device torch. No effect in the simulator.

Call `capture()` to take a photo, and `reset()` to clear `photo` and return to the live feed.

## Errors

`CameraError`:

- `noVideoCaptureDevices` — no back camera was found on the device.
- `sessionInputAdditionFailed` — a camera was found but could not be added as a capture
  session input.
- `captureDeviceInitializationFailed(Error)` — creating the `AVCaptureDeviceInput` for the
  camera threw.
- `detectionFailed(Error)` — document detection failed 20 consecutive times; the wrapped
  error is the underlying Vision failure.

## Simulator

The iOS Simulator has no camera. Set `Camera.simulatorImage` (and optionally
`simulatorBoundingBox`) before the view appears to preview the flow with a static image
instead of a live feed; `capture()` then hands back that image directly, uncropped.
