#!/usr/bin/env swift

import CoreML
import CoreVideo
import Foundation

private struct GroundTruthBox: Decodable {
    let label: String
    let xmin: Double
    let xmax: Double
    let ymin: Double
    let ymax: Double
}

private struct DatasetRecord: Decodable {
    let imageID: String
    let localImage: String
    let boxes: [GroundTruthBox]
}

private struct Detection {
    let label: String
    let confidence: Double
    let xmin: Double
    let xmax: Double
    let ymin: Double
    let ymax: Double
}

private struct ClassMetrics {
    var truePositive = 0
    var falsePositive = 0
    var falseNegative = 0
    var matchedIoUs: [Double] = []

    var precision: Double {
        let denominator = truePositive + falsePositive
        return denominator == 0 ? 0 : Double(truePositive) / Double(denominator)
    }

    var recall: Double {
        let denominator = truePositive + falseNegative
        return denominator == 0 ? 0 : Double(truePositive) / Double(denominator)
    }
}

private struct EvaluationError: Error, CustomStringConvertible {
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
        throw EvaluationError(description: "unsupported detector class count: \(classCount)")
    }
}

private func iou(_ detection: Detection, _ truth: GroundTruthBox) -> Double {
    let intersectionWidth = max(0, min(detection.xmax, truth.xmax) - max(detection.xmin, truth.xmin))
    let intersectionHeight = max(0, min(detection.ymax, truth.ymax) - max(detection.ymin, truth.ymin))
    let intersection = intersectionWidth * intersectionHeight
    let detectionArea = max(0, detection.xmax - detection.xmin) * max(0, detection.ymax - detection.ymin)
    let truthArea = max(0, truth.xmax - truth.xmin) * max(0, truth.ymax - truth.ymin)
    let union = detectionArea + truthArea - intersection
    return union > 0 ? intersection / union : 0
}

private func records(at path: URL) throws -> [DatasetRecord] {
    let text = try String(contentsOf: path, encoding: .utf8)
    let decoder = JSONDecoder()
    return try text.split(separator: "\n").map { line in
        try decoder.decode(DatasetRecord.self, from: Data(line.utf8))
    }
}

private func detections(
    model: MLModel,
    imageURL: URL,
    confidenceThreshold: Double,
    iouThreshold: Double
) throws -> [Detection] {
    let imageConstraint = model.modelDescription.inputDescriptionsByName["image"]?.imageConstraint
    let pixelsWide = imageConstraint?.pixelsWide ?? 416
    let pixelsHigh = imageConstraint?.pixelsHigh ?? 416
    let image = try MLFeatureValue(
        imageAt: imageURL,
        pixelsWide: pixelsWide,
        pixelsHigh: pixelsHigh,
        pixelFormatType: kCVPixelFormatType_32ARGB,
        options: nil
    )
    guard let pixelBuffer = image.imageBufferValue else {
        throw EvaluationError(description: "could not decode \(imageURL.lastPathComponent)")
    }
    let input = try MLDictionaryFeatureProvider(dictionary: [
        "image": MLFeatureValue(pixelBuffer: pixelBuffer),
        "iouThreshold": MLFeatureValue(double: iouThreshold),
        "confidenceThreshold": MLFeatureValue(double: confidenceThreshold)
    ])
    let output = try model.prediction(from: input)
    guard let confidence = output.featureValue(for: "confidence")?.multiArrayValue,
          let coordinates = output.featureValue(for: "coordinates")?.multiArrayValue,
          coordinates.count % 4 == 0 else {
        throw EvaluationError(description: "model output contract is not an NMS object detector")
    }
    let coordinateCount = coordinates.count / 4
    guard coordinateCount > 0 else { return [] }
    guard confidence.count % coordinateCount == 0 else {
        throw EvaluationError(description: "confidence and coordinate output sizes disagree")
    }
    let classCount = confidence.count / coordinateCount
    let indices = try classIndices(for: classCount)
    let predictionCount = coordinateCount
    var results: [Detection] = []
    for index in 0..<predictionCount {
        for (label, classIndex) in indices {
            let score = confidence[index * classCount + classIndex].doubleValue
            guard score >= confidenceThreshold else { continue }
            let centerX = coordinates[index * 4].doubleValue
            let centerY = coordinates[index * 4 + 1].doubleValue
            let width = coordinates[index * 4 + 2].doubleValue
            let height = coordinates[index * 4 + 3].doubleValue
            results.append(Detection(
                label: label,
                confidence: score,
                xmin: max(0, centerX - width / 2),
                xmax: min(1, centerX + width / 2),
                ymin: max(0, centerY - height / 2),
                ymax: min(1, centerY + height / 2)
            ))
        }
    }
    return results
}

