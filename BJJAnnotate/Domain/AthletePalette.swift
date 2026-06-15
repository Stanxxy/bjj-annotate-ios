import Foundation

/// PM-locked 8-color athlete palette. THE ONLY PLACE THESE HEX CODES APPEAR.
///
/// Designer Mockup Pack §2.1: 8 hues chosen for WCAG AA contrast against system
/// background (both modes), pairwise distinguishability under common color-vision
/// deficiencies, and legibility as 2pt strokes over photographic image content.
///
/// `AthletePaletteGrepTests` walks `BJJAnnotate/` and asserts no other Swift file
/// contains any of these hex literals (AC #7). If a designer iteration requires a
/// palette change, edit this file ONLY and the grep gate passes by construction.
enum AthletePalette {
    /// 8 hex codes, slot 1 → slot 8 (athlete-1 → athlete-8).
    static let hexes: [String] = [
        "#3B82F6",   // 1 — blue
        "#F59E0B",   // 2 — amber
        "#10B981",   // 3 — emerald
        "#EF4444",   // 4 — red
        "#8B5CF6",   // 5 — violet
        "#EC4899",   // 6 — pink
        "#14B8A6",   // 7 — teal
        "#F97316",   // 8 — orange-deep
    ]

    /// Returns the palette hex for an `athlete-N` id (1-indexed). Returns nil when
    /// `N` is out of range or the id is not the `athlete-N` form. Referee instances
    /// do NOT consume a palette slot — callers handle the referee case explicitly
    /// (Designer §2.4 — referee strokes are `.secondary` system gray).
    static func hex(forAthleteId id: String) -> String? {
        guard let n = athleteNumber(id), (1...hexes.count).contains(n) else { return nil }
        return hexes[n - 1]
    }

    /// Parses the integer suffix from an `athlete-N` id. Returns nil for non-matching ids.
    static func athleteNumber(_ id: String) -> Int? {
        let prefix = "athlete-"
        guard id.hasPrefix(prefix) else { return nil }
        let suffix = id.dropFirst(prefix.count)
        guard !suffix.isEmpty else { return nil }
        return Int(suffix)
    }
}
