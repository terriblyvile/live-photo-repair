import AppKit
import AVFoundation
import Photos
import SwiftUI

/// Small async wrappers around PHImageManager.
enum AssetLoading {
    static func thumbnail(for asset: PHAsset, side: CGFloat) async -> NSImage? {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let size = CGSize(width: side * scale, height: side * scale)

        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImage(
                for: asset, targetSize: size, contentMode: .aspectFill, options: options
            ) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }

    static func avAsset(for video: PHAsset) async -> AVAsset? {
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.version = .original
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestAVAsset(forVideo: video, options: options) { asset, _, _ in
                continuation.resume(returning: asset)
            }
        }
    }
}

struct AssetThumbnail: View {
    let asset: PHAsset
    var side: CGFloat = 160

    @StateObject private var loader = ThumbnailLoader()

    var body: some View {
        // The rectangle sets the size; the image fills it from an overlay so a
        // portrait or landscape photo can't push the frame wider or taller.
        Rectangle()
            .fill(.quaternary)
            .overlay {
                if let image = loader.image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .clipped()
        .task(id: asset.localIdentifier) {
            loader.image = await AssetLoading.thumbnail(for: asset, side: side)
        }
    }
}

@MainActor
private final class ThumbnailLoader: ObservableObject {
    @Published var image: NSImage?
}
