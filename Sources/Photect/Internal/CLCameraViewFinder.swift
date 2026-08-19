import UIKit
import Foundation
import AVFoundation
import Vision

internal protocol CLCameraView: AnyObject {
    var isTorchOn: Bool { get set }
    
    func capture()
}

internal protocol CLCameraViewFinderDelegate: AnyObject {
    func imageForSimulatorInCameraViewFinder(_ camera: CLCameraViewFinder) -> UIImage?
    
    func boundingBoxForSimulatorInCameraViewFinder(_ camera: CLCameraViewFinder) -> CGRect?
    
    func cameraViewFinder(_ camera: CLCameraViewFinder, didCapturePhoto photo: UIImage)

    func cameraViewFinder(_ camera: CLCameraViewFinder, didFailToCapturePhoto error: CameraError)

    func cameraViewFinderDidInitialize()
    func cameraViewFinderDidFail(with error: CameraError)
}

/// The state of a capture connection the capture guard depends on. `AVCaptureConnection` conforms
/// to it, and it exists so the guard can be exercised without an `AVCaptureSession`, which the
/// simulator the tests run on cannot provide.
internal protocol CLCaptureConnection {
    var isActive: Bool { get }
    var isEnabled: Bool { get }
}

extension AVCaptureConnection: CLCaptureConnection {}

internal class CLCameraViewFinder: UIView, AVCaptureVideoDataOutputSampleBufferDelegate, AVCapturePhotoCaptureDelegate, CLCameraView {
    private lazy var captureSession = AVCaptureSession()
    
    private weak var simulation: UIImageView?
    private var simulationDetectionTimer: Timer?
    internal var simulationBoundingBox: CGRect?
    
    private lazy var previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
    
    private let detectionLayer = CAShapeLayer()
    
    private var device: AVCaptureDevice?
    private var deviceInput: AVCaptureDeviceInput?
    
    private let videoDataOutput = AVCaptureVideoDataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    
    private let queue = DispatchQueue(label: "CLCameraViewFinder")
    
    // Detection
    private var lastDetectionAt: Double = 0
    private var lastDetection: VNRectangleObservation? = nil
    private var detectionRate: Double = 0.5
    
    private var isFirstDetection: Bool = true
    internal var isDetecting: Bool = false

    /// The `uniqueID` of the capture handed to `AVFoundation` and not yet reported to the
    /// delegate, or nil when no capture is outstanding. Read and written on the main queue only.
    private var inFlightCaptureID: Int64?

    /// Number of consecutive failed detections. Reset by any successful detection.
    internal var consecutiveDetectionFailures: Int = 0

    /// Number of consecutive failed detections tolerated before the delegate is told the camera
    /// has failed. At the current detection rate of one attempt every 0.5s this is about 10s of
    /// uninterrupted failure. Reporting the failure is terminal for the presentation — a consumer
    /// that removes the view finder on error stops the capture session and no later frame can
    /// recover it — so the bound is deliberately past the point where a consumer's own timeout
    /// would have acted.
    internal static let maximumConsecutiveDetectionFailures = 20
    
    weak var delegate: CLCameraViewFinderDelegate? {
        didSet {
#if targetEnvironment(simulator)
            DispatchQueue.main.async { [weak self] in
                self?.simulate()
            }
#endif
        }
    }
    
    private let ciContext = CIContext()
    
    var isTorchOn: Bool = false {
        didSet { updateTorchLevel() }
    }
    
    init() {
        super.init(frame: .zero)
    }
    
    override init(frame: CGRect) {
        super.init(frame: frame)
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }
    
    func construct() {
#if targetEnvironment(simulator)
        let simulation = UIImageView()
        simulation.contentMode = .scaleAspectFill
        simulation.layer.insertSublayer(self.detectionLayer, at: 1)
        
        self.simulation = simulation
        self.addSubview(simulation)
#else
        setCameraInput()
        showCameraFeed()
        setCameraOutput()
        setPhotoOutput()
    
        self.previewLayer.insertSublayer(self.detectionLayer, at: 1)
#endif
    }
    
    private func simulate() {
        self.simulation?.image = self.delegate?.imageForSimulatorInCameraViewFinder(self)
        self.simulationBoundingBox = self.delegate?.boundingBoxForSimulatorInCameraViewFinder(self)
        
        self.startSimulationDetection()
    }
    
