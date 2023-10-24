import UIKit
import Foundation
import AVFoundation
import Vision

internal protocol CLCameraView: AnyObject {
    func capture()
}

internal protocol CLCameraViewFinderDelegate: AnyObject {
    func cameraViewFinder(_ camera: CLCameraViewFinder, didCapturePhoto photo: UIImage)
    
    func cameraViewFinderDidInitialize()
}

internal class CLCameraViewFinder: UIView, AVCaptureVideoDataOutputSampleBufferDelegate, AVCapturePhotoCaptureDelegate, CLCameraView {
    private let captureSession = AVCaptureSession()
    
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
    
    weak var delegate: CLCameraViewFinderDelegate?
    
    private let ciContext = CIContext()
    
    init() {
        super.init(frame: .zero)
        construct()
    }
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        construct()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        construct()
    }
    
    func capture() {
        let settings = AVCapturePhotoSettings()
        self.photoOutput.capturePhoto(with: settings, delegate: self)
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
        self.queue.async {
            guard !self.captureSession.isRunning else { return }
            
            self.videoDataOutput.setSampleBufferDelegate(self, queue: self.queue)
            self.captureSession.startRunning()
            
            if let device = self.device {
                do {
                    try device.lockForConfiguration()
                    defer { device.unlockForConfiguration() }
                    
                    try device.setTorchModeOn(level: AVCaptureDevice.maxAvailableTorchLevel)
                } catch {
                    print("Failed to change configuration")
                }
            }
        }
    }
    
    func stop() {
        self.queue.async {
            guard self.captureSession.isRunning else { return }
            
            self.videoDataOutput.setSampleBufferDelegate(nil, queue: self.queue)
            self.captureSession.stopRunning()
        }
    }
    
    private func construct() {
        setCameraInput()
        showCameraFeed()
        setCameraOutput()
        setPhotoOutput()
        
        self.previewLayer.insertSublayer(self.detectionLayer, at: 1)
    }
    
    private func setCameraInput() {
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .builtInDualCamera, .builtInTrueDepthCamera],
            mediaType: .video,
            position: .back
        )
        
        guard let device = discoverySession.devices.first else {
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
            }
        } catch {
            print("Failed to create device input for device: \(device)")
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
        self.previewLayer.frame = self.layer.bounds
    }
    
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = Date.timeIntervalSinceReferenceDate
        let nextDetectionAt = self.lastDetectionAt + self.detectionRate
        guard nextDetectionAt < now, !isDetecting else {
            return
        }
        
        self.isDetecting = true
        self.lastDetectionAt = now
        
        guard let frame = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return print("Failed to decode frame from buffer")
        }
        
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
        
        let handler = VNImageRequestHandler(cvPixelBuffer: frame, options: [:])
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
