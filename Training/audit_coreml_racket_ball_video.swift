#!/usr/bin/env swift

import AVFoundation
import CoreML
import CoreVideo
import Foundation

private struct Detection {
    let label: String
    let confidence: Double
    let centerX: Double
    let centerY: Double
    let width: Double
    let height: Double
}

private struct FrameAudit {
    let timestamp: Double
    let racket: Detection?
    let ball: Detection?
}

private struct AuditError: Error, CustomStringConvertible {
    let description: String
}

private let cocoClassIndices = [
    "tennis_ball": 32,   // COCO's broader "sports ball" class
    "tennis_racket": 38
]

private let tennisClassIndices = [
    "tennis_ball": 0,
    "tennis_racket": 1
]

private func classIndices(for classCount: Int) throws -> [String: Int] {
    switch classCount {
    case 80:
        return cocoClassIndices
    case 2:
        return tennisClassIndices
    default:
        throw AuditError(description: "unsupported detector class count: \(classCount)")
    }
}

private func detections(
    model: MLModel,
    image: CGImage,
    confidenceThreshold: Double
) throws -> [Detection] {
    let imageConstraint = model.modelDescription.inputDescriptionsByName["image"]?.imageConstraint
    let pixelsWide = imageConstraint?.pixelsWide ?? 416
    let pixelsHigh = imageConstraint?.pixelsHigh ?? 416
    let imageValue = try MLFeatureValue(
        cgImage: image,
        pixelsWide: pixelsWide,
        pixelsHigh: pixelsHigh,
        pixelFormatType: kCVPixelFormatType_32ARGB,
        options: nil
    )
    guard let pixelBuffer = imageValue.imageBufferValue else {
        throw AuditError(description: "could not create model image input")
    }
    let input = try MLDictionaryFeatureProvider(dictionary: [
        "image": MLFeatureValue(pixelBuffer: pixelBuffer),
        "iouThreshold": MLFeatureValue(double: 0.45),
        "confidenceThreshold": MLFeatureValue(double: confidenceThreshold)
    ])
    let output = try model.prediction(from: input)
    guard let confidence = output.featureValue(for: "confidence")?.multiArrayValue,
          let coordinates = output.featureValue(for: "coordinates")?.multiArrayValue,
          coordinates.count % 4 == 0 else {
        throw AuditError(description: "model output contract is not an NMS object detector")
    }

    let coordinateCount = coordinates.count / 4
    guard coordinateCount > 0 else { return [] }
    guard confidence.count % coordinateCount == 0 else {
        throw AuditError(description: "confidence and coordinate output sizes disagree")
    }
    let classCount = confidence.count / coordinateCount
    let indices = try classIndices(for: classCount)
    let count = coordinateCount
    var results: [Detection] = []
    for index in 0..<count {
        for (label, classIndex) in indices {
            let score = confidence[index * classCount + classIndex].doubleValue
            guard score >= confidenceThreshold else { continue }
            results.append(Detection(
                label: label,
                confidence: score,
                centerX: coordinates[index * 4].doubleValue,
                centerY: coordinates[index * 4 + 1].doubleValue,
                width: coordinates[index * 4 + 2].doubleValue,
                height: coordinates[index * 4 + 3].doubleValue
            ))
        }
    }
    return results
}

private func longestRun(_ values: [Bool]) -> Int {
    var longest = 0
    var current = 0
    for value in values {
        current = value ? current + 1 : 0
        longest = max(longest, current)
    }
    return longest
}

private func percentile(_ values: [Double], probability: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let ordered = values.sorted()
    let position = min(1, max(0, probability)) * Double(ordered.count - 1)
    let lower = Int(position.rounded(.down))
    let upper = Int(position.rounded(.up))
    guard lower != upper else { return ordered[lower] }
    let fraction = position - Double(lower)
    return ordered[lower] + (ordered[upper] - ordered[lower]) * fraction
}