    private func startSimulationDetection() {
        self.simulationDetectionTimer?.invalidate()
        self.simulationDetectionTimer = Timer.scheduledTimer(withTimeInterval: detectionRate + 0.05, repeats: true) { [weak self] timer in
            self?.simulateDetection()
        }
    }
    
    private func stopSimulationDetection() {
        self.simulationDetectionTimer?.invalidate()
        self.simulationDetectionTimer = nil
    }
    
    private func updateTorchLevel() {
#if !targetEnvironment(simulator)
        self.queue.async {
            guard self.captureSession.isRunning else { return }
            
            if let device = self.device, device.hasTorch, device.isTorchAvailable {
                do {
                    try device.lockForConfiguration()
                    defer { device.unlockForConfiguration() }
                    
                    if self.isTorchOn {
                        try device.setTorchModeOn(level: AVCaptureDevice.maxAvailableTorchLevel)
                    } else {
                        device.torchMode = .off
                    }
                } catch {
                    print("Failed to change configuration")
                }
            }
        }
#endif
    }
    
    /// How a step of the capture ends, and which side tells the delegate about it.
    internal enum CaptureOutcome {
        /// The capture produced a photo. `withCaptureOutcome` delivers it.
        case captured(UIImage)

        /// The capture could not be started, or started and produced nothing.
        /// `withCaptureOutcome` reports it.
        case failed(CameraError)

        /// The work started a capture that reports its own outcome later, on another thread.
        /// `withCaptureOutcome` must say nothing.
        case handedOff
    }

    /// Runs `work` and tells the delegate how the capture ended, unless `work` handed the capture
    /// on to something that reports it later.
    ///
    /// The invariant is that one `Camera.capture()` produces exactly one delegate notification.
    /// `Camera` sets `isCapturing` when the capture starts and only a notification clears it, so a
    /// path that returns without one leaves the shutter disabled for the lifetime of the screen,
    /// with no photo and no error — the same defect as the detection latch in CPD-33988.
    ///
    /// The choice cannot be skipped, because `work` has to return a `CaptureOutcome` on every path
    /// out of it: a new early return is a compile error until it says what the delegate is told. A
    /// plain `defer` would not do, because on the `handedOff` path the capture outlives this scope
    /// and reporting here would resolve a capture that is still in flight.
    ///
    /// `id` identifies the capture `AVFoundation` is reporting on, and is nil for a capture that
    /// never reached it. Two callbacks can report the same capture — the photo and the backstop —
    /// so the first one to claim the id wins and the other returns without running `work`.
    internal func withCaptureOutcome(resolving id: Int64? = nil, _ work: () -> CaptureOutcome) {
        if let id, !resolveCapture(id: id) {
            return
        }

        switch work() {
        case .captured(let photo):
            self.delegate?.cameraViewFinder(self, didCapturePhoto: photo)
        case .failed(let error):
            self.delegate?.cameraViewFinder(self, didFailToCapturePhoto: error)
        case .handedOff:
            break
        }
    }

    /// Records a capture as outstanding, so that whichever callback reports it first can claim it.
    internal func beginCapture(id: Int64) {
        self.inFlightCaptureID = id
    }

    /// Claims the outstanding capture `id`, and reports whether this call is the one that resolved
    /// it. A second call for the same id returns false: the capture has already been reported and
    /// notifying again would break the one-notification-per-capture invariant.
    internal func resolveCapture(id: Int64) -> Bool {
        guard self.inFlightCaptureID == id else {
            return false
        }

        self.inFlightCaptureID = nil

        return true
    }

    /// Whether `capturePhoto` may be called over this connection.
    ///
    /// `AVCapturePhotoOutput.capturePhoto` raises an Objective-C `NSInvalidArgumentException` when
    /// the output has no active and enabled video connection. Swift cannot catch it, so the
    /// process dies — the connection has to be checked before the call, not defended around it.
    /// The session can stop at any time after the view finder initialized, for reasons no consumer
    /// can see coming: an incoming call, another app taking the camera, a backgrounding.
    internal static func canCapture(over connection: CLCaptureConnection?) -> Bool {
        guard let connection else {
            return false
        }

        return connection.isActive && connection.isEnabled
    }

