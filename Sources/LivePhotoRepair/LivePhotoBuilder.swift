import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Writes the two files Photos needs for a Live Photo.
///
/// Photos links a still and a video when both carry the same content identifier:
/// in the image it lives in the Apple maker note (key "17"), and in the movie it is
/// the `com.apple.quicktime.content.identifier` metadata item. The movie also needs a
/// timed `still-image-time` marker that says which moment the still was taken from.
enum LivePhotoBuilder {
    private static let makerNoteIdentifierKey = "17"
    private static let contentIdentifierKey = "com.apple.quicktime.content.identifier"
    private static let stillImageTimeKey = "com.apple.quicktime.still-image-time"

    // MARK: Still image

    /// Copies an existing photo, adding the content identifier. Returns the written URL,
    /// whose extension matches the format that was actually written.
    static func stampStill(at source: URL, into directory: URL, identifier: String) throws -> URL {
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
              let sourceType = CGImageSourceGetType(imageSource) as String? else {
            throw RepairError.message("Could not read the original still.")
        }

        var properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any] ?? [:]
        var makerNote = properties[kCGImagePropertyMakerAppleDictionary] as? [String: Any] ?? [:]
        makerNote[makerNoteIdentifierKey] = identifier
        properties[kCGImagePropertyMakerAppleDictionary] = makerNote
        properties[kCGImageDestinationLossyCompressionQuality] = 0.95

        // Live Photos are HEIC or JPEG. Anything else (PNG, RAW) is converted to HEIC.
        let keepsFormat = [UTType.heic.identifier, UTType.jpeg.identifier].contains(sourceType)
        let type = keepsFormat ? UTType(sourceType)! : UTType.heic

