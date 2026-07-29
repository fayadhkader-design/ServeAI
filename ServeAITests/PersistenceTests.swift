import SwiftData
import XCTest
@testable import ServeAI

@MainActor
final class PersistenceTests: XCTestCase {
    func testSaveFetchAndDelete() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: ServeAnalysis.self, configurations: configuration)
        let repository = SwiftDataServeAnalysisRepository(context: container.mainContext)
        let analysis = MockData.analysis()

        try repository.save(analysis)
        var fetched = try repository.fetchAll()
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.id, analysis.id)
        XCTAssertEqual(fetched.first?.phaseScores.count, 10)

        try repository.delete(analysis)
        fetched = try repository.fetchAll()
        XCTAssertTrue(fetched.isEmpty)
    }

    func testAppViewModelDeleteRemovesRecordAndOwnedVideo() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: ServeAnalysis.self, configurations: configuration)
        let videoManager = LocalVideoAssetManager()
        let appModel = AppViewModel(
            configuration: AppConfiguration(analysisMode: .mock),
            videoAssetManager: videoManager
        )
        appModel.configure(context: container.mainContext)

        let videoURL = try VideoStorage.makeDestination(extension: "mp4")
        try Data("disposable acceptance fixture".utf8).write(to: videoURL)
        let analysis = MockData.analysis(videoURL: videoURL)
        appModel.save(analysis)

        XCTAssertEqual(appModel.analyses.map(\.id), [analysis.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: videoURL.path))

        appModel.delete(analysis)

        XCTAssertTrue(appModel.analyses.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: videoURL.path))
    }
}
