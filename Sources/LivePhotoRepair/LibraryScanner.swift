import AVFoundation
import Foundation
import Photos

/// Finds short videos that look like flattened Live Photos and tries to match each
/// one with a still taken at the same moment.
struct LibraryScanner {
    static let durationRange = 0.8...4.5
    static let liveLikeDuration = 1.2...3.6
    /// How far apart (seconds) a still and video can be and still count as one capture.
    static let pairingWindow: TimeInterval = 2.0
    /// Live Photo movies have been at least 1080 pixels on the short side since the
    /// iPhone 6s. Downloaded clips and memes are usually smaller.
    static let minimumCameraShortSide = 1080
    /// iPhone camera names: IMG_1234.MOV, IMG_E1234.MOV and so on. Saved or downloaded
    /// files tend to use lowercase extensions or random names.
    private static let cameraFilename = try! NSRegularExpression(pattern: #"^IMG_E?\d{4}( ?\(\d+\))?\.(MOV|MP4|HEIC|JPG)$"#)

    /// `repaired` holds video identifiers that were already fixed in an earlier session.
    func scan(repaired: Set<String>, progress: @escaping (Int, Int) -> Void) async -> [Candidate] {
        let options = PHFetchOptions()
        options.includeHiddenAssets = true
        options.predicate = NSPredicate(
            format: "mediaType == %d AND duration >= %f AND duration <= %f",
            PHAssetMediaType.video.rawValue,
            Self.durationRange.lowerBound,
            Self.durationRange.upperBound
        )
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]

        let fetched = PHAsset.fetchAssets(with: options)
        var videos: [PHAsset] = []
        fetched.enumerateObjects { asset, _, _ in videos.append(asset) }

        var candidates: [Candidate] = []
        candidates.reserveCapacity(videos.count)
        for (index, video) in videos.enumerated() {
            candidates.append(await makeCandidate(for: video, repaired: repaired))
            if index % 20 == 0 || index == videos.count - 1 {
                progress(index + 1, videos.count)
            }
        }
        return candidates
    }

    private func makeCandidate(for video: PHAsset, repaired: Set<String>) async -> Candidate {
        let resource = Self.resource(of: video, preferring: [.video, .fullSizeVideo])
        let filename = resource?.originalFilename ?? ""
        let size = CGSize(width: video.pixelWidth, height: video.pixelHeight)
        let device = await Self.recordingDevice(of: video)
        let still = findMatchingStill(for: video, videoFilename: filename)

        // Evidence the clip came out of a camera. It raises confidence; a missing
        // signal only adds an informational warning.
        var cameraEvidence: [String] = []
        if let device { cameraEvidence.append("Recorded on \(device)") }
        if Self.isCameraFilename(filename) { cameraEvidence.append("Camera-style filename") }
        if video.location != nil { cameraEvidence.append("Has a GPS location") }

        let shortSide = min(video.pixelWidth, video.pixelHeight)
        // Older iPhones record Live Photo movies at 4:3, newer ones at 16:9. The shape
        // only counts at camera resolution, so small vertical meme clips don't score.
        let isCameraShaped = (Self.isFourByThree(size) || Self.isSixteenByNine(size))
            && shortSide >= Self.minimumCameraShortSide

        var points = 0
        var reasons = cameraEvidence
        points += min(cameraEvidence.count, 2)

        if Self.liveLikeDuration.contains(video.duration) {
            points += 1
            reasons.append(String(format: "%.1f s long, typical of a Live Photo", video.duration))
        }
        if isCameraShaped {
            points += 1
            reasons.append("\(video.pixelWidth) × \(video.pixelHeight) frame like the iPhone camera")
        }
        if let still {
            points += 2
            reasons.append(still.asset.mediaSubtypes.contains(.photoLive)
                ? "Matching still is already a Live Photo"
                : "Matching still found: \(still.filename)")
        }

        var warnings: [String] = []
        if cameraEvidence.isEmpty { warnings.append("No camera metadata, camera filename, or location") }
        if !Self.isFourByThree(size) && !Self.isSixteenByNine(size) {
            warnings.append("Frame is not 4:3 or 16:9 (\(video.pixelWidth) × \(video.pixelHeight))")
        }
        if shortSide < Self.minimumCameraShortSide { warnings.append("Lower resolution than an iPhone Live Photo") }

        let confidence: Confidence = points >= 4 ? .high : (points >= 2 ? .medium : .low)

        let stillIsLive = still?.asset.mediaSubtypes.contains(.photoLive) ?? false
        let action: RepairAction
        if still == nil {
            action = .rebuildLivePhoto
        } else {
            action = stillIsLive ? .removeDuplicateVideo : .pairWithStill
        }

        return Candidate(
            id: video.localIdentifier,
            video: video,
            filename: filename,
            duration: video.duration,
            pixelSize: size,
            fileSize: resource.flatMap(Self.fileSize(of:)),
            creationDate: video.creationDate,
            recordingDevice: device,
            confidence: confidence,
            reasons: reasons,
            warnings: warnings,
            matchedStill: still?.asset,
            matchedStillFilename: still?.filename,
            stillIsAlreadyLive: stillIsLive,
            action: action,
            status: repaired.contains(video.localIdentifier) ? .done : .pending
        )
    }

