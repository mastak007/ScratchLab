// EquipmentDetector.swift
// ScratchLab - ML Equipment Detection
// Uses Vision framework to detect turntables and DJ controllers in camera feed

import Foundation
import Vision
import AVFoundation
import CoreML
import UIKit

// MARK: - Detected Equipment Types
enum EquipmentType: String, CaseIterable {
    case turntable = "Turntable"
    case controller = "DJ Controller"
    case mixer = "Mixer"
    case cdj = "CDJ"
    case unknown = "Unknown"
    
    var icon: String {
        switch self {
        case .turntable: return "🎛️"
        case .controller: return "🎚️"
        case .mixer: return "🔊"
        case .cdj: return "💿"
        case .unknown: return "❓"
        }
    }
    
    var description: String {
        switch self {
        case .turntable: return "Vinyl turntable detected"
        case .controller: return "DJ controller detected"
        case .mixer: return "DJ mixer detected"
        case .cdj: return "CDJ/Media player detected"
        case .unknown: return "Point camera at your equipment"
        }
    }
}

// MARK: - Detection Result
struct EquipmentDetectionResult {
    let equipmentType: EquipmentType
    let confidence: Float
    let boundingBox: CGRect
    let timestamp: Date
    
    var isHighConfidence: Bool {
        return confidence >= 0.7
    }
}

// MARK: - Equipment Detector
class EquipmentDetector: NSObject, ObservableObject {
    // Published state
    @Published var isDetecting: Bool = false
    @Published var lastDetection: EquipmentDetectionResult?
    @Published var detectedEquipment: [EquipmentDetectionResult] = []
    @Published var isEquipmentFramed: Bool = false
    
    // Vision components
    private var visionModel: VNCoreMLModel?
    private var detectionRequest: VNCoreMLRequest?
    
    // Object tracking
    private var objectTracker: VNSequenceRequestHandler?
    private var trackingRequest: VNTrackObjectRequest?
    private var lastObservation: VNDetectedObjectObservation?
    
    // Configuration
    private let minimumConfidence: Float = 0.5
    private let detectionInterval: TimeInterval = 0.5 // Process every 0.5 seconds
    private var lastDetectionTime: Date = .distantPast
    
    // Callbacks
    var onEquipmentDetected: ((EquipmentDetectionResult) -> Void)?
    var onEquipmentLost: (() -> Void)?
    
    override init() {
        super.init()
        setupVisionModel()
    }
    
    // MARK: - Setup
    
    private func setupVisionModel() {
        // In production, load a trained CoreML model for DJ equipment
        // For now, we'll use object detection heuristics
        
        // Try to load custom model if available
        if let modelURL = Bundle.main.url(forResource: "DJEquipmentDetector", withExtension: "mlmodelc") {
            do {
                let mlModel = try MLModel(contentsOf: modelURL)
                visionModel = try VNCoreMLModel(for: mlModel)
                setupDetectionRequest()
            } catch {
                print("Failed to load ML model: \(error)")
                // Fall back to generic object detection
                setupGenericDetection()
            }
        } else {
            // Use generic object detection as fallback
            setupGenericDetection()
        }
        
        objectTracker = VNSequenceRequestHandler()
    }
    
    private func setupDetectionRequest() {
        guard let model = visionModel else { return }
        
        detectionRequest = VNCoreMLRequest(model: model) { [weak self] request, error in
            self?.processDetectionResults(request.results)
        }
        
        detectionRequest?.imageCropAndScaleOption = .scaleFill
    }
    
    private func setupGenericDetection() {
        // Use rectangle detection as a fallback for equipment detection
        // DJ equipment typically has rectangular shapes (platters, faders, buttons)
    }
    
    // MARK: - Detection
    
    func startDetecting() {
        isDetecting = true
    }
    
    func stopDetecting() {
        isDetecting = false
        lastObservation = nil
    }
    
    func processFrame(_ pixelBuffer: CVPixelBuffer) {
        guard isDetecting else { return }
        
        // Rate limit detection
        let now = Date()
        guard now.timeIntervalSince(lastDetectionTime) >= detectionInterval else { return }
        lastDetectionTime = now
        
        // If we have a tracking observation, update tracking
        if let observation = lastObservation {
            updateTracking(pixelBuffer, observation: observation)
        }
        
        // Run detection
        runDetection(on: pixelBuffer)
    }
    
