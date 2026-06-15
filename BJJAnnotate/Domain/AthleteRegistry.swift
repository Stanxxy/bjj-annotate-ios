import Foundation

/// Stateless allocator for `athlete-N` ids. PM Marker B: ids are NEVER reused;
/// allocation is `max(existing_ids) + 1`, capped at 8 (Designer §3.1 +
/// PM addendum #10 "Project full — 8 athletes max.").
///
/// The registry has no instance state — callers pass the live athletes list at
/// each allocation. This is intentional: it makes the allocator trivially testable,
/// race-free (no shared mutable state), and the "ids never reused" invariant flows
/// directly from `max + 1` arithmetic.
enum AthleteRegistry {

    /// Hard cap. AC #11 / PM addendum #10. Beyond this, `allocate` returns nil and
    /// the UI renders the "Project full" row in the athlete picker.
    static let cap = 8

    /// Returns the next athlete, or nil if the project is full.
    ///
    /// - Color is taken from `AthletePalette.hexes[next - 1]` so allocation order
    ///   matches palette order (athlete-1 = blue, athlete-2 = amber, ...).
    /// - `display_name` defaults to the id itself. Phase 4 may introduce editing
    ///   under Settings (see PM Resolution #1).
    static func allocate(in athletes: [Athlete]) -> Athlete? {
        let usedNumbers = athletes.compactMap { AthletePalette.athleteNumber($0.id) }
        let next = (usedNumbers.max() ?? 0) + 1
        guard next <= cap else { return nil }
        // Palette is indexed 1...8; we just gated `next <= cap` so this is safe.
        let hex = AthletePalette.hexes[next - 1]
        let id = "athlete-\(next)"
        return Athlete(id: id, display_name: id, color_hex: hex)
    }
}
