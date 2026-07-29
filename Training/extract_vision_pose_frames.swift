import Foundation
import ImageIO
import Vision

private let jointOrder: [(String, VNHumanBodyPoseObservation.JointName)] = [
    ("nose", .nose), ("neck", .neck), ("root", .root),
    ("leftShoulder", .leftShoulder), ("rightShoulder", .rightShoulder),
    ("leftElbow", .leftElbow), ("rightElbow", .rightElbow),
    ("leftWrist", .leftWrist), ("rightWrist", .rightWrist),
    ("leftHip", .leftHip), ("rightHip", .rightHip),
    ("leftKnee", .leftKnee), ("rightKnee", .rightKnee),
    ("leftAnkle", .leftAnkle), ("rightAnkle", .rightAnkle),
]

private struct Arguments {
    let input: URL
    let output: URL
    let participant: String
    let samplesPerSecond: Double

    init() throws {
        var input: URL?
        var output: URL?
        var participant: String?
        var samplesPerSecond = 15.0
        var iterator = CommandLine.arguments.dropFirst().makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--input":
                input = iterator.next().map { URL(fileURLWithPath: $0) }
            case "--output":
                output = iterator.next().map { URL(fileURLWithPath: $0) }
            case "--participant":
                participant = iterator.next()
            case "--fps":
                guard let value = iterator.next(), let parsed = Double(value), parsed > 0 else {
                    throw ExtractionError.usage
                }
                samplesPerSecond = parsed
            default:
                throw ExtractionError.usage
            }
        }
        guard let input, let output, let participant, !participant.isEmpty else {
            throw ExtractionError.usage
        }
        self.input = input
        self.output = output
        self.participant = participant
        self.samplesPerSecond = samplesPerSecond
    }
}

private enum ExtractionError: Error, CustomStringConvertible {
    case usage
    case noFrameDirectories
    case unreadableImage(String)

    var description: String {
        switch self {
        case .usage:
            "usage: extract_vision_pose_frames --input DIR --output FILE --participant ID [--fps 15]"
        case .noFrameDirectories:
            "no frame directories containing JPG or PNG files were found"
        case .unreadableImage(let name):
            "could not decode image \(name)"
        }
    }
}

private struct PointValue {
    let x: Double
    let y: Double
    let confidence: Double
}

@main
private struct VisionPoseFrameExtractor {
    static func main() {
        do {
            let arguments = try Arguments()
            let groups = try discoverGroups(under: arguments.input)
            guard !groups.isEmpty else { throw ExtractionError.noFrameDirectories }
            try FileManager.default.createDirectory(
                at: arguments.output.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            FileManager.default.createFile(atPath: arguments.output.path, contents: nil)
            let handle = try FileHandle(forWritingTo: arguments.output)
            defer { try? handle.close() }

            for (name, images) in groups.sorted(by: { $0.key < $1.key }) {
                var frames: [[String: Any]] = []
                for (index, imageURL) in images.enumerated() {
                    guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
                          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                        throw ExtractionError.unreadableImage(imageURL.lastPathComponent)
                    }
                    let request = VNDetectHumanBodyPoseRequest()
                    try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
                    guard let observation = request.results?.max(by: { $0.confidence < $1.confidence }),
                          let frame = normalizedFrame(
                            observation: observation,
                            timestamp: Double(index) / arguments.samplesPerSecond
                          ) else { continue }
                    frames.append(frame)
                }
                let record: [String: Any] = [
                    "sourceFilename": name,
                    "participantPseudonym": arguments.participant,
                    "duration": Double(max(images.count - 1, 0)) / arguments.samplesPerSecond,
                    "requestedSamplesPerSecond": arguments.samplesPerSecond,
                    "sampledFrameCount": images.count,
                    "detectedFrameCount": frames.count,
                    "frames": frames,
                ]
                let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
                try handle.write(contentsOf: data)
                try handle.write(contentsOf: Data([0x0A]))
                print("\(name): detected \(frames.count)/\(images.count) pose frames")
            }
        } catch {
            FileHandle.standardError.write(Data("Vision frame extraction stopped: \(error)\n".utf8))
            Foundation.exit(1)
        }
    }

    private static func discoverGroups(under root: URL) throws -> [String: [URL]] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return [:] }
        var groups: [String: [URL]] = [:]
        for case let url as URL in enumerator {
            guard ["jpg", "jpeg", "png"].contains(url.pathExtension.lowercased()),
                  (try? url.resourceValues(forKeys: keys).isRegularFile) == true else { continue }
            groups[url.deletingLastPathComponent().lastPathComponent, default: []].append(url)
        }
        return groups.mapValues { $0.sorted { $0.lastPathComponent < $1.lastPathComponent } }
    }

    private static func normalizedFrame(
        observation: VNHumanBodyPoseObservation,
        timestamp: Double
    ) -> [String: Any]? {
        let recognized = (try? observation.recognizedPoints(.all)) ?? [:]
        var points: [String: PointValue] = [:]
        for (name, visionName) in jointOrder {
            guard let point = recognized[visionName], point.confidence >= 0.10 else { continue }
            points[name] = PointValue(
                x: Double(point.location.x),
                y: Double(point.location.y),
                confidence: Double(point.confidence)
            )
        }
        let centers = [points["root"], points["leftHip"], points["rightHip"]].compactMap { $0 }
        guard !centers.isEmpty else { return nil }
        let centerX = centers.map(\.x).reduce(0, +) / Double(centers.count)
        let centerY = centers.map(\.y).reduce(0, +) / Double(centers.count)
        let scalePoints = [points["nose"], points["neck"], points["leftAnkle"], points["rightAnkle"]].compactMap { $0 }
        let scale = max(scalePoints.map { hypot($0.x - centerX, $0.y - centerY) }.max() ?? 0, 0.10)
        let joints: [[String: Any]] = jointOrder.map { name, _ in
            guard let point = points[name] else {
                return ["joint": name, "x": 0.0, "y": 0.0, "confidence": 0.0, "isPresent": false]
            }
            return [
                "joint": name,
                "x": (point.x - centerX) / scale,
                "y": (point.y - centerY) / scale,
                "confidence": point.confidence,
                "isPresent": true,
            ]
        }
        let confidence = points.values.map(\.confidence).reduce(0, +) / Double(max(points.count, 1))
        return [
            "timestamp": timestamp,
            "bodyConfidence": confidence,
            "rawRootX": centerX,
            "rawRootY": centerY,
            "rawScale": scale,
            "joints": joints,
        ]
    }
}
