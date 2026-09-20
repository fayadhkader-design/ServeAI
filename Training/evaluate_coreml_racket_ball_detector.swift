// Compile with ObjectDetectionSequenceSelector.swift; see Training/README.md.

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

private struct KeypointValue: Decodable {
    let status: String
    let x: Double?
    let y: Double?
}

private struct KeypointRecord: Decodable {
    let sampleID: String
    let localImage: String
    let points: [String: KeypointValue]
    let roi: CropRect?
    let sourcePixelWidth: Int?
    let sourcePixelHeight: Int?
}

private struct CropRect: Decodable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

private typealias Detection = ObjectDetectionCandidate

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

private struct CenterMetrics {
    var visibleCount = 0
    var truePositive = 0
    var falsePositive = 0
    var falseNegative = 0
    var matchedDistances: [Double] = []
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

private func keypointRecords(at path: URL) throws -> [KeypointRecord] {
    let text = try String(contentsOf: path, encoding: .utf8)
    let decoder = JSONDecoder()
    return try text.split(separator: "\n").map { line in
        try decoder.decode(KeypointRecord.self, from: Data(line.utf8))
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

private func sourceDetection(_ detection: Detection, metadata: KeypointRecord) throws -> Detection {
    guard let roi = metadata.roi,
          let sourceWidth = metadata.sourcePixelWidth, sourceWidth > 0,
          let sourceHeight = metadata.sourcePixelHeight, sourceHeight > 0 else {
        throw EvaluationError(description: "temporal evaluation requires source dimensions and ROI for \(metadata.sampleID)")
    }
    return Detection(
        label: detection.label, confidence: detection.confidence,
        xmin: (roi.x + detection.xmin * roi.width) / Double(sourceWidth),
        xmax: (roi.x + detection.xmax * roi.width) / Double(sourceWidth),
        ymin: (roi.y + detection.ymin * roi.height) / Double(sourceHeight),
        ymax: (roi.y + detection.ymax * roi.height) / Double(sourceHeight)
    )
}

private func cropDetection(_ detection: Detection, metadata: KeypointRecord) throws -> Detection {
    guard let roi = metadata.roi,
          let sourceWidth = metadata.sourcePixelWidth, sourceWidth > 0,
          let sourceHeight = metadata.sourcePixelHeight, sourceHeight > 0,
          roi.width > 0, roi.height > 0 else {
        throw EvaluationError(description: "temporal evaluation requires valid ROI geometry for \(metadata.sampleID)")
    }
    return Detection(
        label: detection.label, confidence: detection.confidence,
        xmin: (detection.xmin * Double(sourceWidth) - roi.x) / roi.width,
        xmax: (detection.xmax * Double(sourceWidth) - roi.x) / roi.width,
        ymin: (detection.ymin * Double(sourceHeight) - roi.y) / roi.height,
        ymax: (detection.ymax * Double(sourceHeight) - roi.y) / roi.height
    )
}

private func temporallySelectedDetections(
    records: [DatasetRecord],
    rawDetections: [[Detection]],
    keypoints: [KeypointRecord],
    confidenceThreshold: Double
) throws -> (frames: [[Detection]], linkedPairs: [String: Int]) {
    let metadataByID = Dictionary(uniqueKeysWithValues: keypoints.map { ($0.sampleID, $0) })
    let metadata = try records.map { record -> KeypointRecord in
        guard let value = metadataByID[record.imageID], value.localImage == record.localImage else {
            throw EvaluationError(description: "missing matching ROI metadata for \(record.imageID)")
        }
        return value
    }
    let sourceFrames = try zip(rawDetections, metadata).map { detections, info in
        try detections.map { try sourceDetection($0, metadata: info) }
    }
    var selected = Array(repeating: [Detection](), count: records.count)
    var linkedPairs: [String: Int] = [:]
    for label in tennisClassIndices.keys.sorted() {
        let track = ObjectDetectionSequenceSelector.select(
            frames: sourceFrames, label: label,
            minimumConfidence: confidenceThreshold
        )
        linkedPairs[label] = track.filter(\.linkedToPrevious).count
        for observation in track {
            selected[observation.frameIndex].append(try cropDetection(
                observation.candidate, metadata: metadata[observation.frameIndex]
            ))
        }
    }
    return (selected, linkedPairs)
}

private func evaluate(
    records: [DatasetRecord],
    predictionsByFrame: [[Detection]],
    matchIoU: Double
) -> [String: ClassMetrics] {
    var metrics = Dictionary(
        uniqueKeysWithValues: tennisClassIndices.keys.map { ($0, ClassMetrics()) }
    )
    for (record, predictions) in zip(records, predictionsByFrame) {
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

private func evaluateBallCenters(
    records: [KeypointRecord],
    predictionsByImage: [String: [Detection]],
    maximumCenterDistance: Double
) -> CenterMetrics {
    var metrics = CenterMetrics()
    for record in records {
        let predictions = (predictionsByImage[record.localImage] ?? [])
            .filter { $0.label == "tennis_ball" }
        guard let ball = record.points["ballCenter"],
              ball.status == "visible", let x = ball.x, let y = ball.y else {
            metrics.falsePositive += predictions.count
            continue
        }
        metrics.visibleCount += 1
        let distances = predictions.map { detection in
            let centerX = (detection.xmin + detection.xmax) / 2
            let centerY = (detection.ymin + detection.ymax) / 2
            return hypot(centerX - x, centerY - y)
        }
        guard let best = distances.min(), best <= maximumCenterDistance else {
            metrics.falseNegative += 1
            metrics.falsePositive += predictions.count
            continue
        }
        metrics.truePositive += 1
        metrics.matchedDistances.append(best)
        metrics.falsePositive += max(0, predictions.count - 1)
    }
    return metrics
}

private func usage() -> Never {
    fputs("Usage: evaluate_coreml_racket_ball_detector MODEL.mlmodelc DATASET_DIR [CONFIDENCE] [--temporal] [--per-frame]\n", stderr)
    exit(2)
}

@main
private enum DetectorEvaluator {
static func main() {
    guard CommandLine.arguments.count >= 3 else { usage() }
    let modelURL = URL(fileURLWithPath: CommandLine.arguments[1])
    let datasetDirectory = URL(fileURLWithPath: CommandLine.arguments[2])
    let confidenceThreshold = CommandLine.arguments.count > 3
        ? Double(CommandLine.arguments[3]) ?? 0.10
        : 0.10
    let includePerFrame = CommandLine.arguments.contains("--per-frame")
    let includeTemporal = CommandLine.arguments.contains("--temporal")

do {
    let configuration = MLModelConfiguration()
    configuration.computeUnits = .all
    let model = try MLModel(contentsOf: modelURL, configuration: configuration)
    let datasetRecords = try records(
        at: datasetDirectory.appendingPathComponent("annotations.jsonl")
    )
    let rawPredictions = try datasetRecords.map { record in
        try detections(
            model: model,
            imageURL: datasetDirectory.appendingPathComponent(record.localImage),
            confidenceThreshold: confidenceThreshold,
            iouThreshold: 0.45
        )
    }
    let keypointPath = datasetDirectory.appendingPathComponent("keypoints.jsonl")
    let keypoints = FileManager.default.fileExists(atPath: keypointPath.path)
        ? try keypointRecords(at: keypointPath) : nil
    var processedFrames = rawPredictions
    var linkedPairs: [String: Int] = [:]
    if includeTemporal {
        guard let keypoints else {
            throw EvaluationError(description: "temporal evaluation requires keypoints.jsonl")
        }
        let selected = try temporallySelectedDetections(
            records: datasetRecords,
            rawDetections: rawPredictions,
            keypoints: keypoints,
            confidenceThreshold: confidenceThreshold
        )
        processedFrames = selected.frames
        linkedPairs = selected.linkedPairs
    }
    let result = evaluate(
        records: datasetRecords,
        predictionsByFrame: processedFrames,
        matchIoU: 0.50
    )
    let predictionsByImage = Dictionary(uniqueKeysWithValues: zip(datasetRecords, processedFrames).map {
        ($0.localImage, $1)
    })
    let ballCenterResult: CenterMetrics? = keypoints.map {
        evaluateBallCenters(
            records: $0,
            predictionsByImage: predictionsByImage,
            maximumCenterDistance: 0.06
        )
    }
    let ballCenterJSON: Any = ballCenterResult.map { value in
        let meanDistance = value.matchedDistances.isEmpty
            ? 0
            : value.matchedDistances.reduce(0, +) / Double(value.matchedDistances.count)
        let precisionDenominator = value.truePositive + value.falsePositive
        return [
            "visibleCount": value.visibleCount,
            "truePositive": value.truePositive,
            "falsePositive": value.falsePositive,
            "falseNegative": value.falseNegative,
            "precision": precisionDenominator == 0 ? 0 : Double(value.truePositive) / Double(precisionDenominator),
            "recall": value.visibleCount == 0 ? 0 : Double(value.truePositive) / Double(value.visibleCount),
            "maximumNormalizedCenterDistance": 0.06,
            "meanMatchedNormalizedCenterDistance": meanDistance
        ] as [String: Any]
    } ?? NSNull()
    var output: [String: Any] = [
        "schemaVersion": 1,
        "purpose": "Object-perception pilot only; not serve-technique accuracy.",
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
        "ballCenterMetrics": ballCenterJSON,
        "releaseInterpretation": [
            "canEstablishServeTechniqueAccuracy": false,
            "canEstablishPronationAccuracy": false
        ]
    ]
    output["temporalAssociation"] = [
        "enabled": includeTemporal,
        "observationsOnly": true,
        "maximumFrameGap": ObjectDetectionSequenceSelector.maximumFrameGap,
        "maximumNormalizedDisplacementPerFrame": ObjectDetectionSequenceSelector.maximumNormalizedDisplacementPerFrame,
        "linkedPairs": linkedPairs
    ] as [String: Any]
    if includePerFrame {
        output["frames"] = zip(datasetRecords, processedFrames).map { record, predictions in
            return [
                "imageID": record.imageID,
                "detections": predictions.map { detection in
                    [
                        "label": detection.label,
                        "confidence": detection.confidence,
                        "xmin": detection.xmin,
                        "xmax": detection.xmax,
                        "ymin": detection.ymin,
                        "ymax": detection.ymax
                    ] as [String: Any]
                }
            ] as [String: Any]
        }
    }
    let encoded = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: encoded, as: UTF8.self))
} catch {
    fputs("evaluation failed: \(error)\n", stderr)
    exit(1)
}
}
}
