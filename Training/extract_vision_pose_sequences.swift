import AVFoundation
import CryptoKit
import Foundation
import ImageIO
import Vision

private let jointOrder: [(String, VNHumanBodyPoseObservation.JointName)] = [
    ("nose", .nose),
    ("neck", .neck),
    ("root", .root),
    ("leftShoulder", .leftShoulder),
    ("rightShoulder", .rightShoulder),
    ("leftElbow", .leftElbow),
    ("rightElbow", .rightElbow),
    ("leftWrist", .leftWrist),
    ("rightWrist", .rightWrist),
    ("leftHip", .leftHip),
    ("rightHip", .rightHip),
    ("leftKnee", .leftKnee),
    ("rightKnee", .rightKnee),
    ("leftAnkle", .leftAnkle),
    ("rightAnkle", .rightAnkle),
]

private struct Arguments {
    let input: URL
    let output: URL
    let sampleCount: Int
    let limit: Int?
    let participantPseudonym: String?

    init() throws {
        var input: URL?
        var output: URL?
        var sampleCount = 32
        var limit: Int?
        var participantPseudonym: String?
        var iterator = CommandLine.arguments.dropFirst().makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--input":
                guard let value = iterator.next() else { throw ExtractionError.usage }
                input = URL(fileURLWithPath: value)
            case "--output":
                guard let value = iterator.next() else { throw ExtractionError.usage }
                output = URL(fileURLWithPath: value)
            case "--samples":
                guard let value = iterator.next(), let parsed = Int(value), parsed >= 24 else {
                    throw ExtractionError.usage
                }
                sampleCount = parsed
            case "--limit":
                guard let value = iterator.next(), let parsed = Int(value), parsed > 0 else {
                    throw ExtractionError.usage
                }
                limit = parsed
            case "--participant":
                guard let value = iterator.next(),
                      !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ExtractionError.usage
                }
                participantPseudonym = value
            default:
                throw ExtractionError.usage
            }
        }
        guard let input, let output else { throw ExtractionError.usage }
        self.input = input
        self.output = output
        self.sampleCount = sampleCount
        self.limit = limit
        self.participantPseudonym = participantPseudonym
    }
}

private enum ExtractionError: Error, CustomStringConvertible {
    case usage
    case noVideos(URL)
    case invalidFilename(String)
    case invalidDuration(String)

    var description: String {
        switch self {
        case .usage:
            return "usage: extract_vision_pose_sequences --input DIR --output FILE [--samples 32] [--limit N] [--participant ID]"
        case let .noVideos(url):
            return "no AVI or MP4 videos found under \(url.path)"
        case let .invalidFilename(name):
            return "unrecognized THETIS filename: \(name)"
        case let .invalidDuration(name):
            return "video has an invalid duration: \(name)"
        }
    }
}

private struct PointValue {
    let x: Double
    let y: Double
    let confidence: Double
}

@main
private struct VisionPoseSequenceExtractor {
    static func main() async {
        do {
            let arguments = try Arguments()
            try FileManager.default.createDirectory(
                at: arguments.output.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            FileManager.default.createFile(atPath: arguments.output.path, contents: nil)
            let handle = try FileHandle(forWritingTo: arguments.output)
            defer { try? handle.close() }

            var videos = try discoverVideos(under: arguments.input)
            if let limit = arguments.limit {
                videos = Array(videos.prefix(limit))
            }
            guard !videos.isEmpty else { throw ExtractionError.noVideos(arguments.input) }

            var successful = 0
            var rejected = 0
            for (index, video) in videos.enumerated() {
                do {
                    let record = try await extract(
                        video: video,
                        sampleCount: arguments.sampleCount,
                        participantPseudonym: arguments.participantPseudonym
                    )
                    let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
                    try handle.write(contentsOf: data)
                    try handle.write(contentsOf: Data([0x0A]))
                    successful += 1
                } catch {
                    rejected += 1
                    FileHandle.standardError.write(Data("rejected \(video.lastPathComponent): \(error)\n".utf8))
                }
                if (index + 1).isMultiple(of: 20) || index + 1 == videos.count {
                    print("processed \(index + 1)/\(videos.count); usable=\(successful), rejected=\(rejected)")
                }
            }
            print("wrote \(successful) Apple Vision pose sequences to \(arguments.output.path); rejected=\(rejected)")
        } catch {
            FileHandle.standardError.write(Data("Vision extraction stopped: \(error)\n".utf8))
            Foundation.exit(1)
        }
    }

    private static func discoverVideos(under root: URL) throws -> [URL] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return enumerator.compactMap { item -> URL? in
            guard let url = item as? URL,
                  ["avi", "mp4", "mov"].contains(url.pathExtension.lowercased()),
                  (try? url.resourceValues(forKeys: keys).isRegularFile) == true else { return nil }
            return url
        }.sorted { $0.path < $1.path }
    }

    private static func extract(
        video: URL,
        sampleCount: Int,
        participantPseudonym: String?
    ) async throws -> [String: Any] {
        let filename = video.deletingPathExtension().lastPathComponent
        let pieces = filename.split(separator: "_")
        let participant: String
        let serveType: String
        let repetition: String
        if let participantPseudonym {
            participant = participantPseudonym
            serveType = "calibration"
            repetition = filename
        } else {
            guard pieces.count >= 3,
                  pieces[0].first == "p",
                  Int(pieces[0].dropFirst()) != nil else {
                throw ExtractionError.invalidFilename(filename)
            }
            participant = "thetis-\(pieces[0])"
            serveType = String(pieces[1])
            repetition = String(pieces[2])
        }

        let asset = AVURLAsset(url: video)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0.5 else { throw ExtractionError.invalidDuration(filename) }
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let frameRate = try await tracks.first?.load(.nominalFrameRate) ?? 0
        let naturalSize = try await tracks.first?.load(.naturalSize) ?? .zero
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 120)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 120)

        let start = min(0.08, duration * 0.02)
        let end = max(start + 0.1, duration - start)
        var frames: [[String: Any]] = []
        for step in 0..<sampleCount {
            let fraction = sampleCount == 1 ? 0.5 : Double(step) / Double(sampleCount - 1)
            let timestamp = start + fraction * (end - start)
            let requested = CMTime(seconds: timestamp, preferredTimescale: 600)
            var actual = CMTime.zero
            let image = try generator.copyCGImage(at: requested, actualTime: &actual)
            guard let observation = try detectPose(in: image) else { continue }
            if let frame = normalizedFrame(observation: observation, timestamp: actual.seconds) {
                frames.append(frame)
            }
        }

        let sha256 = try hash(video)
        return [
            "sourcePath": video.path,
            "sourceFilename": video.lastPathComponent,
            "sourceVideoSHA256": sha256,
            "participantPseudonym": participant,
            "serveType": serveType,
            "repetition": repetition,
            "duration": duration,
            "width": Int(abs(naturalSize.width)),
            "height": Int(abs(naturalSize.height)),
            "nominalFrameRate": Double(frameRate),
            "sampledFrameCount": sampleCount,
            "detectedFrameCount": frames.count,
            "frames": frames,
        ]
    }

    private static func detectPose(in image: CGImage) throws -> VNHumanBodyPoseObservation? {
        let request = VNDetectHumanBodyPoseRequest()
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
        try handler.perform([request])
        return request.results?.max { lhs, rhs in lhs.confidence < rhs.confidence }
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

    private static func hash(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
