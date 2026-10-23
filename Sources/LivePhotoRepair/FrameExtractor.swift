import AVFoundation
import CoreGraphics
import Vision

/// Pulls individual frames out of a video and picks the one that makes the best still.
enum FrameExtractor {
    static func frame(of asset: AVAsset, at seconds: Double) async throws -> CGImage {
        let generator = makeGenerator(for: asset)
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        return try await generator.image(at: time).image
    }

    /// Samples frames across the clip and scores each with Vision's aesthetics model.
    /// Frames near the middle get a small bonus, since that is where the original key
    /// photo sat and the ends often show the phone being raised or lowered.
    static func bestFrame(of asset: AVAsset, samples: Int = 12) async throws -> (image: CGImage, seconds: Double) {
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else {
            throw RepairError.message("The video has no readable duration.")
        }

        let generator = makeGenerator(for: asset)
        var best: (image: CGImage, seconds: Double, score: Double)?

        for index in 0..<samples {
            let position = (Double(index) + 0.5) / Double(samples)
            let requested = CMTime(seconds: duration * position, preferredTimescale: 600)
            guard let result = try? await generator.image(at: requested) else { continue }

            let score = aestheticsScore(result.image) - 0.3 * abs(position - 0.5)
            if best == nil || score > best!.score {
                best = (result.image, result.actualTime.seconds, score)
            }
        }

        guard let best else { throw RepairError.message("Could not read any frames from the video.") }
        return (best.image, best.seconds)
    }

    private static func makeGenerator(for asset: AVAsset) -> AVAssetImageGenerator {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return generator
    }

    /// Returns roughly -1...1. Blurry or badly exposed frames score low.
    private static func aestheticsScore(_ image: CGImage) -> Double {
        let request = VNCalculateImageAestheticsScoresRequest()
        let handler = VNImageRequestHandler(cgImage: image)
        guard (try? handler.perform([request])) != nil,
              let observation = request.results?.first else { return 0 }
        return Double(observation.overallScore)
    }
}
