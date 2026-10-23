import Foundation
import Observation
import Photos

@MainActor
@Observable
final class AppModel {
    var authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    var candidates: [Candidate] = []
    var focusedID: String?
    var checkedIDs: Set<String> = []
    var minimumConfidence: Confidence = .medium
    var hideCompleted = false
    var showIgnored = false
    var sortOrder: CandidateSort = .newest

    var isScanning = false
    var hasScanned = false
    var scanProgress = (done: 0, total: 0)
    var isRepairing = false
    var repairProgress = (done: 0, total: 0)
    var statusMessage = ""

    /// Originals replaced by a repair, waiting for the user to move them to Recently Deleted.
    var pendingDeletion: [String] = UserDefaults.standard.stringArray(forKey: Keys.pendingDeletion) ?? [] {
        didSet { UserDefaults.standard.set(pendingDeletion, forKey: Keys.pendingDeletion) }
    }

    /// Videos the user chose to leave alone. Kept across scans and launches.
    private(set) var ignoredIDs: Set<String> = Set(UserDefaults.standard.stringArray(forKey: Keys.ignored) ?? []) {
        didSet { UserDefaults.standard.set(Array(ignoredIDs), forKey: Keys.ignored) }
    }

    /// Videos repaired in this or an earlier session, so a rescan shows them as done.
    private var repairedVideoIDs: Set<String> = Set(UserDefaults.standard.stringArray(forKey: Keys.repaired) ?? []) {
        didSet { UserDefaults.standard.set(Array(repairedVideoIDs), forKey: Keys.repaired) }
    }

    private enum Keys {
        static let pendingDeletion = "pendingDeletion"
        static let repaired = "repairedVideoIDs"
        static let ignored = "ignoredVideoIDs"
    }

    var hasAccess: Bool { authorization == .authorized || authorization == .limited }

    var visibleCandidates: [Candidate] {
        candidates
            .filter { candidate in
                candidate.confidence >= minimumConfidence
                    && !(hideCompleted && candidate.status == .done)
                    && (showIgnored || !ignoredIDs.contains(candidate.id))
            }
            .sorted(by: sortOrder.areInOrder)
    }

    var checkedRepairable: [Candidate] {
        candidates.filter {
            checkedIDs.contains($0.id) && !ignoredIDs.contains($0.id) && $0.status != .done && $0.action != .skip
        }
    }

    func isIgnored(_ id: String) -> Bool { ignoredIDs.contains(id) }

    func setIgnored(_ ignored: Bool, for id: String) {
        if ignored { ignore([id]) } else { ignoredIDs.remove(id) }
    }

    /// Ignoring also unchecks the items; if the focused item is now hidden, focus
    /// moves to the next visible item.
    func ignore(_ ids: [String]) {
        ignoredIDs.formUnion(ids)
        checkedIDs.subtract(ids)
        if let focusedID, ids.contains(focusedID), !showIgnored {
            self.focusedID = visibleCandidates.first?.id
        }
    }

    func ignoreChecked() {
        ignore(checkedDeletable.map(\.id))
        statusMessage = "Ignored videos are hidden. Turn on Show Ignored in the Show menu to see them."
    }

    func index(of id: String) -> Int? {
        candidates.firstIndex { $0.id == id }
    }

    // MARK: Actions

    func requestAccess() async {
        authorization = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    func scan() async {
        guard hasAccess, !isScanning else { return }
        isScanning = true
        scanProgress = (0, 0)
        statusMessage = "Scanning library…"

        let repaired = repairedVideoIDs
        let found = await Task.detached(priority: .userInitiated) {
            await LibraryScanner().scan(repaired: repaired) { done, total in
                Task { @MainActor in self.scanProgress = (done, total) }
            }
        }.value

        candidates = found
        checkedIDs = Set(found.filter { $0.confidence == .high && $0.status != .done && !ignoredIDs.contains($0.id) }.map(\.id))
        focusedID = visibleCandidates.first?.id
        isScanning = false
        hasScanned = true

        let high = found.filter { $0.confidence == .high }.count
        let paired = found.filter { $0.matchedStill != nil }.count
        statusMessage = "Found \(found.count) short videos: \(high) high confidence, \(paired) with a matching still."
    }

    func checkAllVisible(_ checked: Bool) {
        let ids = visibleCandidates.filter { $0.status != .done && !ignoredIDs.contains($0.id) }.map(\.id)
        if checked { checkedIDs.formUnion(ids) } else { checkedIDs.subtract(ids) }
    }

    func repairChecked() async {
        await repair(checkedRepairable.map(\.id))
    }

    func repair(_ ids: [String]) async {
        guard !isRepairing, !ids.isEmpty else { return }
        isRepairing = true
        repairProgress = (0, ids.count)
        var failures = 0

        for id in ids {
            guard let index = index(of: id) else { continue }
            candidates[index].status = .working
            statusMessage = "Repairing \(candidates[index].filename)…"

            do {
                let result = try await RepairService.repair(candidates[index])
                if let index = self.index(of: id) {
                    candidates[index].status = .done
                }
                repairedVideoIDs.insert(id)
                pendingDeletion.append(contentsOf: result.replacedAssetIDs.filter { !pendingDeletion.contains($0) })
                checkedIDs.remove(id)
            } catch {
                failures += 1
                if let index = self.index(of: id) {
                    candidates[index].status = .failed(error.localizedDescription)
                }
            }
            repairProgress.done += 1
        }

        isRepairing = false
        let succeeded = ids.count - failures
        statusMessage = "Repaired \(succeeded) of \(ids.count)."
            + (failures > 0 ? " \(failures) failed; select one to see why." : "")
            + (pendingDeletion.isEmpty ? "" : " Check the new items in Photos, then remove the originals.")
    }

    /// Checked videos that can be deleted outright. Repaired items are excluded
    /// because their originals go through Remove Originals instead.
    var checkedDeletable: [Candidate] {
        candidates.filter { checkedIDs.contains($0.id) && !ignoredIDs.contains($0.id) && $0.status != .done }
    }

    func deleteCheckedVideos() async {
        await deleteVideos(checkedDeletable.map(\.id))
    }

    /// Moves videos to Recently Deleted without repairing them, for clips that were
    /// never Live Photos. macOS asks the user to confirm first.
    func deleteVideos(_ ids: [String]) async {
        guard !ids.isEmpty, !isRepairing else { return }
        do {
            try await RepairService.delete(assetIDs: ids)
            let removed = Set(ids)
            statusMessage = "Moved \(removed.count) videos to Recently Deleted."
            if let focusedID, removed.contains(focusedID) { self.focusedID = nil }
            candidates.removeAll { removed.contains($0.id) }
            checkedIDs.subtract(removed)
            if focusedID == nil { focusedID = visibleCandidates.first?.id }
        } catch {
            // Cancelling the system confirmation lands here too.
            statusMessage = "Videos were not deleted: \(error.localizedDescription)"
        }
    }

    func deletePendingOriginals() async {
        guard !pendingDeletion.isEmpty else { return }
        do {
            try await RepairService.delete(assetIDs: pendingDeletion)
            let removed = Set(pendingDeletion)
            statusMessage = "Moved \(removed.count) originals to Recently Deleted."
            pendingDeletion = []
            if let focusedID, removed.contains(focusedID) { self.focusedID = nil }
            candidates.removeAll { removed.contains($0.id) }
            checkedIDs.subtract(removed)
            if focusedID == nil { focusedID = visibleCandidates.first?.id }
        } catch {
            // Cancelling the system confirmation lands here too.
            statusMessage = "Originals were not removed: \(error.localizedDescription)"
        }
    }
}
