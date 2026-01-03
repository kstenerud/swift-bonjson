// ABOUTME: Public BONJSONDecoder API matching Apple's JSONDecoder interface.
// ABOUTME: Provides Codable support for decoding BONJSON binary format to Swift types.

import Foundation

/// An object that decodes instances of a data type from BONJSON data.
///
/// Use `BONJSONDecoder` in the same way you would use `JSONDecoder`:
///
///     struct Person: Codable {
///         var name: String
///         var age: Int
///     }
///
///     let decoder = BONJSONDecoder()
///     let person = try decoder.decode(Person.self, from: bonjsonData)
///
public final class BONJSONDecoder {

    /// The strategy to use for decoding `Date` values.
    public enum DateDecodingStrategy {
        /// Decode the date as a Unix timestamp (seconds since epoch).
        case secondsSince1970

        /// Decode the date as a Unix timestamp (milliseconds since epoch).
        case millisecondsSince1970

        /// Decode the date from an ISO 8601 formatted string.
        case iso8601

        /// Decode the date using a custom formatter.
        case formatted(DateFormatter)

        /// Decode the date using a custom closure.
        case custom((Decoder) throws -> Date)
    }

    /// The strategy to use for decoding `Data` values.
    public enum DataDecodingStrategy {
        /// Decode data from a Base64-encoded string.
        case base64

        /// Decode the data using a custom closure.
        case custom((Decoder) throws -> Data)
    }

    /// The strategy to use for non-conforming floating-point values.
    public enum NonConformingFloatDecodingStrategy {
        /// Throw an error when encountering non-conforming values.
        case `throw`

        /// Decode infinity and NaN from specific string values.
        case convertFromString(positiveInfinity: String, negativeInfinity: String, nan: String)
    }

    /// The strategy to use when decoding keys.
    public enum KeyDecodingStrategy {
        /// Use the keys specified by each type.
        case useDefaultKeys

        /// Convert keys from snake_case to camelCase.
        case convertFromSnakeCase

        /// Use a custom function to convert keys.
        case custom((_ codingPath: [CodingKey]) -> CodingKey)
    }

    /// The strategy to use for decoding dates. Default is `.secondsSince1970`.
    public var dateDecodingStrategy: DateDecodingStrategy = .secondsSince1970

    /// The strategy to use for decoding data. Default is `.base64`.
    public var dataDecodingStrategy: DataDecodingStrategy = .base64

    /// The strategy to use for non-conforming floats. Default is `.throw`.
    public var nonConformingFloatDecodingStrategy: NonConformingFloatDecodingStrategy = .throw

    /// The strategy to use for decoding keys. Default is `.useDefaultKeys`.
    public var keyDecodingStrategy: KeyDecodingStrategy = .useDefaultKeys

    /// Contextual user info for decoding.
    public var userInfo: [CodingUserInfoKey: Any] = [:]

    /// Creates a new BONJSON decoder.
    public init() {}

    /// Decodes a value of the given type from the given BONJSON representation.
    ///
    /// - Parameters:
    ///   - type: The type of the value to decode.
    ///   - data: The data to decode from.
    /// - Returns: A value of the requested type.
    /// - Throws: An error if decoding fails.
    public func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let reader = BONJSONReader(data: data)
        let value = try reader.parse()

        let decoder = _BONJSONDecoder(
            value: value,
            codingPath: [],
            userInfo: userInfo,
            dateDecodingStrategy: dateDecodingStrategy,
            dataDecodingStrategy: dataDecodingStrategy,
            nonConformingFloatDecodingStrategy: nonConformingFloatDecodingStrategy,
            keyDecodingStrategy: keyDecodingStrategy
        )

        return try decodeValue(type, using: decoder)
    }
}

// MARK: - Internal Decoder Implementation

/// Internal decoder that implements the Decoder protocol.
final class _BONJSONDecoder: Decoder {
    let value: BONJSONValue
    let codingPath: [CodingKey]
    let userInfo: [CodingUserInfoKey: Any]

