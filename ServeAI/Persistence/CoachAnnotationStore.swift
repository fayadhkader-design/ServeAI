import Foundation

struct CoachAnnotationSessionDescriptor: Identifiable, Hashable, Sendable {
    let annotationID: UUID
    let analysisID: UUID
    let createdAt: Date
    let annotatorPseudonym: String?
    let schemaVersion: Int

    var id: UUID { annotationID }
}

protocol CoachAnnotationPersisting: Sendable {
    func listSessions(analysisID: UUID) async throws -> [CoachAnnotationSessionDescriptor]
    func load(analysisID: UUID, annotationID: UUID) async throws -> CoachServeAnnotationPackage?
    func save(_ package: CoachServeAnnotationPackage) async throws
    func delete(analysisID: UUID, annotationID: UUID) async throws
    func deleteAll(analysisID: UUID) async throws
}

enum CoachAnnotationStoreError: LocalizedError {
    case mismatchedAnalysis
    case mismatchedAnnotation

    var errorDescription: String? {
        switch self {
        case .mismatchedAnalysis: "The saved annotation does not match this analysis."
        case .mismatchedAnnotation: "The saved annotation does not match this labeling session."
        }
    }
}

actor LocalCoachAnnotationStore: CoachAnnotationPersisting {
    private let directoryURL: URL
    private let fileManager: FileManager

    init(
        directoryURL: URL = URL.applicationSupportDirectory
            .appending(path: "ServeAI", directoryHint: .isDirectory)
            .appending(path: "CoachAnnotations", directoryHint: .isDirectory),
        fileManager: FileManager = .default
    ) {
        self.directoryURL = directoryURL
        self.fileManager = fileManager
    }

    func listSessions(analysisID: UUID) throws -> [CoachAnnotationSessionDescriptor] {
        try loadPackages(analysisID: analysisID).map { package in
            CoachAnnotationSessionDescriptor(
                annotationID: package.annotationID,
                analysisID: package.analysisID,
                createdAt: package.createdAt,
                annotatorPseudonym: package.annotatorPseudonym,
                schemaVersion: package.schemaVersion
            )
        }
    }

    func load(analysisID: UUID, annotationID: UUID) throws -> CoachServeAnnotationPackage? {
        try migrateLegacyFileIfNeeded(analysisID: analysisID)
        let url = annotationFileURL(analysisID: analysisID, annotationID: annotationID)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let package = try decodePackage(at: url)
        guard package.analysisID == analysisID else { throw CoachAnnotationStoreError.mismatchedAnalysis }
        guard package.annotationID == annotationID else { throw CoachAnnotationStoreError.mismatchedAnnotation }
        return package
    }

    func save(_ package: CoachServeAnnotationPackage) throws {
        let analysisDirectory = analysisDirectoryURL(for: package.analysisID)
        try fileManager.createDirectory(at: analysisDirectory, withIntermediateDirectories: true)
        let data = try CoachAnnotationExporter().data(for: package)
        try data.write(
            to: annotationFileURL(
                analysisID: package.analysisID,
                annotationID: package.annotationID
            ),
            options: [.atomic, .completeFileProtection]
        )
        let legacy = legacyFileURL(for: package.analysisID)
        if fileManager.fileExists(atPath: legacy.path) {
            try fileManager.removeItem(at: legacy)
        }
    }

    func delete(analysisID: UUID, annotationID: UUID) throws {
        let url = annotationFileURL(analysisID: analysisID, annotationID: annotationID)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
        let directory = analysisDirectoryURL(for: analysisID)
        let remaining = try fileManager.contentsOfDirectory(atPath: directory.path)
        if remaining.isEmpty {
            try fileManager.removeItem(at: directory)
        }
    }

    func deleteAll(analysisID: UUID) throws {
        let directory = analysisDirectoryURL(for: analysisID)
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
        let legacy = legacyFileURL(for: analysisID)
        if fileManager.fileExists(atPath: legacy.path) {
            try fileManager.removeItem(at: legacy)
        }
    }

    private func loadPackages(analysisID: UUID) throws -> [CoachServeAnnotationPackage] {
        try migrateLegacyFileIfNeeded(analysisID: analysisID)
        let directory = analysisDirectoryURL(for: analysisID)
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        let urls = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        let packages = try urls
            .filter { $0.pathExtension.lowercased() == "json" }
            .map { try decodePackage(at: $0) }
        guard packages.allSatisfy({ $0.analysisID == analysisID }) else {
            throw CoachAnnotationStoreError.mismatchedAnalysis
        }
        return packages.sorted {
            if $0.createdAt == $1.createdAt {
                return $0.annotationID.uuidString < $1.annotationID.uuidString
            }
            return $0.createdAt > $1.createdAt
        }
    }

    private func migrateLegacyFileIfNeeded(analysisID: UUID) throws {
        let legacy = legacyFileURL(for: analysisID)
        guard fileManager.fileExists(atPath: legacy.path) else { return }
        let data = try Data(contentsOf: legacy)
        let package = try decodePackage(data)
        guard package.analysisID == analysisID else { throw CoachAnnotationStoreError.mismatchedAnalysis }
        let directory = analysisDirectoryURL(for: analysisID)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = annotationFileURL(
            analysisID: analysisID,
            annotationID: package.annotationID
        )
        if !fileManager.fileExists(atPath: destination.path) {
            try data.write(to: destination, options: [.atomic, .completeFileProtection])
        }
        try fileManager.removeItem(at: legacy)
    }

    private func decodePackage(at url: URL) throws -> CoachServeAnnotationPackage {
        try decodePackage(Data(contentsOf: url))
    }

    private func decodePackage(_ data: Data) throws -> CoachServeAnnotationPackage {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(CoachServeAnnotationPackage.self, from: data)
    }

    private func analysisDirectoryURL(for analysisID: UUID) -> URL {
        directoryURL.appending(
            path: "analysis-\(analysisID.uuidString.lowercased())",
            directoryHint: .isDirectory
        )
    }

    private func annotationFileURL(analysisID: UUID, annotationID: UUID) -> URL {
        analysisDirectoryURL(for: analysisID)
            .appending(path: "annotation-\(annotationID.uuidString.lowercased())")
            .appendingPathExtension("json")
    }

    private func legacyFileURL(for analysisID: UUID) -> URL {
        directoryURL
            .appending(path: "analysis-\(analysisID.uuidString.lowercased())")
            .appendingPathExtension("json")
    }
}