    private func runDetection(on pixelBuffer: CVPixelBuffer) {
        // If we have a trained model, use it
        if let request = detectionRequest {
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
            try? handler.perform([request])
        } else {
            // Use heuristic detection
            runHeuristicDetection(on: pixelBuffer)
        }
    }
    
    private func runHeuristicDetection(on pixelBuffer: CVPixelBuffer) {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        
        // Detect rectangles (common in DJ equipment)
        let rectangleRequest = VNDetectRectanglesRequest { [weak self] request, error in
            self?.processRectangleResults(request.results as? [VNRectangleObservation])
        }
        
        rectangleRequest.minimumAspectRatio = 0.3
        rectangleRequest.maximumAspectRatio = 3.0
        rectangleRequest.minimumSize = 0.1
        rectangleRequest.minimumConfidence = 0.5
        
        // Detect circles (turntable platters)
        let circleRequest = VNDetectContoursRequest { [weak self] request, error in
            self?.processContourResults(request.results as? [VNContoursObservation])
        }
        
        try? handler.perform([rectangleRequest])
    }
    
    private func processDetectionResults(_ results: [Any]?) {
        guard let observations = results as? [VNRecognizedObjectObservation] else { return }
        
        var newDetections: [EquipmentDetectionResult] = []
        
        for observation in observations {
            guard let topLabel = observation.labels.first,
                  observation.confidence >= minimumConfidence else { continue }
            
            let equipmentType = mapLabelToEquipment(topLabel.identifier)
            
            let result = EquipmentDetectionResult(
                equipmentType: equipmentType,
                confidence: observation.confidence,
                boundingBox: observation.boundingBox,
                timestamp: Date()
            )
            
            newDetections.append(result)
            
            // Start tracking high-confidence detections
            if result.isHighConfidence {
                lastObservation = observation
            }
        }
        
        DispatchQueue.main.async { [weak self] in
            self?.detectedEquipment = newDetections
            self?.lastDetection = newDetections.first
            self?.isEquipmentFramed = !newDetections.isEmpty
            
            if let detection = newDetections.first {
                self?.onEquipmentDetected?(detection)
            } else if self?.lastDetection != nil {
                self?.onEquipmentLost?()
            }
        }
    }
    
    private func processRectangleResults(_ observations: [VNRectangleObservation]?) {
        guard let rectangles = observations, !rectangles.isEmpty else {
            DispatchQueue.main.async { [weak self] in
                self?.isEquipmentFramed = false
            }
            return
        }
        
        // Analyze rectangles to identify equipment
        // Large horizontal rectangles = likely controller or mixer
        // Square-ish shapes = likely turntable
        
        var bestMatch: (EquipmentType, Float, CGRect)? = nil
        
        for rect in rectangles {
            let aspectRatio = rect.boundingBox.width / rect.boundingBox.height
            let size = rect.boundingBox.width * rect.boundingBox.height
            
            var equipmentType: EquipmentType = .unknown
            var confidence: Float = rect.confidence
            
            // Heuristics for equipment type
            if size > 0.2 { // Large object
                if aspectRatio > 1.5 && aspectRatio < 4.0 {
                    // Wide rectangle - likely controller or mixer
                    equipmentType = .controller
                    confidence *= 0.8
                } else if aspectRatio > 0.8 && aspectRatio < 1.2 {
                    // Square-ish - could be turntable
                    equipmentType = .turntable
                    confidence *= 0.7
                }
            }
            
            if equipmentType != .unknown {
                if bestMatch == nil || confidence > bestMatch!.1 {
                    bestMatch = (equipmentType, confidence, rect.boundingBox)
                }
            }
        }
        
        if let match = bestMatch {
            let result = EquipmentDetectionResult(
                equipmentType: match.0,
                confidence: match.1,
                boundingBox: match.2,
                timestamp: Date()
            )
            
            DispatchQueue.main.async { [weak self] in
                self?.lastDetection = result
                self?.isEquipmentFramed = true
                self?.onEquipmentDetected?(result)
            }
        }
    }
    