    func capture() {
        withCaptureOutcome {
#if targetEnvironment(simulator)
            guard let image = self.simulation?.image else {
                print("No simulation image to capture")
                return .failed(.captureFailed(nil))
            }

            return .captured(image)
#else
            guard Self.canCapture(over: self.photoOutput.connection(with: .video)) else {
                print("No active and enabled video connection to capture over")
                return .failed(.captureFailed(nil))
            }

            let settings = AVCapturePhotoSettings()
            self.beginCapture(id: settings.uniqueID)
            self.photoOutput.capturePhoto(with: settings, delegate: self)

            return .handedOff
#endif
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let id = photo.resolvedSettings.uniqueID

        // AVCapturePhotoOutput calls its delegate on a private queue, and the delegate publishes
        // into SwiftUI state, so hop to the main queue first — the same hop detectionDidFail and
        // the initialize notification make. It also serializes this callback against the backstop
        // below, so exactly one of them resolves the capture.
        DispatchQueue.main.async {
            self.withCaptureOutcome(resolving: id) {
                if let error {
                    print("Failed to capture photo", error)
                    return .failed(.captureFailed(error))
                }

                guard let data = photo.fileDataRepresentation() else {
                    print("Could not represent photo as file")
                    return .failed(.captureFailed(nil))
                }

                return self.captureOutcome(forPhotoData: data)
            }
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        captureDidFinish(resolving: resolvedSettings.uniqueID, error: error)
    }

    /// The backstop for a capture that was accepted and then produced no photo, which is what an
    /// interruption mid-capture looks like — an incoming call, another app taking the camera.
    /// AVFoundation does not guarantee `didFinishProcessingPhoto` for an aborted capture, and
    /// without this the capture would be handed off and never reported, leaving `isCapturing` set
    /// for the life of the screen with no photo and no error.
    ///
    /// It reports only if nothing has resolved this capture already, so it cannot notify a second
    /// time on the ordinary path where the photo arrived first.
    internal func captureDidFinish(resolving id: Int64, error: Error?) {
        DispatchQueue.main.async {
            self.withCaptureOutcome(resolving: id) {
                print("Capture finished without delivering a photo", error as Any)
                return .failed(.captureFailed(error))
            }
        }
    }

    /// The part of the capture pipeline that depends only on the photo's file representation.
    /// Separated from `photoOutput(_:didFinishProcessingPhoto:error:)` so it can be exercised
    /// directly: `AVCapturePhoto` has no initializer a test can call.
    internal func captureOutcome(forPhotoData data: Data) -> CaptureOutcome {
        guard let image = CIImage(data: data, options: [.applyOrientationProperty: true]) else {
            print("Failed to represent captured photo as CIImage")
            return .failed(.captureFailed(nil))
        }

        guard let cropped = ciImage(from: image) else {
            print("Could not crop image")
            return .failed(.captureFailed(nil))
        }

        guard let cgImage = ciContext.createCGImage(cropped, from: cropped.extent) else {
            print("Could not convert CIImage to CGImage")
            return .failed(.captureFailed(nil))
        }

        return .captured(UIImage(cgImage: cgImage))
    }

    private func ciImage(from ciImage: CIImage) -> CIImage? {
        guard let observation = lastDetection else {
            return ciImage
        }
        
        let size = ciImage.extent.size
        
        let topLeft = observation.topLeft.scaled(to: size)
        let topRight = observation.topRight.scaled(to: size)
        let bottomLeft = observation.bottomLeft.scaled(to: size)
        let bottomRight = observation.bottomRight.scaled(to: size)
        
        // pass filters to extract/rectify the image
        let croppedImage = ciImage.applyingFilter("CIPerspectiveCorrection", parameters: [
            "inputTopLeft": CIVector(cgPoint: topLeft),
            "inputTopRight": CIVector(cgPoint: topRight),
            "inputBottomLeft": CIVector(cgPoint: bottomLeft),
            "inputBottomRight": CIVector(cgPoint: bottomRight),
        ])
        
        return croppedImage
    }
    
    func start() {
        DispatchQueue.main.async {
            self.construct()

#if targetEnvironment(simulator)
            self.startSimulationDetection()
#else
            self.queue.async {
                guard !self.captureSession.isRunning else { return }
                
                self.videoDataOutput.setSampleBufferDelegate(self, queue: self.queue)
                self.captureSession.startRunning()
                
                self.updateTorchLevel()
            }
#endif
        }
    }
    
    func stop() {
#if targetEnvironment(simulator)
        self.stopSimulationDetection()
#else
        self.queue.async {
            guard self.captureSession.isRunning else { return }
            
            self.videoDataOutput.setSampleBufferDelegate(nil, queue: self.queue)
            self.captureSession.stopRunning()
        }
#endif
    }
    
    private func setCameraInput() {
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .builtInDualCamera, .builtInTrueDepthCamera],
            mediaType: .video,
            position: .back
        )
        
        guard let device = discoverySession.devices.first else {
            self.delegate?.cameraViewFinderDidFail(with: .noVideoCaptureDevices)
            return print("Failed to find camera input device")
        }
        
        self.device = device
        
        do {
            let deviceInput = try AVCaptureDeviceInput(device: device)
            self.deviceInput = deviceInput
            
            if self.captureSession.canAddInput(deviceInput) {
                self.captureSession.addInput(deviceInput)
            } else {
                print("Failed to add device input to session: \(deviceInput)")
                self.delegate?.cameraViewFinderDidFail(with: .sessionInputAdditionFailed)
            }
        } catch {
            print("Failed to create device input for device: \(device)")
            self.delegate?.cameraViewFinderDidFail(with: .captureDeviceInitializationFailed(error))
        }
    }
    
