import AVFoundation
import Foundation
import Photos

struct RepairResult {
    /// Identifier of the new asset, or nil when nothing was created.
    let newAssetID: String?
    /// Originals that are safe to delete once the user has checked the result.
    let replacedAssetIDs: [String]
}

/// Talks to the Photos library: exports originals, builds the replacement, and saves it.
/// PhotoKit cannot turn an existing video into a photo in place, so every repair
/// creates a new asset and leaves the old one for the user to delete afterwards.
enum RepairService {
    static func repair(_ candidate: Candidate) async throws -> RepairResult {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LivePhotoRepair", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let video = candidate.video

        switch candidate.action {
        case .skip:
            return RepairResult(newAssetID: nil, replacedAssetIDs: [])

        case .removeDuplicateVideo:
            return RepairResult(newAssetID: nil, replacedAssetIDs: [video.localIdentifier])

        case .pairWithStill:
            guard let still = candidate.matchedStill else {
                throw RepairError.message("No matching still to pair with.")
            }
            let identifier = UUID().uuidString
            let videoURL = try await export(video, types: [.video, .fullSizeVideo], to: workDir)
            let stillURL = try await export(still, types: [.photo, .fullSizePhoto], to: workDir)

            let stampedStill = try LivePhotoBuilder.stampStill(at: stillURL, into: workDir, identifier: identifier)
            let movieURL = workDir.appendingPathComponent("paired.mov")
            // The original key photo sat in the middle of the clip.
            try await LivePhotoBuilder.writePairedVideo(
                from: videoURL, to: movieURL, identifier: identifier, stillTime: candidate.duration / 2
            )

            let newID = try await save(photo: stampedStill, pairedVideo: movieURL, copyingFrom: [still, video])
            return RepairResult(newAssetID: newID, replacedAssetIDs: [video.localIdentifier, still.localIdentifier])

        case .rebuildLivePhoto, .stillOnly:
            let videoURL = try await export(video, types: [.video, .fullSizeVideo], to: workDir)
            let asset = AVURLAsset(url: videoURL)

            let frame: CGImage
            let frameTime: Double
            if let chosen = candidate.keyFrameTime {
                frame = try await FrameExtractor.frame(of: asset, at: chosen)
                frameTime = chosen
            } else {
                (frame, frameTime) = try await FrameExtractor.bestFrame(of: asset)
            }

            // A matching still that is kept stays in the library, so only the video is replaced.
            let sources = [video] + (candidate.matchedStill.map { [$0] } ?? [])

            if candidate.action == .stillOnly {
                let stillURL = try LivePhotoBuilder.writeStill(frame, into: workDir, identifier: nil)
                let newID = try await save(photo: stillURL, pairedVideo: nil, copyingFrom: sources)
                return RepairResult(newAssetID: newID, replacedAssetIDs: [video.localIdentifier])
            }

            let identifier = UUID().uuidString
            let stillURL = try LivePhotoBuilder.writeStill(frame, into: workDir, identifier: identifier)
            let movieURL = workDir.appendingPathComponent("paired.mov")
            try await LivePhotoBuilder.writePairedVideo(
                from: videoURL, to: movieURL, identifier: identifier, stillTime: frameTime
            )
            let newID = try await save(photo: stillURL, pairedVideo: movieURL, copyingFrom: sources)
            return RepairResult(newAssetID: newID, replacedAssetIDs: [video.localIdentifier])
        }
    }

    /// Moves assets to Recently Deleted. macOS shows its own confirmation dialog.
    static func delete(assetIDs: [String]) async throws {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: assetIDs, options: nil)
        guard assets.count > 0 else { return }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(assets)
        }
    }

    // MARK: Helpers

    private static func export(_ asset: PHAsset, types: [PHAssetResourceType], to directory: URL) async throws -> URL {
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = types.lazy.compactMap({ type in resources.first { $0.type == type } }).first else {
            throw RepairError.message("Could not find the original file for this item.")
        }

        let url = directory.appendingPathComponent("\(UUID().uuidString)-\(resource.originalFilename)")
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true  // Download from iCloud if needed.

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
        return url
    }

    /// Creates the new asset and carries over the date, location, favorite and hidden
    /// state of the first source, plus every album any source was in.
    private static func save(photo: URL, pairedVideo: URL?, copyingFrom sources: [PHAsset]) async throws -> String {
        let primary = sources[0]
        let albums = sources.flatMap { source -> [PHAssetCollection] in
            var found: [PHAssetCollection] = []
            PHAssetCollection.fetchAssetCollectionsContaining(source, with: .album, options: nil)
                .enumerateObjects { album, _, _ in
                    if album.canPerform(.addContent) { found.append(album) }
                }
            return found
        }
        var seen = Set<String>()
        let uniqueAlbums = albums.filter { seen.insert($0.localIdentifier).inserted }

        let createdID = IdentifierBox()
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.shouldMoveFile = true
            request.addResource(with: .photo, fileURL: photo, options: options)
            if let pairedVideo {
                request.addResource(with: .pairedVideo, fileURL: pairedVideo, options: options)
            }
            request.creationDate = sources.compactMap(\.creationDate).first
            request.location = sources.compactMap(\.location).first
            request.isFavorite = sources.contains(where: \.isFavorite)
            request.isHidden = primary.isHidden

            guard let placeholder = request.placeholderForCreatedAsset else { return }
            createdID.value = placeholder.localIdentifier
            for album in uniqueAlbums {
                PHAssetCollectionChangeRequest(for: album)?.addAssets([placeholder] as NSArray)
            }
        }

        guard let id = createdID.value else {
            throw RepairError.message("Photos did not return the new item.")
        }
        return id
    }
}

private final class IdentifierBox: @unchecked Sendable {
    var value: String?
}