    let dateDecodingStrategy: BONJSONDecoder.DateDecodingStrategy
    let dataDecodingStrategy: BONJSONDecoder.DataDecodingStrategy
    let nonConformingFloatDecodingStrategy: BONJSONDecoder.NonConformingFloatDecodingStrategy
    let keyDecodingStrategy: BONJSONDecoder.KeyDecodingStrategy

    init(
        value: BONJSONValue,
        codingPath: [CodingKey],
        userInfo: [CodingUserInfoKey: Any],
        dateDecodingStrategy: BONJSONDecoder.DateDecodingStrategy,
        dataDecodingStrategy: BONJSONDecoder.DataDecodingStrategy,
        nonConformingFloatDecodingStrategy: BONJSONDecoder.NonConformingFloatDecodingStrategy,
        keyDecodingStrategy: BONJSONDecoder.KeyDecodingStrategy
    ) {
        self.value = value
        self.codingPath = codingPath
        self.userInfo = userInfo
        self.dateDecodingStrategy = dateDecodingStrategy
        self.dataDecodingStrategy = dataDecodingStrategy
        self.nonConformingFloatDecodingStrategy = nonConformingFloatDecodingStrategy
        self.keyDecodingStrategy = keyDecodingStrategy
    }

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        guard case .object(let pairs) = value else {
            throw DecodingError.typeMismatch(
                [String: Any].self,
                DecodingError.Context(
                    codingPath: codingPath,
                    debugDescription: "Expected object but found \(value.typeName)"
                )
            )
        }

        let container = _BONJSONKeyedDecodingContainer<Key>(
            decoder: self,
            pairs: pairs,
            codingPath: codingPath
        )
        return KeyedDecodingContainer(container)
    }

    func unkeyedContainer() throws -> UnkeyedDecodingContainer {
        guard case .array(let elements) = value else {
            throw DecodingError.typeMismatch(
                [Any].self,
                DecodingError.Context(
                    codingPath: codingPath,
                    debugDescription: "Expected array but found \(value.typeName)"
                )
            )
        }

        return _BONJSONUnkeyedDecodingContainer(
            decoder: self,
            elements: elements,
            codingPath: codingPath
        )
    }

    func singleValueContainer() throws -> SingleValueDecodingContainer {
        return _BONJSONSingleValueDecodingContainer(decoder: self, codingPath: codingPath)
    }

    /// Creates a nested decoder for the given value and key.
    func nestedDecoder(value: BONJSONValue, forKey key: CodingKey) -> _BONJSONDecoder {
        return _BONJSONDecoder(
            value: value,
            codingPath: codingPath + [key],
            userInfo: userInfo,
            dateDecodingStrategy: dateDecodingStrategy,
            dataDecodingStrategy: dataDecodingStrategy,
            nonConformingFloatDecodingStrategy: nonConformingFloatDecodingStrategy,
            keyDecodingStrategy: keyDecodingStrategy
        )
    }

    /// Converts a key according to the key decoding strategy.
    func convertedKey(_ key: String) -> String {
        switch keyDecodingStrategy {
        case .useDefaultKeys:
            return key
        case .convertFromSnakeCase:
            return key.convertFromSnakeCase()
        case .custom(let converter):
            return converter(codingPath + [_BONJSONStringKey(key)]).stringValue
        }
    }
}

// MARK: - Keyed Decoding Container

struct _BONJSONKeyedDecodingContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let decoder: _BONJSONDecoder
    let pairs: [(String, BONJSONValue)]
    let codingPath: [CodingKey]

    /// Dictionary for fast key lookup.
    private let keyedValues: [String: BONJSONValue]

    var allKeys: [Key] {
        return pairs.compactMap { Key(stringValue: decoder.convertedKey($0.0)) }
    }

    init(decoder: _BONJSONDecoder, pairs: [(String, BONJSONValue)], codingPath: [CodingKey]) {
        self.decoder = decoder
        self.pairs = pairs
        self.codingPath = codingPath

        var dict: [String: BONJSONValue] = [:]
        for (key, value) in pairs {
            dict[decoder.convertedKey(key)] = value
        }
        self.keyedValues = dict
    }

    func contains(_ key: Key) -> Bool {
        return keyedValues[key.stringValue] != nil
    }

    private func value(forKey key: Key) throws -> BONJSONValue {
        guard let value = keyedValues[key.stringValue] else {
            throw DecodingError.keyNotFound(
                key,
                DecodingError.Context(
                    codingPath: codingPath,
                    debugDescription: "No value associated with key \(key.stringValue)"
                )
            )
        }
        return value
    }

    func decodeNil(forKey key: Key) throws -> Bool {
        guard let value = keyedValues[key.stringValue] else {
            throw DecodingError.keyNotFound(
                key,
                DecodingError.Context(
                    codingPath: codingPath,
                    debugDescription: "No value associated with key \(key.stringValue)"
                )
            )
        }
        return value == .null
    }

    func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool {
        let value = try value(forKey: key)
        guard case .bool(let b) = value else {
            throw typeMismatchError(type, value: value, forKey: key)
        }
        return b
    }

    func decode(_ type: String.Type, forKey key: Key) throws -> String {
        let value = try value(forKey: key)
        guard case .string(let s) = value else {
            throw typeMismatchError(type, value: value, forKey: key)
        }
        return s
    }

    func decode(_ type: Double.Type, forKey key: Key) throws -> Double {
        let value = try value(forKey: key)
        return try decodeFloatingPoint(type, from: value, forKey: key)
    }

    func decode(_ type: Float.Type, forKey key: Key) throws -> Float {
        let value = try value(forKey: key)
        return Float(try decodeFloatingPoint(Double.self, from: value, forKey: key))
    }

    func decode(_ type: Int.Type, forKey key: Key) throws -> Int {
        let value = try value(forKey: key)
        return try decodeInteger(type, from: value, forKey: key)
    }

    func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 {
        let value = try value(forKey: key)
        return try decodeInteger(type, from: value, forKey: key)
    }

    func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 {
        let value = try value(forKey: key)
        return try decodeInteger(type, from: value, forKey: key)
    }

    func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 {
        let value = try value(forKey: key)
        return try decodeInteger(type, from: value, forKey: key)
    }

    func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 {
        let value = try value(forKey: key)
        return try decodeInteger(type, from: value, forKey: key)
    }

    func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt {
        let value = try value(forKey: key)
        return try decodeInteger(type, from: value, forKey: key)
    }

    func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 {
        let value = try value(forKey: key)
        return try decodeInteger(type, from: value, forKey: key)
    }

    func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 {
        let value = try value(forKey: key)
        return try decodeInteger(type, from: value, forKey: key)
    }

    func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 {
        let value = try value(forKey: key)
        return try decodeInteger(type, from: value, forKey: key)
    }

    func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 {
        let value = try value(forKey: key)
        return try decodeInteger(type, from: value, forKey: key)
    }

    func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
        let value = try value(forKey: key)
        let nestedDecoder = decoder.nestedDecoder(value: value, forKey: key)
        return try decodeValue(type, using: nestedDecoder)
    }

    func nestedContainer<NestedKey: CodingKey>(
        keyedBy type: NestedKey.Type,
        forKey key: Key
    ) throws -> KeyedDecodingContainer<NestedKey> {
        let value = try value(forKey: key)
        guard case .object(let pairs) = value else {
            throw typeMismatchError([String: Any].self, value: value, forKey: key)
        }
        let nestedDecoder = decoder.nestedDecoder(value: value, forKey: key)
        let container = _BONJSONKeyedDecodingContainer<NestedKey>(
            decoder: nestedDecoder,
            pairs: pairs,
            codingPath: codingPath + [key]
        )
        return KeyedDecodingContainer(container)
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> UnkeyedDecodingContainer {
        let value = try value(forKey: key)
        guard case .array(let elements) = value else {
            throw typeMismatchError([Any].self, value: value, forKey: key)
        }
        let nestedDecoder = decoder.nestedDecoder(value: value, forKey: key)
        return _BONJSONUnkeyedDecodingContainer(
            decoder: nestedDecoder,
            elements: elements,
            codingPath: codingPath + [key]
        )
    }

    func superDecoder() throws -> Decoder {
        return try superDecoder(forKey: Key(stringValue: "super")!)
    }

    func superDecoder(forKey key: Key) throws -> Decoder {
        let value = try value(forKey: key)
        return decoder.nestedDecoder(value: value, forKey: key)
    }

    private func typeMismatchError<T>(_ type: T.Type, value: BONJSONValue, forKey key: Key) -> DecodingError {
        return DecodingError.typeMismatch(
            type,
            DecodingError.Context(
                codingPath: codingPath + [key],
                debugDescription: "Expected \(type) but found \(value.typeName)"
            )
        )
    }

    private func decodeFloatingPoint<T: BinaryFloatingPoint>(
        _ type: T.Type,
        from value: BONJSONValue,
        forKey key: Key
    ) throws -> T {
        switch value {
        case .float(let f):
            return T(f)
        case .int(let i):
            return T(i)
        case .uint(let u):
            return T(u)
        case .string(let s):
            // Check for non-conforming float strings
            if case .convertFromString(let posInf, let negInf, let nan) = decoder.nonConformingFloatDecodingStrategy {
                if s == posInf {
                    return T(Double.infinity)
                } else if s == negInf {
                    return T(-Double.infinity)
                } else if s == nan {
                    return T(Double.nan)
                }
            }
            throw typeMismatchError(type, value: value, forKey: key)
        default:
            throw typeMismatchError(type, value: value, forKey: key)
        }
    }

    private func decodeInteger<T: FixedWidthInteger>(
        _ type: T.Type,
        from value: BONJSONValue,
        forKey key: Key
    ) throws -> T {
        switch value {
        case .int(let i):
            guard let result = T(exactly: i) else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: codingPath + [key],
                        debugDescription: "Integer \(i) doesn't fit in \(type)"
                    )
                )
            }
            return result
        case .uint(let u):
            guard let result = T(exactly: u) else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: codingPath + [key],
                        debugDescription: "Integer \(u) doesn't fit in \(type)"
                    )
                )
            }
            return result
        case .float(let f):
            guard let result = T(exactly: f) else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: codingPath + [key],
                        debugDescription: "Float \(f) cannot be exactly converted to \(type)"
                    )
                )
            }
            return result
        default:
            throw typeMismatchError(type, value: value, forKey: key)
        }
    }
}

