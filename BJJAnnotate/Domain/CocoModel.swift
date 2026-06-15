import Foundation

/// COCO Keypoints 1.0 document with the BJJAnnotate `bjj_annotate_meta` extension.
/// THIS IS THE WORKING FORMAT — there is NO separate internal representation that
/// gets transformed at export time (PM AC #5; Plan §Phase 1 Constraints).
///
/// `AnnotationStore` holds a single `var coco: CocoDocument` property; the on-disk
/// `annotations.json` IS the encoded form of this struct.
struct CocoDocument: Codable, Equatable {
    var info: CocoInfo?
    var images: [CocoImage]
    var categories: [CocoCategory]
    var annotations: [CocoAnnotation]
    /// BJJAnnotate-specific extension. Optional so a foreign COCO file (no extension)
    /// can still decode; production writes always include this block.
    var bjj_annotate_meta: BjjAnnotateMeta?
}

struct CocoInfo: Codable, Equatable {
    var contributor: String?
    var date_created: String?
    var description: String?
    var version: String?
    var year: Int?
}

struct CocoImage: Codable, Equatable {
    var id: Int
    var file_name: String
    var width: Int
    var height: Int
}

struct CocoCategory: Codable, Equatable {
    var id: Int
    var name: String
    var supercategory: String?
    /// Present on athlete categories (1 = gi-athlete, 2 = nogi-athlete); absent on
    /// referee (3). COCO Keypoints 1.0 requires keypoints + skeleton on at least one
    /// category in the file; we put both on the athlete categories.
    var keypoints: [String]?
    var skeleton: [[Int]]?
}

struct CocoAnnotation: Codable, Equatable {
    var id: Int
    var image_id: Int
    var category_id: Int
    /// `[x, y, w, h]` in image pixel coordinates. AC #1 numeric preservation depends
    /// on this being typed as `Double` (allows 120000.0 to survive encode).
    var bbox: [Double]
    var area: Double
    var iscrowd: Int
    var segmentation: [JSONValue]      // COCO allows multiple shapes here; we keep the structure verbatim
    var score: Double?                  // present on athlete instances; absent on referee
    var attributes: CocoAnnotationAttributes
    /// AC #2 — referee instances OMIT `keypoints` and `num_keypoints` entirely.
    /// Encoded as absent JSON keys when nil (NOT as empty arrays).
    var keypoints: [Double]?
    var num_keypoints: Int?
}

struct CocoAnnotationAttributes: Codable, Equatable {
    /// Athlete-id binding (`athlete-N`). Referee instances OMIT this.
    var athlete_id: String?
    /// Origin of the annotation. Phase 1 always sets `"user"` (manual draw).
    /// Phase 3 (model inference) will set `"model"`.
    var source: String
    /// Present only when `source == "model"` (Phase 3+). AC #16d: field is ABSENT
    /// on user-created annotations, not empty-string.
    var model_version: String?
}

/// BJJAnnotate extension to COCO. Schema version 1 in Phase 1.
///
/// Unknown keys at this object's root are captured into `additionalProperties` and
/// re-emitted verbatim — AC #3 (PM Marker A: explicit struct + JSONValue catch-all).
struct BjjAnnotateMeta: Codable, Equatable {
    var schema_version: Int
    var athletes: [Athlete]
    var image_states: [ImageState]
    var settings: MetaSettings
    /// Catch-all for unknown / forward-compatible keys at the root of
    /// `bjj_annotate_meta`. Initialized empty on production writes.
    var additionalProperties: [String: JSONValue]

    private enum KnownKeys: String, CaseIterable {
        case schema_version
        case athletes
        case image_states
        case settings
    }

    /// Generic CodingKey for the catch-all decode/encode path.
    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    init(
        schema_version: Int,
        athletes: [Athlete],
        image_states: [ImageState],
        settings: MetaSettings,
        additionalProperties: [String: JSONValue] = [:]
    ) {
        self.schema_version = schema_version
        self.athletes = athletes
        self.image_states = image_states
        self.settings = settings
        self.additionalProperties = additionalProperties
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyKey.self)
        // Decode known keys via the typed path.
        let sv = try container.decode(Int.self, forKey: AnyKey(stringValue: "schema_version"))
        let athletes = try container.decode([Athlete].self, forKey: AnyKey(stringValue: "athletes"))
        let states = try container.decode([ImageState].self, forKey: AnyKey(stringValue: "image_states"))
        let settings = try container.decode(MetaSettings.self, forKey: AnyKey(stringValue: "settings"))
        // Collect unknown keys into JSONValue catch-all.
        var extras: [String: JSONValue] = [:]
        let known = Set(KnownKeys.allCases.map(\.rawValue))
        for key in container.allKeys where !known.contains(key.stringValue) {
            extras[key.stringValue] = try container.decode(JSONValue.self, forKey: key)
        }
        self.schema_version = sv
        self.athletes = athletes
        self.image_states = states
        self.settings = settings
        self.additionalProperties = extras
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyKey.self)
        try container.encode(schema_version, forKey: AnyKey(stringValue: "schema_version"))
        try container.encode(athletes, forKey: AnyKey(stringValue: "athletes"))
        try container.encode(image_states, forKey: AnyKey(stringValue: "image_states"))
        try container.encode(settings, forKey: AnyKey(stringValue: "settings"))
        // Emit unknown keys flat at the same level. JSONEncoder.sortedKeys orders the
        // final output; we do NOT need to pre-sort here.
        for (k, v) in additionalProperties {
            try container.encode(v, forKey: AnyKey(stringValue: k))
        }
    }
}

struct Athlete: Codable, Equatable, Hashable {
    var id: String
    var display_name: String
    var color_hex: String
}

struct ImageState: Codable, Equatable {
    var image_id: Int
    var visited_at: String   // ISO8601 string
    var flagged: Bool
}

struct MetaSettings: Codable, Equatable {
    var sticky_category_id: Int
}