        return try writeImage(directory: directory, type: type) { destination in
            CGImageDestinationAddImageFromSource(destination, imageSource, 0, properties as CFDictionary)
        }
    }

    /// Encodes a frame grabbed from the video. Pass nil to write a plain photo with no
    /// Live Photo identifier.
    static func writeStill(_ image: CGImage, into directory: URL, identifier: String?) throws -> URL {
        var properties: [CFString: Any] = [
            kCGImagePropertyOrientation: 1,
            kCGImageDestinationLossyCompressionQuality: 0.95,
        ]
        if let identifier {
            properties[kCGImagePropertyMakerAppleDictionary] = [makerNoteIdentifierKey: identifier]
        }
        return try writeImage(directory: directory, type: .heic) { destination in
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        }
    }

    private static func writeImage(directory: URL, type: UTType, add: (CGImageDestination) -> Void) throws -> URL {
        // Fall back to JPEG on Macs that cannot encode HEIC.
        for candidate in [type, .jpeg] {
            let ext = candidate.preferredFilenameExtension ?? "jpg"
            let url = directory.appendingPathComponent("still.\(ext)")
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, candidate.identifier as CFString, 1, nil) else {
                continue
            }
            add(destination)
            if CGImageDestinationFinalize(destination) { return url }
        }
        throw RepairError.message("Could not encode the still image.")
    }

    // MARK: Paired video

    /// Remuxes the video into a QuickTime movie with the Live Photo metadata. Audio and
    /// video samples are copied as-is, so there is no quality loss.
    static func writePairedVideo(from source: URL, to destination: URL, identifier: String, stillTime: Double) async throws {
        try? FileManager.default.removeItem(at: destination)

        let asset = AVURLAsset(url: source)
        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mov)

        let identifierItem = AVMutableMetadataItem()
        identifierItem.keySpace = .quickTimeMetadata
        identifierItem.key = contentIdentifierKey as NSString
        identifierItem.value = identifier as NSString
        identifierItem.dataType = kCMMetadataBaseDataType_UTF8 as String
        writer.metadata = [identifierItem]

        var pairs: [(output: AVAssetReaderTrackOutput, input: AVAssetWriterInput)] = []
        let tracks = try await asset.loadTracks(withMediaType: .video) + asset.loadTracks(withMediaType: .audio)
        guard tracks.contains(where: { $0.mediaType == .video }) else {
            throw RepairError.message("The file has no video track.")
        }

        for track in tracks {
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            let format = try await track.load(.formatDescriptions).first
            let input = AVAssetWriterInput(mediaType: track.mediaType, outputSettings: nil, sourceFormatHint: format)
            input.expectsMediaDataInRealTime = false
            if track.mediaType == .video {
                input.transform = try await track.load(.preferredTransform)
            }
            guard reader.canAdd(output), writer.canAdd(input) else {
                throw RepairError.message("This video's format cannot be copied into a Live Photo.")
            }
            reader.add(output)
            writer.add(input)
            pairs.append((output, input))
        }

        let (metadataInput, metadataAdaptor) = try makeStillTimeInput()
        guard writer.canAdd(metadataInput) else {
            throw RepairError.message("Could not add the Live Photo marker track.")
        }
        writer.add(metadataInput)

        guard reader.startReading() else {
            throw reader.error ?? RepairError.message("Could not read the video.")
        }
        guard writer.startWriting() else {
            throw writer.error ?? RepairError.message("Could not start writing the video.")
        }
        writer.startSession(atSourceTime: .zero)

        let stillItem = AVMutableMetadataItem()
        stillItem.keySpace = .quickTimeMetadata
        stillItem.key = stillImageTimeKey as NSString
        stillItem.value = 0 as NSNumber
        stillItem.dataType = "com.apple.metadata.datatype.int8"
        let stillRange = CMTimeRange(
            start: CMTime(seconds: stillTime, preferredTimescale: 600),
            duration: CMTime(value: 1, timescale: 100)
        )
        metadataAdaptor.append(AVTimedMetadataGroup(items: [stillItem], timeRange: stillRange))
        metadataInput.markAsFinished()

        await copySamples(pairs, reader: reader)

        if reader.status == .failed {
            writer.cancelWriting()
            throw reader.error ?? RepairError.message("Reading the video failed.")
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? RepairError.message("Writing the Live Photo video failed.")
        }
    }

    private static func makeStillTimeInput() throws -> (AVAssetWriterInput, AVAssetWriterInputMetadataAdaptor) {
        let spec: [NSString: Any] = [
            kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier: "mdta/\(stillImageTimeKey)",
            kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType: "com.apple.metadata.datatype.int8",
        ]
        var description: CMFormatDescription?
        let status = CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
            allocator: kCFAllocatorDefault,
            metadataType: kCMMetadataFormatType_Boxed,
            metadataSpecifications: [spec] as CFArray,
            formatDescriptionOut: &description
        )
        guard status == noErr, let description else {
            throw RepairError.message("Could not describe the Live Photo marker track.")
        }
        let input = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: description)
        return (input, AVAssetWriterInputMetadataAdaptor(assetWriterInput: input))
    }

    /// Feeds every track on its own queue so the writer can interleave them freely.
    private static func copySamples(_ pairs: [(output: AVAssetReaderTrackOutput, input: AVAssetWriterInput)], reader: AVAssetReader) async {
        let group = DispatchGroup()
        for (index, pair) in pairs.enumerated() {
            group.enter()
            var finished = false
            let queue = DispatchQueue(label: "livephotorepair.copy.\(index)")
            pair.input.requestMediaDataWhenReady(on: queue) {
                guard !finished else { return }
                while pair.input.isReadyForMoreMediaData {
                    if reader.status == .reading,
                       let sample = pair.output.copyNextSampleBuffer(),
                       pair.input.append(sample) {
                        continue
                    }
                    finished = true
                    pair.input.markAsFinished()
                    group.leave()
                    return
                }
            }
        }
        await withCheckedContinuation { continuation in
            group.notify(queue: .global()) { continuation.resume() }
        }
    }
}

enum RepairError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let text): text
        }
    }
}