// MARK: - Unkeyed Decoding Container

struct _BONJSONUnkeyedDecodingContainer: UnkeyedDecodingContainer {
    let decoder: _BONJSONDecoder
    let elements: [BONJSONValue]
    let codingPath: [CodingKey]

    var count: Int? { elements.count }
    var isAtEnd: Bool { currentIndex >= elements.count }
    private(set) var currentIndex: Int = 0

    init(decoder: _BONJSONDecoder, elements: [BONJSONValue], codingPath: [CodingKey]) {
        self.decoder = decoder
        self.elements = elements
        self.codingPath = codingPath
    }

    private mutating func nextValue() throws -> BONJSONValue {
        guard !isAtEnd else {
            throw DecodingError.valueNotFound(
                Any.self,
                DecodingError.Context(
                    codingPath: codingPath + [_BONJSONIndexKey(index: currentIndex)],
                    debugDescription: "Unkeyed container is at end"
                )
            )
        }
        let value = elements[currentIndex]
        currentIndex += 1
        return value
    }

    mutating func decodeNil() throws -> Bool {
        guard !isAtEnd else { return false }
        if elements[currentIndex] == .null {
            currentIndex += 1
            return true
        }
        return false
    }

    mutating func decode(_ type: Bool.Type) throws -> Bool {
        let value = try nextValue()
        guard case .bool(let b) = value else {
            throw typeMismatchError(type, value: value)
        }
        return b
    }

    mutating func decode(_ type: String.Type) throws -> String {
        let value = try nextValue()
        guard case .string(let s) = value else {
            throw typeMismatchError(type, value: value)
        }
        return s
    }

    mutating func decode(_ type: Double.Type) throws -> Double {
        let value = try nextValue()
        return try decodeFloatingPoint(type, from: value)
    }

    mutating func decode(_ type: Float.Type) throws -> Float {
        let value = try nextValue()
        return Float(try decodeFloatingPoint(Double.self, from: value))
    }

    mutating func decode(_ type: Int.Type) throws -> Int {
        let value = try nextValue()
        return try decodeInteger(type, from: value)
    }

