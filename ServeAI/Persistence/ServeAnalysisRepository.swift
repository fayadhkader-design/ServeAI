import Foundation
import SwiftData

@MainActor
protocol ServeAnalysisRepository: AnyObject {
    func fetchAll() throws -> [ServeAnalysis]
    func save(_ analysis: ServeAnalysis) throws
    func saveChanges() throws
    func delete(_ analysis: ServeAnalysis) throws
}

@MainActor
final class SwiftDataServeAnalysisRepository: ServeAnalysisRepository {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    func fetchAll() throws -> [ServeAnalysis] {
        var descriptor = FetchDescriptor<ServeAnalysis>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        descriptor.fetchLimit = 100
        return try context.fetch(descriptor)
    }

    func save(_ analysis: ServeAnalysis) throws {
        context.insert(analysis)
        try context.save()
    }

    func saveChanges() throws {
        try context.save()
    }

    func delete(_ analysis: ServeAnalysis) throws {
        context.delete(analysis)
        try context.save()
    }
}