    private func processContourResults(_ observations: [VNContoursObservation]?) {
        // Look for circular contours (turntable platters)
        // This is a simplified implementation
    }
    
    private func updateTracking(_ pixelBuffer: CVPixelBuffer, observation: VNDetectedObjectObservation) {
        let trackRequest = VNTrackObjectRequest(detectedObjectObservation: observation) { [weak self] request, error in
            guard let results = request.results as? [VNDetectedObjectObservation],
                  let updated = results.first else {
                self?.lastObservation = nil
                return
            }
            
            if updated.confidence > 0.3 {
                self?.lastObservation = updated
                
                DispatchQueue.main.async {
                    // Update bounding box for UI overlay
                    if var detection = self?.lastDetection {
                        self?.lastDetection = EquipmentDetectionResult(
                            equipmentType: detection.equipmentType,
                            confidence: updated.confidence,
                            boundingBox: updated.boundingBox,
                            timestamp: Date()
                        )
                    }
                }
            } else {
                self?.lastObservation = nil
            }
        }
        
        trackRequest.trackingLevel = .fast
        
        try? objectTracker?.perform([trackRequest], on: pixelBuffer)
    }
    
    private func mapLabelToEquipment(_ label: String) -> EquipmentType {
        let lowercased = label.lowercased()
        
        if lowercased.contains("turntable") || lowercased.contains("vinyl") || lowercased.contains("technics") {
            return .turntable
        } else if lowercased.contains("controller") || lowercased.contains("ddj") || lowercased.contains("traktor") {
            return .controller
        } else if lowercased.contains("mixer") || lowercased.contains("djm") {
            return .mixer
        } else if lowercased.contains("cdj") || lowercased.contains("xdj") {
            return .cdj
        }
        
        return .unknown
    }
    
    // MARK: - Manual Equipment Selection
    
    func setManualEquipment(_ type: EquipmentType) {
        let result = EquipmentDetectionResult(
            equipmentType: type,
            confidence: 1.0,
            boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8),
            timestamp: Date()
        )
        
        DispatchQueue.main.async { [weak self] in
            self?.lastDetection = result
            self?.isEquipmentFramed = true
        }
    }
}

// MARK: - Equipment Detection Overlay View
import SwiftUI

struct EquipmentDetectionOverlay: View {
    @ObservedObject var detector: EquipmentDetector
    let frameSize: CGSize
    
    var body: some View {
        ZStack {
            // Bounding box overlay
            if let detection = detector.lastDetection, detector.isEquipmentFramed {
                let rect = convertBoundingBox(detection.boundingBox)
                
                // Equipment frame
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        detection.isHighConfidence ? Color(hex: "4CAF50") : Color(hex: "FF9800"),
                        lineWidth: 3
                    )
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                
                // Corner brackets
                CornerBrackets(rect: rect, color: detection.isHighConfidence ? Color(hex: "4CAF50") : Color(hex: "FF9800"))
                
                // Label
                VStack(spacing: 4) {
                    HStack(spacing: 6) {
                        Text(detection.equipmentType.icon)
                            .font(.title3)
                        
                        Text(detection.equipmentType.rawValue)
                            .font(.custom("Futura-Bold", size: 14))
                            .foregroundColor(.white)
                    }
                    
                    Text("\(Int(detection.confidence * 100))% confidence")
                        .font(.custom("Futura-Medium", size: 10))
                        .foregroundColor(.white.opacity(0.7))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.7))
                .cornerRadius(8)
                .position(x: rect.midX, y: rect.maxY + 30)
            }
            
