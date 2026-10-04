import Foundation

/// A Sendable JSON value for the app-server protocol (newline-delimited JSON-RPC over stdio).
public enum JSON: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    public init(any value: Any) {
        switch value {
        case let n as NSNumber where CFGetTypeID(n) == CFBooleanGetTypeID(): self = .bool(n.boolValue)
        case let n as NSNumber: self = .number(n.doubleValue)
        case let s as String: self = .string(s)
        case let a as [Any]: self = .array(a.map(JSON.init(any:)))
        case let o as [String: Any]: self = .object(o.mapValues(JSON.init(any:)))
        default: self = .null
        }
    }

    public var any: Any {
        switch self {
        case .null: NSNull()
        case .bool(let b): b
        case .number(let n): n == n.rounded() && abs(n) < 1e15 ? Int(n) as Any : n as Any
        case .string(let s): s
        case .array(let a): a.map(\.any)
        case .object(let o): o.mapValues(\.any)
        }
    }

    public static func parse(_ line: String) -> JSON? {
        guard let data = line.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        return JSON(any: value)
    }

    public func serialized() -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: any, options: [.withoutEscapingSlashes, .fragmentsAllowed]) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }

    public subscript(key: String) -> JSON? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public var string: String? { if case .string(let s) = self { return s } else { return nil } }
    public var bool: Bool? { if case .bool(let b) = self { return b } else { return nil } }
    public var int: Int? {
        switch self {
        case .number(let n): Int(exactly: n.rounded()) ?? Int(n)
        case .string(let s): Int(s)
        default: nil
        }
    }
}

extension JSON: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
                ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(arrayLiteral elements: JSON...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSON)...) { self = .object(Dictionary(elements, uniquingKeysWith: { $1 })) }
    public init(nilLiteral: ()) { self = .null }
}