    mutating func decode(_ type: Int8.Type) throws -> Int8 {
        let value = try nextValue()
        return try decodeInteger(type, from: value)
    }

    mutating func decode(_ type: Int16.Type) throws -> Int16 {
        let value = try nextValue()
        return try decodeInteger(type, from: value)
    }

    mutating func decode(_ type: Int32.Type) throws -> Int32 {
        let value = try nextValue()
        return try decodeInteger(type, from: value)
    }

    mutating func decode(_ type: Int64.Type) throws -> Int64 {
        let value = try nextValue()
        return try decodeInteger(type, from: value)
    }

    mutating func decode(_ type: UInt.Type) throws -> UInt {
        let value = try nextValue()
        return try decodeInteger(type, from: value)
    }

    mutating func decode(_ type: UInt8.Type) throws -> UInt8 {
        let value = try nextValue()
        return try decodeInteger(type, from: value)
    }

    mutating func decode(_ type: UInt16.Type) throws -> UInt16 {
        let value = try nextValue()
        return try decodeInteger(type, from: value)
    }

    mutating func decode(_ type: UInt32.Type) throws -> UInt32 {
        let value = try nextValue()
        return try decodeInteger(type, from: value)
    }

    mutating func decode(_ type: UInt64.Type) throws -> UInt64 {
        let value = try nextValue()
        return try decodeInteger(type, from: value)
    }

    mutating func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let index = currentIndex
        let value = try nextValue()
        let nestedDecoder = decoder.nestedDecoder(value: value, forKey: _BONJSONIndexKey(index: index))
        return try decodeValue(type, using: nestedDecoder)
    }

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy type: NestedKey.Type
    ) throws -> KeyedDecodingContainer<NestedKey> {
        let index = currentIndex
        let value = try nextValue()
        guard case .object(let pairs) = value else {
            throw typeMismatchError([String: Any].self, value: value)
        }
        let nestedDecoder = decoder.nestedDecoder(value: value, forKey: _BONJSONIndexKey(index: index))
        let container = _BONJSONKeyedDecodingContainer<NestedKey>(
            decoder: nestedDecoder,
            pairs: pairs,
            codingPath: codingPath + [_BONJSONIndexKey(index: index)]
        )
        return KeyedDecodingContainer(container)
    }

    mutating func nestedUnkeyedContainer() throws -> UnkeyedDecodingContainer {
        let index = currentIndex
        let value = try nextValue()
        guard case .array(let elements) = value else {
            throw typeMismatchError([Any].self, value: value)
        }
        let nestedDecoder = decoder.nestedDecoder(value: value, forKey: _BONJSONIndexKey(index: index))
        return _BONJSONUnkeyedDecodingContainer(
            decoder: nestedDecoder,
            elements: elements,
            codingPath: codingPath + [_BONJSONIndexKey(index: index)]
        )
    }

    mutating func superDecoder() throws -> Decoder {
        let index = currentIndex
        let value = try nextValue()
        return decoder.nestedDecoder(value: value, forKey: _BONJSONIndexKey(index: index))
    }

    private func typeMismatchError<T>(_ type: T.Type, value: BONJSONValue) -> DecodingError {
        return DecodingError.typeMismatch(
            type,
            DecodingError.Context(
                codingPath: codingPath + [_BONJSONIndexKey(index: currentIndex - 1)],
                debugDescription: "Expected \(type) but found \(value.typeName)"
            )
        )
    }

    private func decodeFloatingPoint<T: BinaryFloatingPoint>(
        _ type: T.Type,
        from value: BONJSONValue
    ) throws -> T {
        switch value {
        case .float(let f):
            return T(f)
        case .int(let i):
            return T(i)
        case .uint(let u):
            return T(u)
        case .string(let s):
            if case .convertFromString(let posInf, let negInf, let nan) = decoder.nonConformingFloatDecodingStrategy {
                if s == posInf {
                    return T(Double.infinity)
                } else if s == negInf {
                    return T(-Double.infinity)
                } else if s == nan {
                    return T(Double.nan)
                }
            }
            throw typeMismatchError(type, value: value)
        default:
            throw typeMismatchError(type, value: value)
        }
    }

    private func decodeInteger<T: FixedWidthInteger>(
        _ type: T.Type,
        from value: BONJSONValue
    ) throws -> T {
        switch value {
        case .int(let i):
            guard let result = T(exactly: i) else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: codingPath + [_BONJSONIndexKey(index: currentIndex - 1)],
                        debugDescription: "Integer \(i) doesn't fit in \(type)"
                    )
                )
            }
            return result
        case .uint(let u):
            guard let result = T(exactly: u) else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: codingPath + [_BONJSONIndexKey(index: currentIndex - 1)],
                        debugDescription: "Integer \(u) doesn't fit in \(type)"
                    )
                )
            }
            return result
        case .float(let f):
            guard let result = T(exactly: f) else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: codingPath + [_BONJSONIndexKey(index: currentIndex - 1)],
                        debugDescription: "Float \(f) cannot be exactly converted to \(type)"
                    )
                )
            }
            return result
        default:
            throw typeMismatchError(type, value: value)
        }
    }
}

