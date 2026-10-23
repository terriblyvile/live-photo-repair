import AVKit
import SwiftUI

struct DetailPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let id = model.focusedID, let index = model.index(of: id) {
            CandidateDetail(id: id, snapshot: model.candidates[index])
                .id(id)
        } else {
            ContentUnavailableView("Select a Video", systemImage: "film", description: Text("Click a thumbnail to preview it and choose how to repair it."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct CandidateDetail: View {
    @Environment(AppModel.self) private var model
    let id: String
    /// Used for the one redraw after the item leaves the list (for example when its
    /// original is deleted), so the view never indexes past the end of the array.
    let snapshot: Candidate

    @StateObject private var state = DetailState()

    private var candidate: Candidate {
        model.index(of: id).map { model.candidates[$0] } ?? snapshot
    }

    private var isIgnored: Bool { model.isIgnored(id) }

    private func update(_ change: (inout Candidate) -> Void) {
        guard let index = model.index(of: id) else { return }
        change(&model.candidates[index])
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                videoSection
                if let still = candidate.matchedStill {
                    GroupBox("Matching still") {
                        HStack(alignment: .top, spacing: 12) {
                            AssetThumbnail(asset: still, side: 96)
                                .frame(width: 96, height: 96)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(candidate.matchedStillFilename ?? "")
                                Text("\(still.pixelWidth) × \(still.pixelHeight)")
                                    .foregroundStyle(.secondary)
                                if candidate.stillIsAlreadyLive {
                                    Label("Already a Live Photo", systemImage: "livephoto")
                                        .foregroundStyle(.green)
                                }
                            }
                            .font(.callout)
                            Spacer()
                        }
                        .padding(4)
                    }
                }
                actionSection
                if candidate.usesKeyFrame { keyFrameSection }
                infoSection
            }
            .padding(16)
        }
        .task { await loadVideo() }
        .onDisappear { state.player?.pause() }
    }

    // MARK: Sections

    private var videoSection: some View {
        ZStack {
            Rectangle().fill(.black)
            if let player = state.player {
                PlayerView(player: player)
            } else {
                ProgressView()
            }
        }
        .aspectRatio(candidate.pixelSize.width > 0 ? candidate.pixelSize.width / candidate.pixelSize.height : 0.75, contentMode: .fit)
        .frame(maxHeight: 360)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var actionSection: some View {
        GroupBox("Repair") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Action", selection: actionBinding) {
                    ForEach(candidate.availableActions) { action in
                        Label(action.title, systemImage: action.systemImage).tag(action)
                    }
                }
                .labelsHidden()

                Text(candidate.action.explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                switch candidate.status {
                case .done:
                    Label("Repaired. Check it in Photos, then use Remove Originals.", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                case .working:
                    ProgressView("Repairing…").controlSize(.small)
                case .pending:
                    EmptyView()
                }

                HStack {
                    Button {
                        Task { await model.repair([candidate.id]) }
                    } label: {
                        Label("Repair This Item", systemImage: "wand.and.stars")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(candidate.status == .done || candidate.action == .skip || isIgnored || model.isRepairing)

                    Button {
                        model.setIgnored(!isIgnored, for: candidate.id)
                    } label: {
                        Label(isIgnored ? "Stop Ignoring" : "Ignore", systemImage: isIgnored ? "eye" : "eye.slash")
                    }
                    .help("Ignored items are hidden from the grid, skipped by Select All, and stay ignored after a rescan.")
                    .disabled(candidate.status == .done)
                }
            }
            .padding(4)
        }
    }

    private var keyFrameSection: some View {
        GroupBox("Key photo") {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    Rectangle().fill(.quaternary)
                    if let keyFrame = state.keyFrame {
                        Image(decorative: keyFrame, scale: 1)
                            .resizable()
                            .scaledToFit()
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .frame(height: 180)
                .clipShape(RoundedRectangle(cornerRadius: 4))

                Slider(value: $state.sliderTime, in: 0...max(candidate.duration, 0.1)) { editing in
                    if !editing { update { $0.keyFrameTime = state.sliderTime } }
                }
                HStack {
                    Text(candidate.keyFrameTime == nil ? "Auto: best frame" : String(format: "Manual: %.2f s", state.sliderTime))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Use Best Frame") {
                        update { $0.keyFrameTime = nil }
                        if let auto = state.autoFrameTime { state.sliderTime = auto }
                    }
                    .controlSize(.small)
                    .disabled(candidate.keyFrameTime == nil || state.isFindingBest)
                }
            }
            .padding(4)
        }
        .task(id: state.sliderTime) { await refreshKeyFrame() }
    }

    private var infoSection: some View {
        GroupBox("Details") {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("File", value: candidate.filename)
                LabeledContent("Size", value: "\(Int(candidate.pixelSize.width)) × \(Int(candidate.pixelSize.height))")
                LabeledContent("Length", value: String(format: "%.2f s", candidate.duration))
                if let size = candidate.fileSize {
                    LabeledContent("File size", value: size.formatted(.byteCount(style: .file)))
                }
                LabeledContent("Recorded on", value: candidate.recordingDevice ?? "Unknown")
                if let date = candidate.creationDate {
                    LabeledContent("Taken", value: date.formatted(date: .abbreviated, time: .standard))
                }
                LabeledContent("Confidence", value: candidate.confidence.title)
                ForEach(candidate.reasons, id: \.self) { reason in
                    Label(reason, systemImage: "checkmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(candidate.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .font(.callout)
            .padding(4)
        }
    }

    // MARK: Loading

    private var actionBinding: Binding<RepairAction> {
        Binding(
            get: { candidate.action },
            set: { action in update { $0.action = action } }
        )
    }

    private func loadVideo() async {
        guard let asset = await AssetLoading.avAsset(for: candidate.video) else { return }
        state.videoAsset = asset
        let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        player.isMuted = true
        state.player = player
        player.play()

        if let chosen = candidate.keyFrameTime {
            state.sliderTime = chosen
        } else {
            state.isFindingBest = true
            if let best = try? await FrameExtractor.bestFrame(of: asset) {
                state.autoFrameTime = best.seconds
                state.keyFrame = best.image
                state.sliderTime = best.seconds
            }
            state.isFindingBest = false
        }
    }

    private func refreshKeyFrame() async {
        guard let videoAsset = state.videoAsset else { return }
        try? await Task.sleep(for: .milliseconds(120))  // Debounce while dragging.
        guard !Task.isCancelled else { return }
        if let image = try? await FrameExtractor.frame(of: videoAsset, at: state.sliderTime) {
            state.keyFrame = image
        }
    }
}

/// Per-item view state. An ObservableObject because the @State macro's plugin is not
/// part of the Command Line Tools.
@MainActor
private final class DetailState: ObservableObject {
    @Published var player: AVPlayer?
    @Published var videoAsset: AVAsset?
    @Published var keyFrame: CGImage?
    @Published var autoFrameTime: Double?
    @Published var sliderTime: Double = 0
    @Published var isFindingBest = false
}

/// AppKit's AVPlayerView. SwiftUI's VideoPlayer crashes when shown with this
/// toolchain (its _AVKit_SwiftUI metadata fails to initialize).
private struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}