    private func findMatchingStill(for video: PHAsset, videoFilename: String) -> (asset: PHAsset, filename: String)? {
        guard let date = video.creationDate else { return nil }

        let options = PHFetchOptions()
        options.includeHiddenAssets = true
        options.predicate = NSPredicate(
            format: "mediaType == %d AND creationDate >= %@ AND creationDate <= %@",
            PHAssetMediaType.image.rawValue,
            date.addingTimeInterval(-Self.pairingWindow) as NSDate,
            date.addingTimeInterval(Self.pairingWindow) as NSDate
        )
        let images = PHAsset.fetchAssets(with: options)
        guard images.count > 0 else { return nil }

        let videoStem = Self.stem(videoFilename)
        let videoIsPortrait = video.pixelHeight > video.pixelWidth
        var best: (asset: PHAsset, filename: String, score: Double)?

        images.enumerateObjects { image, _, _ in
            // A Live Photo's still is 4:3 even when its video is 16:9. Screenshots and saved
            // images that happen to share a timestamp are not.
            guard Self.isFourByThree(CGSize(width: image.pixelWidth, height: image.pixelHeight)) else { return }

            let name = Self.resource(of: image, preferring: [.photo, .fullSizePhoto])?.originalFilename ?? ""
            let gap = abs((image.creationDate ?? date).timeIntervalSince(date))
            // Same filename stem is the strongest signal; otherwise closest in time wins.
            var score = gap
            if !videoStem.isEmpty && Self.stem(name) == videoStem { score -= 100 }
            if (image.pixelHeight > image.pixelWidth) != videoIsPortrait { score += 10 }
            if best == nil || score < best!.score {
                best = (image, name, score)
            }
        }

        // Reject matches that only line up in time but have the wrong orientation.
        guard let best, best.score < 10 else { return nil }
        return (best.asset, best.filename)
    }

    // MARK: Helpers

    /// Reads the make and model the camera writes into the movie, such as
    /// "Apple iPhone 13 Pro". Only checks files already on this Mac, so a scan never
    /// downloads the whole library from iCloud.
    private static func recordingDevice(of video: PHAsset) async -> String? {
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = false
        options.version = .original

        let asset: AVAsset? = await withCheckedContinuation { continuation in
            PHImageManager.default().requestAVAsset(forVideo: video, options: options) { asset, _, _ in
                continuation.resume(returning: asset)
            }
        }
        guard let asset, let items = try? await asset.load(.commonMetadata) else { return nil }

        func value(_ key: AVMetadataKey) async -> String? {
            guard let item = AVMetadataItem.metadataItems(from: items, withKey: key, keySpace: .common).first else { return nil }
            return try? await item.load(.stringValue)
        }
        let make = await value(.commonKeyMake)
        let model = await value(.commonKeyModel)
        guard make != nil || model != nil else { return nil }
        return [make, model].compactMap { $0 }.joined(separator: " ")
    }

    static func resource(of asset: PHAsset, preferring types: [PHAssetResourceType]) -> PHAssetResource? {
        let resources = PHAssetResource.assetResources(for: asset)
        for type in types {
            if let match = resources.first(where: { $0.type == type }) { return match }
        }
        return resources.first
    }

    /// PhotoKit has no public file size API; "fileSize" is the long-standing KVC key.
    static func fileSize(of resource: PHAssetResource) -> Int64? {
        (resource.value(forKey: "fileSize") as? NSNumber)?.int64Value
    }

    static func isCameraFilename(_ filename: String) -> Bool {
        let range = NSRange(filename.startIndex..., in: filename)
        return cameraFilename.firstMatch(in: filename, range: range) != nil
    }

    static func stem(_ filename: String) -> String {
        (filename as NSString).deletingPathExtension.uppercased()
    }

    static func isFourByThree(_ size: CGSize) -> Bool {
        hasAspectRatio(size, 4.0 / 3.0)
    }

    static func isSixteenByNine(_ size: CGSize) -> Bool {
        hasAspectRatio(size, 16.0 / 9.0)
    }

    private static func hasAspectRatio(_ size: CGSize, _ ratio: Double) -> Bool {
        let long = max(size.width, size.height)
        let short = min(size.width, size.height)
        guard short > 0 else { return false }
        return abs(long / short - ratio) < 0.03
    }
}
