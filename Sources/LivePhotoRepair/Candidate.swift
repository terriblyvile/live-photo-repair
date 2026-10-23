import Foundation
import Photos

/// How sure we are that a short video used to be a Live Photo.
enum Confidence: Int, Comparable {
    case low, medium, high

    static func < (lhs: Confidence, rhs: Confidence) -> Bool { lhs.rawValue < rhs.rawValue }

    var title: String {
        switch self {
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        }
    }
}

enum RepairAction: String, CaseIterable, Identifiable {
    /// Re-link the video with a separate still that already exists in the library.
    case pairWithStill
    /// Pull a key frame out of the video and build a new Live Photo from the two.
    case rebuildLivePhoto
    /// Replace the video with a single photo taken from its best frame.
    case stillOnly
    /// The still is already a Live Photo, so the video is just a leftover copy.
    case removeDuplicateVideo
    case skip

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pairWithStill: "Pair with original still"
        case .rebuildLivePhoto: "Rebuild Live Photo from video"
        case .stillOnly: "Convert to still photo"
        case .removeDuplicateVideo: "Remove duplicate video"
        case .skip: "Skip"
        }
    }

    var systemImage: String {
        switch self {
        case .pairWithStill: "link"
        case .rebuildLivePhoto: "livephoto"
        case .stillOnly: "photo"
        case .removeDuplicateVideo: "trash"
        case .skip: "forward"
        }
    }

    var explanation: String {
        switch self {
        case .pairWithStill:
            "Best result. Creates a Live Photo from the full-resolution still and this video."
        case .rebuildLivePhoto:
            "Creates a Live Photo using a frame from the video as the key photo. The still is limited to video resolution."
        case .stillOnly:
            "Creates a regular photo from the chosen frame. Motion is not kept."
        case .removeDuplicateVideo:
            "The matching still is already a working Live Photo. Only the leftover video is removed."
        case .skip:
            "Leave this video alone."
        }
    }
}

enum RepairStatus: Equatable {
    case pending
    case working
    case done
    case failed(String)
}

struct Candidate: Identifiable {
    /// Local identifier of the short video.
    let id: String
    let video: PHAsset
    let filename: String
    let duration: TimeInterval
    let pixelSize: CGSize
    let fileSize: Int64?
    let creationDate: Date?
    /// Make and model from the movie's metadata, e.g. "Apple iPhone 13 Pro".
    let recordingDevice: String?
    let confidence: Confidence
    let reasons: [String]
    let warnings: [String]
    let matchedStill: PHAsset?
    let matchedStillFilename: String?
    let stillIsAlreadyLive: Bool

    var action: RepairAction
    /// Seconds into the video for the key photo. nil means pick automatically.
    var keyFrameTime: Double?
    var status: RepairStatus = .pending

    var availableActions: [RepairAction] {
        if matchedStill != nil {
            return stillIsAlreadyLive
                ? [.removeDuplicateVideo, .rebuildLivePhoto, .stillOnly, .skip]
                : [.pairWithStill, .rebuildLivePhoto, .stillOnly, .skip]
        }
        return [.rebuildLivePhoto, .stillOnly, .skip]
    }

    var usesKeyFrame: Bool { action == .rebuildLivePhoto || action == .stillOnly }
}

enum CandidateSort: String, CaseIterable, Identifiable {
    case newest, oldest, largest, smallest, longest, shortest

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newest: "Date: Newest First"
        case .oldest: "Date: Oldest First"
        case .largest: "Size: Largest First"
        case .smallest: "Size: Smallest First"
        case .longest: "Length: Longest First"
        case .shortest: "Length: Shortest First"
        }
    }

    func areInOrder(_ a: Candidate, _ b: Candidate) -> Bool {
        switch self {
        case .newest: (a.creationDate ?? .distantPast) > (b.creationDate ?? .distantPast)
        case .oldest: (a.creationDate ?? .distantFuture) < (b.creationDate ?? .distantFuture)
        case .largest: (a.fileSize ?? 0) > (b.fileSize ?? 0)
        case .smallest: (a.fileSize ?? .max) < (b.fileSize ?? .max)
        case .longest: a.duration > b.duration
        case .shortest: a.duration < b.duration
        }
    }
}