            // Scanning indicator when no equipment detected
            if !detector.isEquipmentFramed && detector.isDetecting {
                VStack(spacing: 16) {
                    // Scanning animation
                    ZStack {
                        Circle()
                            .stroke(Color.white.opacity(0.2), lineWidth: 2)
                            .frame(width: 100, height: 100)
                        
                        Circle()
                            .trim(from: 0, to: 0.3)
                            .stroke(Color(hex: "FFD700"), lineWidth: 3)
                            .frame(width: 100, height: 100)
                            .rotationEffect(.degrees(Double(Date().timeIntervalSince1970 * 100).truncatingRemainder(dividingBy: 360)))
                            .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: Date())
                    }
                    
                    Text("Scanning for equipment...")
                        .font(.custom("Futura-Medium", size: 14))
                        .foregroundColor(.white)
                    
                    Text("Point camera at your turntable or controller")
                        .font(.custom("Futura-Medium", size: 12))
                        .foregroundColor(.white.opacity(0.6))
                }
                .padding(24)
                .background(Color.black.opacity(0.6))
                .cornerRadius(16)
            }
        }
    }
    
    private func convertBoundingBox(_ box: CGRect) -> CGRect {
        // Vision coordinates are normalized (0-1) with origin at bottom-left
        // Convert to view coordinates with origin at top-left
        let x = box.minX * frameSize.width
        let y = (1 - box.maxY) * frameSize.height
        let width = box.width * frameSize.width
        let height = box.height * frameSize.height
        
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

// MARK: - Corner Brackets
struct CornerBrackets: View {
    let rect: CGRect
    let color: Color
    let bracketLength: CGFloat = 20
    let bracketWidth: CGFloat = 3
    
    var body: some View {
        ZStack {
            // Top-left
            Path { path in
                path.move(to: CGPoint(x: rect.minX, y: rect.minY + bracketLength))
                path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.minX + bracketLength, y: rect.minY))
            }
            .stroke(color, lineWidth: bracketWidth)
            
            // Top-right
            Path { path in
                path.move(to: CGPoint(x: rect.maxX - bracketLength, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + bracketLength))
            }
            .stroke(color, lineWidth: bracketWidth)
            
            // Bottom-left
            Path { path in
                path.move(to: CGPoint(x: rect.minX, y: rect.maxY - bracketLength))
                path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
                path.addLine(to: CGPoint(x: rect.minX + bracketLength, y: rect.maxY))
            }
            .stroke(color, lineWidth: bracketWidth)
            
            // Bottom-right
            Path { path in
                path.move(to: CGPoint(x: rect.maxX - bracketLength, y: rect.maxY))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - bracketLength))
            }
            .stroke(color, lineWidth: bracketWidth)
        }
    }
}

// MARK: - Equipment Selection Sheet
struct EquipmentSelectionSheet: View {
    @ObservedObject var detector: EquipmentDetector
    @Binding var isPresented: Bool
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color(hex: "0D0D0D").ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: 16) {
                        Text("What equipment are you using?")
                            .font(.custom("Futura-Medium", size: 14))
                            .foregroundColor(.white.opacity(0.6))
                            .padding(.top, 20)
                        
                        ForEach(EquipmentType.allCases.filter { $0 != .unknown }, id: \.self) { equipment in
                            Button(action: {
                                detector.setManualEquipment(equipment)
                                isPresented = false
                            }) {
                                HStack(spacing: 16) {
                                    Text(equipment.icon)
                                        .font(.system(size: 32))
                                    
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(equipment.rawValue)
                                            .font(.custom("Futura-Bold", size: 16))
                                            .foregroundColor(.white)
                                        
                                        Text(equipmentDescription(equipment))
                                            .font(.custom("Futura-Medium", size: 12))
                                            .foregroundColor(.white.opacity(0.6))
                                    }
                                    
                                    Spacer()
                                    
                                    if detector.lastDetection?.equipmentType == equipment {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundColor(Color(hex: "4CAF50"))
                                    }
                                }
                                .padding(16)
                                .background(Color.white.opacity(0.05))
                                .cornerRadius(12)
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                }
            }
            .navigationTitle("Select Equipment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { isPresented = false }
                        .foregroundColor(Color(hex: "FFD700"))
                }
            }
        }
    }
    
    private func equipmentDescription(_ type: EquipmentType) -> String {
        switch type {
        case .turntable: return "Technics, Reloop, Pioneer PLX, etc."
        case .controller: return "DDJ, S4, Mixtrack, etc."
        case .mixer: return "DJM, Rane, etc."
        case .cdj: return "CDJ, XDJ, SC6000, etc."
        case .unknown: return ""
        }
    }
}
