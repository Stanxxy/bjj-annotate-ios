import Foundation

/// Recursive `Codable` value carrying any JSON shape. Used by `BjjAnnotateMeta` to
/// preserve unknown/forward-compatible keys verbatim through a decode → mutate → encode
/// round-trip (PM Acceptance Pack §AC #3, AIP §2, Marker A).
///
/// The `indirect` keyword enables `.array` / `.object` to wrap arbitrary nesting.
/// `Hashable` is intentional so the type composes into `Equatable` aggregates without
/// the synthesizer asking for a witness on `[String: JSONValue]`.
indirect enum JSONValue: Codable, Equatable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
            return
        }
        // IMPORTANT: try Bool BEFORE Double. `JSONDecoder` will happily decode `true`
        // as Double(1.0), and `false` as Double(0.0), erasing the JSON's actual type.
        if let b = try? container.decode(Bool.self) {
            self = .bool(b)
            return
        }
        if let d = try? container.decode(Double.self) {
            self = .number(d)
            return
        }
        if let s = try? container.decode(String.self) {
            self = .string(s)
            return
        }
        if let a = try? container.decode([JSONValue].self) {
            self = .array(a)
            return
        }
        if let o = try? container.decode([String: JSONValue].self) {
            self = .object(o)
            return
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Value is not a valid JSONValue"
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let b):
            try container.encode(b)
        case .number(let d):
            try container.encode(d)
        case .string(let s):
            try container.encode(s)
        case .array(let a):
            try container.encode(a)
        case .object(let o):
            try container.encode(o)
        }
    }
}