private func evaluate(
    records: [DatasetRecord],
    datasetDirectory: URL,
    model: MLModel,
    confidenceThreshold: Double,
    matchIoU: Double
) throws -> [String: ClassMetrics] {
    var metrics = Dictionary(
        uniqueKeysWithValues: tennisClassIndices.keys.map { ($0, ClassMetrics()) }
    )
    for record in records {
        let predictions = try detections(
            model: model,
            imageURL: datasetDirectory.appendingPathComponent(record.localImage),
            confidenceThreshold: confidenceThreshold,
            iouThreshold: 0.45
        )
        for label in tennisClassIndices.keys {
            let truths = record.boxes.filter { $0.label == label }
            let candidates = predictions
                .filter { $0.label == label }
                .sorted { $0.confidence > $1.confidence }
            var unmatchedTruths = Set(truths.indices)
            for candidate in candidates {
                let best = unmatchedTruths
                    .map { ($0, iou(candidate, truths[$0])) }
                    .max { $0.1 < $1.1 }
                if let best, best.1 >= matchIoU {
                    metrics[label]!.truePositive += 1
                    metrics[label]!.matchedIoUs.append(best.1)
                    unmatchedTruths.remove(best.0)
                } else {
                    metrics[label]!.falsePositive += 1
                }
            }
            metrics[label]!.falseNegative += unmatchedTruths.count
        }
    }
    return metrics
}

private func usage() -> Never {
    fputs("Usage: evaluate_coreml_racket_ball_detector.swift MODEL.mlmodelc DATASET_DIR [CONFIDENCE]\n", stderr)
    exit(2)
}

guard CommandLine.arguments.count >= 3 else { usage() }
let modelURL = URL(fileURLWithPath: CommandLine.arguments[1])
let datasetDirectory = URL(fileURLWithPath: CommandLine.arguments[2])
let confidenceThreshold = CommandLine.arguments.count > 3
    ? Double(CommandLine.arguments[3]) ?? 0.10
    : 0.10

do {
    let configuration = MLModelConfiguration()
    configuration.computeUnits = .all
    let model = try MLModel(contentsOf: modelURL, configuration: configuration)
    let datasetRecords = try records(
        at: datasetDirectory.appendingPathComponent("annotations.jsonl")
    )
    let result = try evaluate(
        records: datasetRecords,
        datasetDirectory: datasetDirectory,
        model: model,
        confidenceThreshold: confidenceThreshold,
        matchIoU: 0.50
    )
    let output: [String: Any] = [
        "schemaVersion": 1,
        "purpose": "Object-perception baseline only; not serve-technique accuracy.",
        "imageCount": datasetRecords.count,
        "confidenceThreshold": confidenceThreshold,
        "matchIoUThreshold": 0.50,
        "classes": Dictionary(uniqueKeysWithValues: result.map { label, value in
            let meanIoU = value.matchedIoUs.isEmpty
                ? 0
                : value.matchedIoUs.reduce(0, +) / Double(value.matchedIoUs.count)
            return (label, [
                "truePositive": value.truePositive,
                "falsePositive": value.falsePositive,
                "falseNegative": value.falseNegative,
                "precision": value.precision,
                "recall": value.recall,
                "meanMatchedIoU": meanIoU
            ] as [String: Any])
        }),
        "releaseInterpretation": [
            "canEstablishServeTechniqueAccuracy": false,
            "canEstablishPronationAccuracy": false
        ]
    ]
    let encoded = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: encoded, as: UTF8.self))
} catch {
    fputs("evaluation failed: \(error)\n", stderr)
    exit(1)
}