// MARK: - Single Value Decoding Container

struct _BONJSONSingleValueDecodingContainer: SingleValueDecodingContainer {
    let decoder: _BONJSONDecoder
    let codingPath: [CodingKey]

    private var value: BONJSONValue { decoder.value }

    init(decoder: _BONJSONDecoder, codingPath: [CodingKey]) {
        self.decoder = decoder
        self.codingPath = codingPath
    }

    func decodeNil() -> Bool {
        return value == .null
    }

    func decode(_ type: Bool.Type) throws -> Bool {
        guard case .bool(let b) = value else {
            throw typeMismatchError(type)
        }
        return b
    }

    func decode(_ type: String.Type) throws -> String {
        guard case .string(let s) = value else {
            throw typeMismatchError(type)
        }
        return s
    }

    func decode(_ type: Double.Type) throws -> Double {
        return try decodeFloatingPoint(type)
    }

    func decode(_ type: Float.Type) throws -> Float {
        return Float(try decodeFloatingPoint(Double.self))
    }

    func decode(_ type: Int.Type) throws -> Int {
        return try decodeInteger(type)
    }

    func decode(_ type: Int8.Type) throws -> Int8 {
        return try decodeInteger(type)
    }

    func decode(_ type: Int16.Type) throws -> Int16 {
        return try decodeInteger(type)
    }

    func decode(_ type: Int32.Type) throws -> Int32 {
        return try decodeInteger(type)
    }

    func decode(_ type: Int64.Type) throws -> Int64 {
        return try decodeInteger(type)
    }

    func decode(_ type: UInt.Type) throws -> UInt {
        return try decodeInteger(type)
    }

    func decode(_ type: UInt8.Type) throws -> UInt8 {
        return try decodeInteger(type)
    }

    func decode(_ type: UInt16.Type) throws -> UInt16 {
        return try decodeInteger(type)
    }

    func decode(_ type: UInt32.Type) throws -> UInt32 {
        return try decodeInteger(type)
    }

    func decode(_ type: UInt64.Type) throws -> UInt64 {
        return try decodeInteger(type)
    }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        return try decodeValue(type, using: decoder)
    }

    private func typeMismatchError<T>(_ type: T.Type) -> DecodingError {
        return DecodingError.typeMismatch(
            type,
            DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "Expected \(type) but found \(value.typeName)"
            )
        )
    }

    private func decodeFloatingPoint<T: BinaryFloatingPoint>(_ type: T.Type) throws -> T {
        switch value {
        case .float(let f):
            return T(f)
        case .int(let i):
            return T(i)
        case .uint(let u):
            return T(u)
        case .string(let s):
            if case .convertFromString(let posInf, let negInf, let nan) = decoder.nonConformingFloatDecodingStrategy {
                if s == posInf {
                    return T(Double.infinity)
                } else if s == negInf {
                    return T(-Double.infinity)
                } else if s == nan {
                    return T(Double.nan)
                }
            }
            throw typeMismatchError(type)
        default:
            throw typeMismatchError(type)
        }
    }

    private func decodeInteger<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
        switch value {
        case .int(let i):
            guard let result = T(exactly: i) else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: codingPath,
                        debugDescription: "Integer \(i) doesn't fit in \(type)"
                    )
                )
            }
            return result
        case .uint(let u):
            guard let result = T(exactly: u) else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: codingPath,
                        debugDescription: "Integer \(u) doesn't fit in \(type)"
                    )
                )
            }
            return result
        case .float(let f):
            guard let result = T(exactly: f) else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: codingPath,
                        debugDescription: "Float \(f) cannot be exactly converted to \(type)"
                    )
                )
            }
            return result
        default:
            throw typeMismatchError(type)
        }
    }
}

