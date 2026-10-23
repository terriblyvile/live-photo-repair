import Photos
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if !model.hasAccess {
                AccessView()
            } else if !model.hasScanned && !model.isScanning {
                StartView()
            } else {
                HSplitView {
                    CandidateGrid()
                        .frame(minWidth: 480)
                    DetailPane()
                        .frame(minWidth: 340, idealWidth: 380, maxWidth: 520)
                }
            }
        }
        .safeAreaInset(edge: .bottom) { StatusBar() }
        .toolbar { toolbarContent }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                Task { await model.scan() }
            } label: {
                Label("Scan Library", systemImage: "magnifyingglass")
            }
            .help("Scan your Photos library for Live Photos that became short videos")
            .disabled(!model.hasAccess || model.isScanning || model.isRepairing)

            Button {
                Task { await model.repairChecked() }
            } label: {
                Label("Repair Selected (\(model.checkedRepairable.count))", systemImage: "wand.and.stars")
            }
            .help("Repair the \(model.checkedRepairable.count) checked videos")
            .disabled(model.checkedRepairable.isEmpty || model.isRepairing)

            Button {
                model.ignoreChecked()
            } label: {
                Label("Ignore Checked Videos (\(model.checkedDeletable.count))", systemImage: "eye.slash")
            }
            .help("Ignore the \(model.checkedDeletable.count) checked videos. They are hidden from the grid and stay ignored after a rescan. Turn on Show Ignored in the Show menu to bring them back.")
            .disabled(model.checkedDeletable.isEmpty || model.isRepairing)

            Button(role: .destructive) {
                Task { await model.deletePendingOriginals() }
            } label: {
                Label("Remove Originals (\(model.pendingDeletion.count))", systemImage: "xmark.bin")
            }
            .help("Moves the replaced videos (and paired stills) to Recently Deleted. You can recover them for 30 days.")
            .disabled(model.pendingDeletion.isEmpty || model.isRepairing)

            Button(role: .destructive) {
                Task { await model.deleteCheckedVideos() }
            } label: {
                Label("Delete Checked Videos (\(model.checkedDeletable.count))", systemImage: "trash")
            }
            .help("Delete the \(model.checkedDeletable.count) checked videos without repairing them. They move to Recently Deleted, where you can recover them for 30 days.")
            .disabled(model.checkedDeletable.isEmpty || model.isRepairing)
        }
    }
}

private struct AccessView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ContentUnavailableView {
            Label("Photos Access Needed", systemImage: "photo.on.rectangle.angled")
        } description: {
            if model.authorization == .denied || model.authorization == .restricted {
                Text("Access was denied. Open System Settings > Privacy & Security > Photos and turn on Live Photo Repair.")
            } else {
                Text("Live Photo Repair needs full access to find short videos and save repaired Live Photos.")
            }
        } actions: {
            if model.authorization == .notDetermined {
                Button("Allow Access") { Task { await model.requestAccess() } }
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Open Privacy Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos")!)
                }
            }
        }
    }
}

private struct StartView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ContentUnavailableView {
            Label("Find Broken Live Photos", systemImage: "livephoto.slash")
        } description: {
            Text("Scans for short videos that used to be Live Photos, looks for their original stills, and lets you rebuild them. Nothing changes until you choose Repair, and originals are only removed when you ask.")
        } actions: {
            Button("Scan Library") { Task { await model.scan() } }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
    }
}

private struct StatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            if model.isScanning {
                ProgressView(value: Double(model.scanProgress.done), total: Double(max(model.scanProgress.total, 1)))
                    .frame(width: 160)
            } else if model.isRepairing {
                ProgressView(value: Double(model.repairProgress.done), total: Double(max(model.repairProgress.total, 1)))
                    .frame(width: 160)
            }
            Text(model.statusMessage)
                .lineLimit(1)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}
