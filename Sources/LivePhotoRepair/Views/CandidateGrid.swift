import SwiftUI

struct CandidateGrid: View {
    @Environment(AppModel.self) private var model

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 12)]

    var body: some View {
        let items = model.visibleCandidates

        VStack(spacing: 0) {
            HStack {
                Text("\(items.count) videos")
                    .foregroundStyle(.secondary)
                Spacer()
                filterMenu
                sortMenu
                Button("Select All") { model.checkAllVisible(true) }
                Button("Select None") { model.checkAllVisible(false) }
            }
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if items.isEmpty && !model.isScanning {
                ContentUnavailableView(
                    "Nothing to Show",
                    systemImage: "checkmark.circle",
                    description: Text("No short videos match the current filter.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(items) { candidate in
                            CandidateCell(candidate: candidate)
                        }
                    }
                    .padding(12)
                }
            }
        }
        // Fill the pane so the header stays pinned to the top even with no results.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

extension CandidateGrid {
    // Menus with explicit labels so the current choice is always visible; a
    // Picker's own label can draw blank until the first selection.
    private var filterMenu: some View {
        Menu {
            Picker("Confidence", selection: Bindable(model).minimumConfidence) {
                ForEach([Confidence.high, .medium, .low], id: \.self) { level in
                    Text(Self.filterTitle(level)).tag(level)
                }
            }
            .pickerStyle(.inline)

            Divider()
            Toggle("Hide Repaired", isOn: Bindable(model).hideCompleted)
            Toggle("Show Ignored (\(model.ignoredIDs.count))", isOn: Bindable(model).showIgnored)
        } label: {
            Text("Show: \(Self.filterTitle(model.minimumConfidence))")
        }
        .fixedSize()
        .help("Filter by confidence, and show or hide repaired and ignored videos")
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort", selection: Bindable(model).sortOrder) {
                ForEach(CandidateSort.allCases) { order in
                    Text(order.title).tag(order)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Text("Sort: \(model.sortOrder.title)")
        }
        .fixedSize()
        .help("Sort by date, file size, or length")
    }

    private static func filterTitle(_ level: Confidence) -> String {
        switch level {
        case .high: "High Confidence"
        case .medium: "Medium and Up"
        case .low: "All Short Videos"
        }
    }
}

private struct CandidateCell: View {
    @Environment(AppModel.self) private var model
    let candidate: Candidate

    private var isFocused: Bool { model.focusedID == candidate.id }
    private var isChecked: Bool { model.checkedIDs.contains(candidate.id) }
    private var isIgnored: Bool { model.isIgnored(candidate.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            AssetThumbnail(asset: candidate.video)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .opacity(isIgnored ? 0.4 : 1)
                .overlay(alignment: .topLeading) { checkbox }
                .overlay(alignment: .topTrailing) { statusBadge }
                .overlay(alignment: .bottomLeading) { actionBadge }
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(isFocused ? Color.accentColor : .clear, lineWidth: 3)
                )

            Text(candidate.filename.isEmpty ? "Untitled" : candidate.filename)
                .font(.caption)
                .lineLimit(1)
            HStack(spacing: 4) {
                Text(String(format: "%.1fs", candidate.duration))
                Text("·")
                if let size = candidate.fileSize {
                    Text(size.formatted(.byteCount(style: .file)))
                    Text("·")
                }
                Text(candidate.confidence.title)
                    .foregroundStyle(candidate.confidence == .high ? .green : (candidate.confidence == .medium ? .orange : .secondary))
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture { model.focusedID = candidate.id }
        .contextMenu {
            Button(isIgnored ? "Stop Ignoring" : "Ignore") {
                model.setIgnored(!isIgnored, for: candidate.id)
            }
            Divider()
            Button("Delete Video", role: .destructive) {
                Task { await model.deleteVideos([candidate.id]) }
            }
            .disabled(candidate.status == .done || model.isRepairing)
        }
    }

    private var checkbox: some View {
        Button {
            if isChecked { model.checkedIDs.remove(candidate.id) } else { model.checkedIDs.insert(candidate.id) }
        } label: {
            Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, isChecked ? Color.accentColor : .black.opacity(0.35))
                .shadow(radius: 2)
        }
        .buttonStyle(.plain)
        .padding(6)
        .disabled(candidate.status == .done || isIgnored)
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch candidate.status {
        case .pending where isIgnored:
            Image(systemName: "eye.slash.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .gray)
                .font(.title3)
                .padding(6)
                .help("Ignored")
        case .pending:
            EmptyView()
        case .working:
            ProgressView().controlSize(.small).padding(6)
        case .done:
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(.white, .green)
                .font(.title3)
                .padding(6)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.white, .red)
                .symbolRenderingMode(.palette)
                .font(.title3)
                .padding(6)
        }
    }

    private var actionBadge: some View {
        Image(systemName: candidate.action.systemImage)
            .font(.caption)
            .padding(5)
            .background(.ultraThinMaterial, in: Circle())
            .padding(6)
            .help(candidate.action.title)
    }
}
