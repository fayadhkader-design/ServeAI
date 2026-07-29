import CoreML
import Foundation

private struct BatchInput: Decodable {
    let samples: [[Double]]
}

private struct BatchOutput: Encodable {
    let predictions: [[String: [Double]]]
}

@main
private enum CompiledCoreMLParityRunner {
    static func main() throws {
        guard CommandLine.arguments.count == 4 else {
            throw RunnerError.usage
        }
        let modelURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let inputURL = URL(fileURLWithPath: CommandLine.arguments[2])
        let outputURL = URL(fileURLWithPath: CommandLine.arguments[3])
        let input = try JSONDecoder().decode(BatchInput.self, from: Data(contentsOf: inputURL))

        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuOnly
        let model = try MLModel(contentsOf: modelURL, configuration: configuration)
        let requiredOutputs = [
            "usability", "phaseVisibility", "boundaries",
            "techniqueVisibility", "ratings", "priority",
        ]
        var predictions: [[String: [Double]]] = []
        predictions.reserveCapacity(input.samples.count)
        for sample in input.samples {
            let features = try MLMultiArray(
                shape: [NSNumber(value: sample.count)],
                dataType: .float32
            )
            for (index, value) in sample.enumerated() {
                features[index] = NSNumber(value: Float(value))
            }
            let provider = try MLDictionaryFeatureProvider(dictionary: [
                "features": MLFeatureValue(multiArray: features),
            ])
            let result = try model.prediction(from: provider)
            var values: [String: [Double]] = [:]
            for name in requiredOutputs {
                guard let array = result.featureValue(for: name)?.multiArrayValue else {
                    throw RunnerError.missingOutput(name)
                }
                values[name] = (0..<array.count).map { array[$0].doubleValue }
            }
            predictions.append(values)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(BatchOutput(predictions: predictions)).write(to: outputURL, options: .atomic)
    }
}

private enum RunnerError: LocalizedError {
    case usage
    case missingOutput(String)

    var errorDescription: String? {
        switch self {
        case .usage:
            "usage: run_compiled_coreml_parity <model.mlmodelc> <input.json> <output.json>"
        case .missingOutput(let name):
            "compiled model output \(name) is missing"
        }
    }
}
