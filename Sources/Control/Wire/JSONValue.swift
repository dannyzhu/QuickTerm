import Foundation

/// 任意 JSON 值（客户端解码响应 / 请求 args 的载体）。
/// 存在的理由：所有编解码仍然走 `JSONEncoder`/`JSONDecoder`——绝不手拼字符串
/// （yabai 曾因手拼出的尾逗号打断所有下游 jq 管道）。
enum JSONValue: Codable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        if let v = try? c.decode(Int.self) { self = .int(v); return }
        if let v = try? c.decode(Double.self) { self = .double(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        if let v = try? c.decode([JSONValue].self) { self = .array(v); return }
        if let v = try? c.decode([String: JSONValue].self) { self = .object(v); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "unsupported JSON value")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    var stringValue: String? {
        switch self {
        case .string(let v): v
        case .int(let v): String(v)
        case .double(let v): String(v)
        case .bool(let v): v ? "true" : "false"
        default: nil
        }
    }

    var intValue: Int? {
        switch self {
        case .int(let v): v
        case .double(let v): Int(v)
        case .string(let v): Int(v)
        default: nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .double(let v): v
        case .int(let v): Double(v)
        case .string(let v): Double(v)
        default: nil
        }
    }

    var boolValue: Bool? {
        switch self {
        case .bool(let v): v
        case .int(let v): v != 0
        case .string(let v): ["true", "yes", "on", "1"].contains(v.lowercased())
        default: nil
        }
    }

    var arrayValue: [JSONValue]? {
        if case .array(let v) = self { return v }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let v) = self { return v }
        return nil
    }

    subscript(key: String) -> JSONValue? { objectValue?[key] }
}
