import AVFoundation
import Foundation
import XCTest
@testable import ServeAI

final class VideoAssetServiceTests: XCTestCase {
    private let manager = LocalVideoAssetManager()

    func testDeleteOwnedVideoRemovesManagedFile() throws {
        let file = try VideoStorage.makeDestination(extension: "mov")
        try Data("serve".utf8).write(to: file)

        XCTAssertTrue(try manager.deleteOwnedVideo(at: file))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testDeleteOwnedVideoRefusesFileOutsideManagedDirectory() throws {
        let file = FileManager.default.temporaryDirectory
            .appending(path: "serveai-external-\(UUID().uuidString).mov")
        try Data("external".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        XCTAssertFalse(try manager.deleteOwnedVideo(at: file))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testCleanupPreservesReferencedVideoAndRemovesOrphan() throws {
        let referenced = try VideoStorage.makeDestination(extension: "mov")
        let orphan = try VideoStorage.makeDestination(extension: "mov")
        try Data("referenced".utf8).write(to: referenced)
        try Data("orphan".utf8).write(to: orphan)
        defer { _ = try? manager.deleteOwnedVideo(at: referenced) }

        let removed = try manager.cleanupOrphanedVideos(referencedURLs: [referenced])

        XCTAssertEqual(removed, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: referenced.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
    }

    func testUnreadableVideoDoesNotFabricateThumbnail() async {
        let missing = FileManager.default.temporaryDirectory
            .appending(path: "missing-\(UUID().uuidString).mov")

        let thumbnail = await manager.thumbnailData(for: missing)

        XCTAssertNil(thumbnail)
    }

    func testClipSelectionUsesWholeSourceWhenBoundsAreOmitted() throws {
        let selection = VideoClipSelection.fullClip(URL(fileURLWithPath: "/tmp/serve.mov"))

        let range = try selection.validated(sourceDuration: 7.4)

        XCTAssertEqual(range.lowerBound, 0)
        XCTAssertEqual(range.upperBound, 7.4)
        XCTAssertTrue(selection.usesFullClip)
    }

    func testClipSelectionAcceptsACompleteServeRange() throws {
        let selection = VideoClipSelection(
            sourceURL: URL(fileURLWithPath: "/tmp/serve.mov"),
            startTime: 2.1,
            endTime: 8.7
        )

        let range = try selection.validated(sourceDuration: 12)

        XCTAssertEqual(range.lowerBound, 2.1)
        XCTAssertEqual(range.upperBound, 8.7)
        XCTAssertEqual(try XCTUnwrap(selection.selectedDuration), 6.6, accuracy: 0.0001)
    }

    func testClipSelectionRejectsLessThanTwoSeconds() {
        let selection = VideoClipSelection(
            sourceURL: URL(fileURLWithPath: "/tmp/serve.mov"),
            startTime: 2,
            endTime: 3.9
        )

        XCTAssertThrowsError(try selection.validated(sourceDuration: 12)) { error in
            guard case ServeAIError.videoTooShort = error else {
                return XCTFail("Expected videoTooShort, got \(error)")
            }
        }
    }

    func testClipSelectionAcceptsExactlyTwoSeconds() throws {
        let selection = VideoClipSelection(
            sourceURL: URL(fileURLWithPath: "/tmp/serve.mov"),
            startTime: 1,
            endTime: 3
        )

        let range = try selection.validated(sourceDuration: 4)

        XCTAssertEqual(range.lowerBound, 1)
        XCTAssertEqual(range.upperBound, 3)
    }

    func testClipSelectionRejectsMoreThanFortyFiveSeconds() {
        let selection = VideoClipSelection.fullClip(URL(fileURLWithPath: "/tmp/serve.mov"))

        XCTAssertThrowsError(try selection.validated(sourceDuration: 46)) { error in
            guard case ServeAIError.videoTooLong = error else {
                return XCTFail("Expected videoTooLong, got \(error)")
            }
        }
    }

    func testClipSelectionRejectsOutOfBoundsEnd() {
        let selection = VideoClipSelection(
            sourceURL: URL(fileURLWithPath: "/tmp/serve.mov"),
            startTime: 1,
            endTime: 14
        )

        XCTAssertThrowsError(try selection.validated(sourceDuration: 12)) { error in
            guard case ServeAIError.corruptedVideo = error else {
                return XCTFail("Expected corruptedVideo, got \(error)")
            }
        }
    }

    func testExporterCreatesOnlyTheSelectedServeRange() async throws {
        let source = try XCTUnwrap(resourceURL(named: "IMG_6105-A-pose-crop"))
        let selection = VideoClipSelection(
            sourceURL: source,
            startTime: 0.5,
            endTime: 3.0
        )

        let output = try await AVVideoClipExporter().prepare(selection)
        defer { _ = try? manager.deleteOwnedVideo(at: output) }

        XCTAssertNotEqual(output, source)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        let duration = try await AVURLAsset(url: output).load(.duration).seconds
        XCTAssertEqual(duration, 2.5, accuracy: 0.12)
    }

    private func resourceURL(named name: String) -> URL? {
        let bundle = Bundle(for: Self.self)
        return bundle.url(forResource: name, withExtension: "mp4", subdirectory: "Fixtures")
            ?? bundle.url(forResource: name, withExtension: "mp4")
    }
}
