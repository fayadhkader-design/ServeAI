import CoreTransferable
import Foundation
import UniformTypeIdentifiers

struct ImportedVideo: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { video in
            SentTransferredFile(video.url)
        } importing: { received in
            let destination = try VideoStorage.makeDestination(extension: received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension)
            try FileManager.default.copyItem(at: received.file, to: destination)
            return ImportedVideo(url: destination)
        }
    }
}

enum VideoStorage {
    static var directoryURL: URL {
        URL.documentsDirectory.appending(path: "ServeVideos", directoryHint: .isDirectory)
    }

    static func makeDestination(extension fileExtension: String = "mov") throws -> URL {
        let base = directoryURL
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appending(path: "serve-\(UUID().uuidString).\(fileExtension)")
    }

    static func persist(_ source: URL) throws -> URL {
        let destination = try makeDestination(extension: source.pathExtension.isEmpty ? "mov" : source.pathExtension)
        if source.standardizedFileURL == destination.standardizedFileURL { return source }
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }
}
