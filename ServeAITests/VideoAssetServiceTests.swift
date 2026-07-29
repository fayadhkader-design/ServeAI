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
        defer { try? manager.deleteOwnedVideo(at: referenced) }

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
}