    private func showCameraFeed() {
        self.previewLayer.videoGravity = .resizeAspectFill
        self.layer.addSublayer(self.previewLayer)
        self.previewLayer.frame = self.layer.frame
    }
    
    private func setCameraOutput() {
        self.videoDataOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String : kCVPixelFormatType_32BGRA as NSNumber
        ]
        
        self.videoDataOutput.alwaysDiscardsLateVideoFrames = true
        self.videoDataOutput.setSampleBufferDelegate(self, queue: self.queue)
        if self.captureSession.canAddOutput(self.videoDataOutput) {
            self.captureSession.addOutput(self.videoDataOutput)
        } else {
            return print("Failed to add video output to session: \(self.videoDataOutput)")
        }
        
        if let connection = self.videoDataOutput.connection(with: .video) {
            if connection.isVideoOrientationSupported {
                connection.videoOrientation = .portrait
            }
        }
    }
    
    private func setPhotoOutput() {
        if self.captureSession.canAddOutput(self.photoOutput) {
            self.captureSession.addOutput(self.photoOutput)
        } else {
            print("Failed to add photo output to session: \(self.photoOutput)")
        }
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        
#if targetEnvironment(simulator)
        self.simulation?.frame = self.bounds
#else
        self.previewLayer.frame = self.layer.bounds
#endif
    }
    
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        detectDocument(in: sampleBuffer)
    }
    
    internal func detectDocument(in sampleBuffer: CMSampleBuffer) {
        withDetectionClaim {
            guard let frame = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                print("Failed to decode frame from buffer")
                return .finished
            }
            
            let handler = VNImageRequestHandler(cvPixelBuffer: frame, options: [:])
            self.detectDocument(using: handler)
            
            return .handedOff
        }
    }
    
    internal func simulateDetection() {
        withDetectionClaim {
            guard let boundingBox = self.simulationBoundingBox else {
                return .finished
            }
            
            self.simulateDetection(of: boundingBox)
            
            return .handedOff
        }
    }
    
    private func simulateDetection(of boundingBox: CGRect) {
        DispatchQueue.main.async {
            self.isDetecting = false
            
            if self.isFirstDetection {
                self.delegate?.cameraViewFinderDidInitialize()
                self.isFirstDetection = false
            }
            
            if Int.random(in: 0...5) == 3 {
                self.hideBoundingBox()
            } else {
                let observation = VNRectangleObservation(boundingBox: boundingBox)
                self.drawBoundingBox(for: observation)
            }
        }
    }
    
    /// Which side of a claim is responsible for clearing `isDetecting`.
    internal enum DetectionClaimOutcome {
        /// The work started a detection that owns the claim and clears it when it completes,
        /// possibly on another thread. `withDetectionClaim` must not clear it.
        case handedOff
        
        /// The work is over and started nothing, so `withDetectionClaim` clears the claim before
        /// it returns.
        case finished
    }
    
    /// Claims the detection latch, runs `work`, and clears the claim unless `work` handed it on.
    ///
    /// The invariant is that `isDetecting` is set by exactly one `checkDetection()` and cleared
    /// exactly once afterwards. Leaving it set permanently disables detection: every later frame
    /// returns early at the `!isDetecting` guard, the delegate is never initialized, and nothing
    /// reports an error. Clearing it too early permits overlapping detections, which is what the
    /// latch exists to prevent.
    ///
    /// The choice cannot be skipped, because `work` has to return a `DetectionClaimOutcome` on
    /// every path out of it — a new early return is a compile error until it says which side
    /// clears the claim. A plain `defer` would not do: on the `handedOff` paths the claim outlives
    /// this scope, and clearing it here would release a detection that is still in flight.
    private func withDetectionClaim(_ work: () -> DetectionClaimOutcome) {
        guard checkDetection() else {
            return
        }
        
        if work() == .finished {
            self.isDetecting = false
        }
    }
    
    internal func checkDetection() -> Bool {
        let now = Date.timeIntervalSinceReferenceDate
        let nextDetectionAt = self.lastDetectionAt + self.detectionRate
        guard nextDetectionAt < now, !isDetecting else {
            return false
        }
        
        self.isDetecting = true
        self.lastDetectionAt = now
        
        return true
    }
    
    internal func detectDocument(using handler: VNImageRequestHandler) {
        var didInvokeCompletion = false

        let request = VNDetectDocumentSegmentationRequest { [weak self] request, error in
            didInvokeCompletion = true

            self?.isDetecting = false

            if let error {
                self?.detectionDidFail(with: error)
                return
            }

            self?.detectionDidSucceed()

            DispatchQueue.main.async {
                guard let self else { return }

                if self.isFirstDetection {
                    self.delegate?.cameraViewFinderDidInitialize()
                    self.isFirstDetection = false
                }
                
                let observation = (request.results ?? [])
                    .compactMap { $0 as? VNRectangleObservation }
                    .sorted(by: { a, b in a.confidence < b.confidence })
                    .filter { $0.confidence > 0.9 }
                    .first
                
                if let observation {
                    self.drawBoundingBox(for: observation)
                } else {
                    self.hideBoundingBox()
                }
            }
        }
        
        do {
            try handler.perform([request])
        } catch {
            // Vision does not document whether a failing `perform` runs the request's completion
            // handler before it throws, so compensate only if nothing else did. Left uncompensated
            // the latch would stay set for the lifetime of the view and every later frame would
            // return early at the !isDetecting guard, permanently disabling detection.
            if !didInvokeCompletion {
                self.isDetecting = false
                self.detectionDidFail(with: error)
            }
        }
    }

    /// Clears the consecutive failure count. Called on the Vision completion thread.
    internal func detectionDidSucceed() {
        self.consecutiveDetectionFailures = 0
    }

    /// Records a failed detection attempt. A single failure is transient and recovers on the next
    /// frame, so it is only logged; an uninterrupted run of them is reported to the delegate once,
    /// which clears the initializing state on the consumer side instead of leaving it pending
    /// forever. Called on the Vision completion thread.
    private func detectionDidFail(with error: Error) {
        print("An error occured while detecting", error)

        self.consecutiveDetectionFailures += 1

        guard self.consecutiveDetectionFailures == Self.maximumConsecutiveDetectionFailures else {
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.delegate?.cameraViewFinderDidFail(with: .detectionFailed(error))
        }
    }

    private func drawBoundingBox(for observation: VNRectangleObservation) {
        self.lastDetection = observation
        
        let transform = CGAffineTransform(scaleX: 1, y: -1)
            .translatedBy(x: 0, y: -self.previewLayer.bounds.height)
        
        let scale = CGAffineTransform.identity
            .scaledBy(x: self.previewLayer.bounds.width, y: self.previewLayer.bounds.height)
        
        let bounds = observation.boundingBox
            .applying(scale)
            .applying(transform)
        
        let paddedBounds = bounds.insetBy(dx: -10, dy: -10)
        let path = UIBezierPath(roundedRect: paddedBounds, cornerRadius: 15)
        
        let animation = CABasicAnimation(keyPath: "path")
        animation.fromValue = self.detectionLayer.path
        animation.toValue = path.cgPath
        animation.duration = 0.15
        animation.isRemovedOnCompletion = false
        animation.isAdditive = true
        
        self.detectionLayer.path = path.cgPath
        self.detectionLayer.fillColor = UIColor.green.cgColor
        self.detectionLayer.opacity = 0.3
        
        self.detectionLayer.add(animation, forKey: "animatePath")
    }
    
    private func hideBoundingBox() {
        self.lastDetection = nil
        self.detectionLayer.path = nil
    }
}
