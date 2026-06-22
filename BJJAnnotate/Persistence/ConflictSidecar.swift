import Foundation

/// Conflict sidecar emission helper (AIP §6). Phase 1 ships a STATIC emit path
/// that other code calls when `NSFileVersion.unresolvedConflictVersions(of:)` returns
/// a non-empty list (T10 / AC #34 / AC #36).
///
/// The sidecar filename pattern: `annotations.conflict-<ISO8601>.json`
/// (e.g. `annotations.conflict-2027-01-15T08:00:00Z.json`).
///
/// AC #36: the loser is preserved VERBATIM. NO merge with the winner — the
/// athletes dictionaries stay separate, allowing the user to inspect the loser
/// in Files.app at any time.
enum ConflictSidecar {

    /// Emits a sidecar containing `losersBytes` in the same directory as the winner.
    /// Returns a `ConflictEvent` for the UI to banner (locked copy in LockedCopy.swift).
    ///
    /// Atomic: writes via temp + rename, like every other coordinator write. Throws
    /// if the directory is not writable.
    static func emit(
        directory: URL,
        losersBytes: Data,
        loserModificationDate: Date,
        winnerURL: URL,
        differingAnnotationIds: [Int]
    ) throws -> ConflictEvent {
        let timestamp = Self.iso8601String(from: loserModificationDate)
        let sidecarName = "annotations.conflict-\(timestamp).json"
        let sidecarURL = directory.appendingPathComponent(sidecarName)
        let tempURL = directory.appendingPathComponent(".\(sidecarName).tmp.\(UUID().uuidString)")
        do {
            try losersBytes.write(to: tempURL, options: .atomic)
            try FileManager.default.moveItem(at: tempURL, to: sidecarURL)
        } catch {
            // Best-effort cleanup if temp is left behind.
            do {
                try FileManager.default.removeItem(at: tempURL)
            } catch {
                // intentional: cleanup failure is non-fatal
            }
            throw error
        }
        return ConflictEvent(
            sidecarURL: sidecarURL,
            winnerURL: winnerURL,
            differingAnnotationIds: differingAnnotationIds
        )
    }

    /// Compute the set of annotation ids that differ between two CocoDocuments.
    /// Used by `CocoFileCoordinator` to populate `ConflictEvent.differingAnnotationIds`
    /// before banner + diff modal.
    static func differingAnnotationIds(winner: CocoDocument, loser: CocoDocument) -> [Int] {
        let winnerById = Dictionary(uniqueKeysWithValues: winner.annotations.map { ($0.id, $0) })
        let loserById = Dictionary(uniqueKeysWithValues: loser.annotations.map { ($0.id, $0) })
        var ids: [Int] = []
        for (id, w) in winnerById {
            if let l = loserById[id] {
                if w != l { ids.append(id) }
            } else {
                ids.append(id)  // only in winner
            }
        }
        for (id, _) in loserById where winnerById[id] == nil {
            ids.append(id)      // only in loser
        }
        return ids.sorted()
    }

    private static func iso8601String(from date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }
}
