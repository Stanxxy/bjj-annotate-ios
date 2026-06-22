import XCTest
@testable import BJJAnnotate

/// `JSONValue` is the recursive `Codable` value type used to carry the
/// `bjj_annotate_meta.additionalProperties` catch-all (AIP §2, Marker A).
/// These tests assert each variant decodes-and-encodes back to its source bytes.
final class JSONValueTests: XCTestCase {

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    private let decoder = JSONDecoder()

    // MARK: - Single-variant round-trips

    func test_string_roundtrip() throws {
        let raw = #""hello""#.data(using: .utf8)!
        let decoded = try decoder.decode(JSONValue.self, from: raw)
        XCTAssertEqual(decoded, .string("hello"))
        XCTAssertEqual(try encoder.encode(decoded), raw)
    }

    func test_bool_true_roundtrip() throws {
        let raw = "true".data(using: .utf8)!
        let decoded = try decoder.decode(JSONValue.self, from: raw)
        XCTAssertEqual(decoded, .bool(true))
        XCTAssertEqual(try encoder.encode(decoded), raw)
    }

    func test_bool_false_roundtrip() throws {
        let raw = "false".data(using: .utf8)!
        let decoded = try decoder.decode(JSONValue.self, from: raw)
        XCTAssertEqual(decoded, .bool(false))
        XCTAssertEqual(try encoder.encode(decoded), raw)
    }

    func test_number_integer_value_roundtrip() throws {
        let raw = "42".data(using: .utf8)!
        let decoded = try decoder.decode(JSONValue.self, from: raw)
        XCTAssertEqual(decoded, .number(42))
        // JSONEncoder emits Double(42) as "42" — the integer-valued canonical form.
        XCTAssertEqual(try encoder.encode(decoded), raw)
    }

    func test_number_fractional_value_roundtrip() throws {
        let raw = "42.5".data(using: .utf8)!
        let decoded = try decoder.decode(JSONValue.self, from: raw)
        XCTAssertEqual(decoded, .number(42.5))
        XCTAssertEqual(try encoder.encode(decoded), raw)
    }

    func test_null_roundtrip() throws {
        let raw = "null".data(using: .utf8)!
        let decoded = try decoder.decode(JSONValue.self, from: raw)
        XCTAssertEqual(decoded, .null)
        XCTAssertEqual(try encoder.encode(decoded), raw)
    }

    func test_array_roundtrip() throws {
        let raw = #"["a",true,null]"#.data(using: .utf8)!
        let decoded = try decoder.decode(JSONValue.self, from: raw)
        XCTAssertEqual(decoded, .array([.string("a"), .bool(true), .null]))
        XCTAssertEqual(try encoder.encode(decoded), raw)
    }

    func test_object_roundtrip_with_sorted_keys() throws {
        let raw = #"{"a":1,"b":"two","c":[true,null]}"#.data(using: .utf8)!
        let decoded = try decoder.decode(JSONValue.self, from: raw)
        let expectedEncoded = #"{"a":1,"b":"two","c":[true,null]}"#.data(using: .utf8)!
        XCTAssertEqual(try encoder.encode(decoded), expectedEncoded)
        // Sanity: decoded object preserves all keys.
        if case let .object(dict) = decoded {
            XCTAssertEqual(Set(dict.keys), ["a", "b", "c"])
        } else {
            XCTFail("Expected .object")
        }
    }

    // MARK: - Deeply nested

    func test_deeply_nested_object_roundtrip() throws {
        let raw = #"{"meta":{"flags":{"x":true,"y":[1,2,3]}}}"#.data(using: .utf8)!
        let decoded = try decoder.decode(JSONValue.self, from: raw)
        let encoded = try encoder.encode(decoded)
        XCTAssertEqual(encoded, raw)
    }
}