private func usage() -> Never {
    fputs("Usage: audit_coreml_racket_ball_video.swift MODEL.mlmodelc VIDEO [SAMPLES_PER_SECOND] [CONFIDENCE]\n", stderr)
    exit(2)
}

guard CommandLine.arguments.count >= 3 else { usage() }
let modelURL = URL(fileURLWithPath: CommandLine.arguments[1])
let videoURL = URL(fileURLWithPath: CommandLine.arguments[2])
let samplesPerSecond = CommandLine.arguments.count > 3
    ? Double(CommandLine.arguments[3]) ?? 10
    : 10
let confidenceThreshold = CommandLine.arguments.count > 4
    ? Double(CommandLine.arguments[4]) ?? 0.10
    : 0.10

do {
    guard samplesPerSecond > 0 else {
        throw AuditError(description: "samples per second must be positive")
    }
    let configuration = MLModelConfiguration()
    configuration.computeUnits = .all
    let model = try MLModel(contentsOf: modelURL, configuration: configuration)
    let asset = AVURLAsset(url: videoURL)
    let duration = try await asset.load(.duration).seconds
    guard duration.isFinite, duration > 0 else {
        throw AuditError(description: "video has no readable duration")
    }
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: 832, height: 832)
    generator.requestedTimeToleranceBefore = CMTime(seconds: 0.02, preferredTimescale: 600)
    generator.requestedTimeToleranceAfter = CMTime(seconds: 0.02, preferredTimescale: 600)

    let sampleCount = max(1, Int((duration * samplesPerSecond).rounded(.down)))
    var frames: [FrameAudit] = []
    for sampleIndex in 0..<sampleCount {
        let seconds = min(duration, Double(sampleIndex) / samplesPerSecond)
        let requested = CMTime(seconds: seconds, preferredTimescale: 600)
        let result = try await generator.image(at: requested)
        let candidates = try detections(
            model: model,
            image: result.image,
            confidenceThreshold: confidenceThreshold
        )
        frames.append(FrameAudit(
            timestamp: result.actualTime.seconds,
            racket: candidates
                .filter { $0.label == "tennis_racket" }
                .max { $0.confidence < $1.confidence },
            ball: candidates
                .filter { $0.label == "tennis_ball" }
                .max { $0.confidence < $1.confidence }
        ))
    }

    let racketVisible = frames.map { $0.racket != nil }
    let ballVisible = frames.map { $0.ball != nil }
    let bothVisible = frames.map { $0.racket != nil && $0.ball != nil }
    let racketConfidences = frames.compactMap { $0.racket?.confidence }
    let ballConfidences = frames.compactMap { $0.ball?.confidence }
    let coverage: [String: Any] = [
        "racketFrameRate": Double(racketVisible.filter { $0 }.count) / Double(frames.count),
        "ballFrameRate": Double(ballVisible.filter { $0 }.count) / Double(frames.count),
        "racketAndBallFrameRate": Double(bothVisible.filter { $0 }.count) / Double(frames.count),
        "longestRacketRunFrames": longestRun(racketVisible),
        "longestBallRunFrames": longestRun(ballVisible),
        "medianRacketConfidence": percentile(racketConfidences, probability: 0.50),
        "medianBallConfidence": percentile(ballConfidences, probability: 0.50)
    ]
    let releaseInterpretation: [String: Any] = [
        "canEstablishObjectAccuracy": false,
        "canEstablishRacketDropAccuracy": false,
        "canEstablishPronationAccuracy": false
    ]
    let output: [String: Any] = [
        "schemaVersion": 1,
        "purpose": "Unlabeled temporal detection-coverage audit; not accuracy or coaching ground truth.",
        "durationSeconds": duration,
        "samplesPerSecond": samplesPerSecond,
        "sampledFrameCount": frames.count,
        "confidenceThreshold": confidenceThreshold,
        "coverage": coverage,
        "releaseInterpretation": releaseInterpretation
    ]
    let encoded = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: encoded, as: UTF8.self))
} catch {
    fputs("video audit failed: \(error)\n", stderr)
    exit(1)
}
