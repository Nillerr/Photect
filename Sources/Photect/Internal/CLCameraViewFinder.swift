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
    
    func cameraViewFinderDidInitialize()
    func cameraViewFinderDidFail(with error: CameraError)
}

internal class CLCameraViewFinder: UIView, AVCaptureVideoDataOutputSampleBufferDelegate, AVCapturePhotoCaptureDelegate, CLCameraView {
    private lazy var captureSession = AVCaptureSession()
    
    private weak var simulation: UIImageView?
    private var simulationDetectionTimer: Timer?
    private var simulationBoundingBox: CGRect?
    
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
    private var isDetecting: Bool = false
    
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
    
    func capture() {
#if targetEnvironment(simulator)
        if let image = self.simulation?.image {
            self.delegate?.cameraViewFinder(self, didCapturePhoto: image)
        }
#else
        let settings = AVCapturePhotoSettings()
        self.photoOutput.capturePhoto(with: settings, delegate: self)
#endif
    }
    
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error {
            return print("Failed to capture photo", error)
        }
        
        guard let data = photo.fileDataRepresentation() else {
            return print("Could not represent photo as file")
        }
        
        guard let image = CIImage(data: data, options: [.applyOrientationProperty: true]) else {
            return print("Failed to represent captured photo as CIImage")
        }
        
        guard let cropped = ciImage(from: image) else {
            return print("Could not crop image")
        }
        
        guard let cgImage = ciContext.createCGImage(cropped, from: cropped.extent) else {
            return print("Could not convert CIImage to CGImage")
        }
        
        let uiImage = UIImage(cgImage: cgImage)
        delegate?.cameraViewFinder(self, didCapturePhoto: uiImage)
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
        guard checkDetection() else {
            return
        }
        
        guard let frame = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return print("Failed to decode frame from buffer")
        }
        
        let handler = VNImageRequestHandler(cvPixelBuffer: frame, options: [:])
        detectDocument(using: handler)
    }
    
    private func simulateDetection() {
        guard checkDetection() else {
            return
        }
        
        guard let boundingBox = self.simulationBoundingBox else {
            return
        }
        
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
    
    private func checkDetection() -> Bool {
        let now = Date.timeIntervalSinceReferenceDate
        let nextDetectionAt = self.lastDetectionAt + self.detectionRate
        guard nextDetectionAt < now, !isDetecting else {
            return false
        }
        
        self.isDetecting = true
        self.lastDetectionAt = now
        
        return true
    }
    
    private func detectDocument(using handler: VNImageRequestHandler) {
        let request = VNDetectDocumentSegmentationRequest { [weak self] request, error in
            self?.isDetecting = false
            
            if let error {
                return print("An error occured while detecting", error)
            }
            
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
        
        try? handler.perform([request])
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
