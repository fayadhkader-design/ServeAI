#!/usr/bin/env swift

import CreateML
import Foundation

private struct TrainingError: Error, CustomStringConvertible {
    let description: String
}

private func dataSource(at directory: URL) throws -> MLObjectDetector.DataSource {
    let images = directory.appendingPathComponent("images", isDirectory: true)
    let annotations = directory.appendingPathComponent("createml-annotations.json")
    guard FileManager.default.fileExists(atPath: images.path),
          FileManager.default.fileExists(atPath: annotations.path) else {
        throw TrainingError(description: "dataset must contain images/ and createml-annotations.json")
    }
    return .directoryWithImages(at: images, annotationFile: annotations)
}

private func metricsJSON(_ metrics: MLObjectDetectorMetrics) -> [String: Any] {
    [
        "isValid": metrics.isValid,
        "meanAveragePrecision": [
            "variedIoU": metrics.meanAveragePrecision.variedIoU,
            "IoU50": metrics.meanAveragePrecision.IoU50
        ],
        "averagePrecision": [
            "variedIoU": metrics.averagePrecision.variedIoU,
            "IoU50": metrics.averagePrecision.IoU50
        ],
        "error": metrics.error.map(String.init(describing:)) as Any
    ]
}

private func usage() -> Never {
    fputs("Usage: train_createml_racket_ball_detector.swift TRAIN_DIR VALIDATION_DIR OUTPUT.mlmodel [ITERATIONS]\n", stderr)
    exit(2)
}

guard CommandLine.arguments.count >= 4 else { usage() }
let trainingDirectory = URL(fileURLWithPath: CommandLine.arguments[1])
let validationDirectory = URL(fileURLWithPath: CommandLine.arguments[2])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[3])
let iterations = CommandLine.arguments.count > 4
    ? Int(CommandLine.arguments[4]) ?? 1000
    : 1000

do {
    guard outputURL.pathExtension == "mlmodel" else {
        throw TrainingError(description: "output must end in .mlmodel")
    }
    guard !FileManager.default.fileExists(atPath: outputURL.path) else {
        throw TrainingError(description: "refusing to overwrite existing model")
    }
    guard iterations > 0 else {
        throw TrainingError(description: "iterations must be positive")
    }

    let trainingData = try dataSource(at: trainingDirectory)
    let validationData = try dataSource(at: validationDirectory)
    let parameters = MLObjectDetector.ModelParameters(
        validation: .dataSource(validationData),
        batchSize: 8,
        maxIterations: iterations,
        gridSize: CGSize(width: 13, height: 13),
        algorithm: .transferLearning(.objectPrint(revision: 1))
    )
    let detector = try MLObjectDetector(
        trainingData: trainingData,
        parameters: parameters,
        annotationType: .boundingBox(units: .pixel, origin: .topLeft, anchor: .center)
    )
    let metadata = MLModelMetadata(
        author: "ServeAI research pipeline",
        shortDescription: "Research-only tennis racket and ball detector; not a validated coaching model.",
        license: "Training samples require per-image attribution; see the bound dataset manifest.",
        version: "0.1.0-research",
        additional: [
            "releaseEligible": "false",
            "coachVerified": "false",
            "purpose": "object-perception-research"
        ]
    )
    try detector.write(to: outputURL, metadata: metadata)

    let report: [String: Any] = [
        "schemaVersion": 1,
        "purpose": "Research-only object perception; not serve-technique accuracy.",
        "iterations": iterations,
        "algorithm": "CreateML ObjectPrint transfer learning revision 1",
        "trainingMetrics": metricsJSON(detector.trainingMetrics),
        "validationMetrics": metricsJSON(detector.validationMetrics),
        "releaseEligible": false
    ]
    let encoded = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: encoded, as: UTF8.self))
} catch {
    fputs("training failed: \(error)\n", stderr)
    exit(1)
}