// MARK: - Helper Types

/// A string-based coding key.
struct _BONJSONStringKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }

    init(_ string: String) {
        self.stringValue = string
    }

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        return nil
    }
}

// MARK: - Special Type Decoding

/// Decodes a value, handling special types like Date and Data.
private func decodeValue<T: Decodable>(_ type: T.Type, using decoder: _BONJSONDecoder) throws -> T {
    // Handle Date specially
    if type == Date.self {
        return try decodeDate(using: decoder) as! T
    }

    // Handle Data specially
    if type == Data.self {
        return try decodeData(using: decoder) as! T
    }

    // Handle URL specially
    if type == URL.self {
        guard case .string(let s) = decoder.value else {
            throw DecodingError.typeMismatch(
                URL.self,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Expected string for URL but found \(decoder.value.typeName)"
                )
            )
        }
        guard let url = URL(string: s) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid URL string: \(s)"
                )
            )
        }
        return url as! T
    }

    // Default decoding
    return try T(from: decoder)
}

/// Decodes a Date using the configured strategy.
private func decodeDate(using decoder: _BONJSONDecoder) throws -> Date {
    switch decoder.dateDecodingStrategy {
    case .secondsSince1970:
        let interval = try extractNumber(from: decoder.value, codingPath: decoder.codingPath)
        return Date(timeIntervalSince1970: interval)

    case .millisecondsSince1970:
        let interval = try extractNumber(from: decoder.value, codingPath: decoder.codingPath)
        return Date(timeIntervalSince1970: interval / 1000)

    case .iso8601:
        guard case .string(let s) = decoder.value else {
            throw DecodingError.typeMismatch(
                String.self,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Expected string for ISO 8601 date"
                )
            )
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: s) else {
            // Try without fractional seconds
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = formatter.date(from: s) else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "Invalid ISO 8601 date string: \(s)"
                    )
                )
            }
            return date
        }
        return date

    case .formatted(let formatter):
        guard case .string(let s) = decoder.value else {
            throw DecodingError.typeMismatch(
                String.self,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Expected string for formatted date"
                )
            )
        }
        guard let date = formatter.date(from: s) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Date string doesn't match expected format: \(s)"
                )
            )
        }
        return date

    case .custom(let closure):
        return try closure(decoder)
    }
}

/// Decodes Data using the configured strategy.
private func decodeData(using decoder: _BONJSONDecoder) throws -> Data {
    switch decoder.dataDecodingStrategy {
    case .base64:
        guard case .string(let s) = decoder.value else {
            throw DecodingError.typeMismatch(
                String.self,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Expected string for Base64 data"
                )
            )
        }
        guard let data = Data(base64Encoded: s) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid Base64 string"
                )
            )
        }
        return data

    case .custom(let closure):
        return try closure(decoder)
    }
}

/// Extracts a numeric value as Double from a BONJSONValue.
private func extractNumber(from value: BONJSONValue, codingPath: [CodingKey]) throws -> Double {
    switch value {
    case .float(let f):
        return f
    case .int(let i):
        return Double(i)
    case .uint(let u):
        return Double(u)
    default:
        throw DecodingError.typeMismatch(
            Double.self,
            DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "Expected number but found \(value.typeName)"
            )
        )
    }
}

// MARK: - String Extensions

extension String {
    /// Converts a snake_case string to camelCase.
    func convertFromSnakeCase() -> String {
        guard contains("_") else { return self }

        var result = ""
        var capitalizeNext = false

        for char in self {
            if char == "_" {
                capitalizeNext = true
            } else if capitalizeNext {
                result += char.uppercased()
                capitalizeNext = false
            } else {
                result += String(char)
            }
        }

        return result
    }
}
