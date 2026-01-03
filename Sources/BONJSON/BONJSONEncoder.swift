// ABOUTME: Public BONJSONEncoder API matching Apple's JSONEncoder interface.
// ABOUTME: Provides Codable support for encoding Swift types to BONJSON binary format.

import Foundation

/// An object that encodes instances of a data type as BONJSON data.
///
/// Use `BONJSONEncoder` in the same way you would use `JSONEncoder`:
///
///     struct Person: Codable {
///         var name: String
///         var age: Int
///     }
///
///     let encoder = BONJSONEncoder()
///     let person = Person(name: "Alice", age: 30)
///     let data = try encoder.encode(person)
///
public final class BONJSONEncoder {

    /// The strategy to use for encoding `Date` values.
    public enum DateEncodingStrategy {
        /// Encode the date as a Unix timestamp (seconds since epoch).
        case secondsSince1970

        /// Encode the date as a Unix timestamp (milliseconds since epoch).
        case millisecondsSince1970

        /// Encode the date as an ISO 8601 formatted string.
        case iso8601

        /// Encode the date using a custom formatter.
        case formatted(DateFormatter)

        /// Encode the date using a custom closure.
        case custom((Date, Encoder) throws -> Void)
    }

    /// The strategy to use for encoding `Data` values.
    public enum DataEncodingStrategy {
        /// Encode data as a Base64-encoded string.
        case base64

        /// Encode the data using a custom closure.
        case custom((Data, Encoder) throws -> Void)
    }

    /// The strategy to use for non-conforming floating-point values.
    public enum NonConformingFloatEncodingStrategy {
        /// Throw an error when encountering non-conforming values.
        case `throw`

        /// Encode infinity and NaN as specific string values.
        case convertToString(positiveInfinity: String, negativeInfinity: String, nan: String)
    }

    /// The strategy to use when encoding keys.
    public enum KeyEncodingStrategy {
        /// Use the keys specified by each type.
        case useDefaultKeys

        /// Convert keys to snake_case.
        case convertToSnakeCase

        /// Use a custom function to convert keys.
        case custom((_ codingPath: [CodingKey]) -> CodingKey)
    }

    /// The strategy to use for encoding dates. Default is `.secondsSince1970`.
    public var dateEncodingStrategy: DateEncodingStrategy = .secondsSince1970

    /// The strategy to use for encoding data. Default is `.base64`.
    public var dataEncodingStrategy: DataEncodingStrategy = .base64

    /// The strategy to use for non-conforming floats. Default is `.throw`.
    public var nonConformingFloatEncodingStrategy: NonConformingFloatEncodingStrategy = .throw

    /// The strategy to use for encoding keys. Default is `.useDefaultKeys`.
    public var keyEncodingStrategy: KeyEncodingStrategy = .useDefaultKeys

    /// Contextual user info for encoding.
    public var userInfo: [CodingUserInfoKey: Any] = [:]

    /// Creates a new BONJSON encoder.
    public init() {}

    /// Encodes the given value and returns its BONJSON representation.
    ///
    /// - Parameter value: The value to encode.
    /// - Returns: A new `Data` value containing the encoded BONJSON data.
    /// - Throws: An error if encoding fails.
    public func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = _BONJSONEncoder(
            codingPath: [],
            userInfo: userInfo,
            dateEncodingStrategy: dateEncodingStrategy,
            dataEncodingStrategy: dataEncodingStrategy,
            nonConformingFloatEncodingStrategy: nonConformingFloatEncodingStrategy,
            keyEncodingStrategy: keyEncodingStrategy
        )

        try encoder.encodeValue(value)

        guard let topValue = encoder.value else {
            throw BONJSONEncodingError.internalError("No value was encoded")
        }

        // Serialize the intermediate representation to BONJSON binary
        let writer = BONJSONWriter()
        try serializeValue(topValue, to: writer)
        return writer.data
    }
}

// MARK: - Intermediate Value Type

/// Intermediate representation of a value during encoding.
/// This mirrors BONJSONValue but is built during encoding.
indirect enum _EncodedValue {
    case null
    case bool(Bool)
    case int(Int64)
    case uint(UInt64)
    case float(Double)
    case string(String)
    case array([_EncodedValue])
    case object([(String, _EncodedValue)])
}

// MARK: - Serialization

/// Serializes an encoded value to binary BONJSON format.
private func serializeValue(_ value: _EncodedValue, to writer: BONJSONWriter) throws {
    switch value {
    case .null:
        writer.writeNull()

    case .bool(let b):
        writer.writeBool(b)

    case .int(let i):
        writer.writeInt(i)

    case .uint(let u):
        writer.writeUInt(u)

    case .float(let f):
        try writer.writeFloat(f)

    case .string(let s):
        writer.writeString(s)

    case .array(let elements):
        try writer.beginArray()
        for element in elements {
            try serializeValue(element, to: writer)
        }
        writer.endContainer()

    case .object(let pairs):
        try writer.beginObject()
        for (key, value) in pairs {
            writer.writeString(key)
            try serializeValue(value, to: writer)
        }
        writer.endContainer()
    }
}

// MARK: - Internal Encoder Implementation

/// Internal encoder that implements the Encoder protocol.
/// Builds an intermediate representation that is later serialized.
final class _BONJSONEncoder: Encoder {
    let codingPath: [CodingKey]
    let userInfo: [CodingUserInfoKey: Any]

    let dateEncodingStrategy: BONJSONEncoder.DateEncodingStrategy
    let dataEncodingStrategy: BONJSONEncoder.DataEncodingStrategy
    let nonConformingFloatEncodingStrategy: BONJSONEncoder.NonConformingFloatEncodingStrategy
    let keyEncodingStrategy: BONJSONEncoder.KeyEncodingStrategy

    /// The encoded value (set after encoding completes).
    var value: _EncodedValue?

    init(
        codingPath: [CodingKey],
        userInfo: [CodingUserInfoKey: Any],
        dateEncodingStrategy: BONJSONEncoder.DateEncodingStrategy,
        dataEncodingStrategy: BONJSONEncoder.DataEncodingStrategy,
        nonConformingFloatEncodingStrategy: BONJSONEncoder.NonConformingFloatEncodingStrategy,
        keyEncodingStrategy: BONJSONEncoder.KeyEncodingStrategy
    ) {
        self.codingPath = codingPath
        self.userInfo = userInfo
        self.dateEncodingStrategy = dateEncodingStrategy
        self.dataEncodingStrategy = dataEncodingStrategy
        self.nonConformingFloatEncodingStrategy = nonConformingFloatEncodingStrategy
        self.keyEncodingStrategy = keyEncodingStrategy
    }

    func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
        let container = _BONJSONKeyedEncodingContainer<Key>(encoder: self, codingPath: codingPath)
        return KeyedEncodingContainer(container)
    }

    func unkeyedContainer() -> UnkeyedEncodingContainer {
        return _BONJSONUnkeyedEncodingContainer(encoder: self, codingPath: codingPath)
    }

    func singleValueContainer() -> SingleValueEncodingContainer {
        return _BONJSONSingleValueEncodingContainer(encoder: self, codingPath: codingPath)
    }

    /// Encodes a value and stores the result.
    func encodeValue<T: Encodable>(_ value: T) throws {
        // Handle special types
        if let date = value as? Date {
            self.value = try encodeDate(date)
            return
        }

        if let data = value as? Data {
            self.value = try encodeData(data)
            return
        }

        if let url = value as? URL {
            self.value = .string(url.absoluteString)
            return
        }

        // Default encoding
        try value.encode(to: self)
    }

    /// Encodes a Date using the configured strategy.
    private func encodeDate(_ date: Date) throws -> _EncodedValue {
        switch dateEncodingStrategy {
        case .secondsSince1970:
            return .float(date.timeIntervalSince1970)

        case .millisecondsSince1970:
            return .float(date.timeIntervalSince1970 * 1000)

        case .iso8601:
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return .string(formatter.string(from: date))

        case .formatted(let formatter):
            return .string(formatter.string(from: date))

        case .custom(let closure):
            let encoder = _BONJSONEncoder(
                codingPath: codingPath,
                userInfo: userInfo,
                dateEncodingStrategy: dateEncodingStrategy,
                dataEncodingStrategy: dataEncodingStrategy,
                nonConformingFloatEncodingStrategy: nonConformingFloatEncodingStrategy,
                keyEncodingStrategy: keyEncodingStrategy
            )
            try closure(date, encoder)
            return encoder.value ?? .null
        }
    }

    /// Encodes Data using the configured strategy.
    private func encodeData(_ data: Data) throws -> _EncodedValue {
        switch dataEncodingStrategy {
        case .base64:
            return .string(data.base64EncodedString())

        case .custom(let closure):
            let encoder = _BONJSONEncoder(
                codingPath: codingPath,
                userInfo: userInfo,
                dateEncodingStrategy: dateEncodingStrategy,
                dataEncodingStrategy: dataEncodingStrategy,
                nonConformingFloatEncodingStrategy: nonConformingFloatEncodingStrategy,
                keyEncodingStrategy: keyEncodingStrategy
            )
            try closure(data, encoder)
            return encoder.value ?? .null
        }
    }

    /// Converts a key according to the key encoding strategy.
    func convertedKey(_ key: CodingKey) -> String {
        switch keyEncodingStrategy {
        case .useDefaultKeys:
            return key.stringValue
        case .convertToSnakeCase:
            return key.stringValue.convertToSnakeCase()
        case .custom(let converter):
            return converter(codingPath + [key]).stringValue
        }
    }

    /// Encodes a floating-point value, handling non-conforming values.
    func encodeFloat(_ value: Double) throws -> _EncodedValue {
        if value.isFinite {
            return .float(value)
        }

        switch nonConformingFloatEncodingStrategy {
        case .throw:
            throw BONJSONEncodingError.invalidFloat(value)
        case .convertToString(let posInf, let negInf, let nan):
            if value.isNaN {
                return .string(nan)
            } else if value == .infinity {
                return .string(posInf)
            } else {
                return .string(negInf)
            }
        }
    }
}

// MARK: - Keyed Encoding Container

struct _BONJSONKeyedEncodingContainer<Key: CodingKey>: KeyedEncodingContainerProtocol {
    let encoder: _BONJSONEncoder
    let codingPath: [CodingKey]

    /// The accumulated key-value pairs.
    fileprivate let pairs: _ObjectPairs

    init(encoder: _BONJSONEncoder, codingPath: [CodingKey]) {
        self.encoder = encoder
        self.codingPath = codingPath
        self.pairs = _ObjectPairs()
        encoder.value = .object([])
    }

    private func append(key: String, value: _EncodedValue) {
        pairs.append((key, value))
        encoder.value = .object(pairs.pairs)
    }

    mutating func encodeNil(forKey key: Key) throws {
        append(key: encoder.convertedKey(key), value: .null)
    }

    mutating func encode(_ value: Bool, forKey key: Key) throws {
        append(key: encoder.convertedKey(key), value: .bool(value))
    }

    mutating func encode(_ value: String, forKey key: Key) throws {
        append(key: encoder.convertedKey(key), value: .string(value))
    }

    mutating func encode(_ value: Double, forKey key: Key) throws {
        let encoded = try encoder.encodeFloat(value)
        append(key: encoder.convertedKey(key), value: encoded)
    }

    mutating func encode(_ value: Float, forKey key: Key) throws {
        let encoded = try encoder.encodeFloat(Double(value))
        append(key: encoder.convertedKey(key), value: encoded)
    }

    mutating func encode(_ value: Int, forKey key: Key) throws {
        append(key: encoder.convertedKey(key), value: .int(Int64(value)))
    }

    mutating func encode(_ value: Int8, forKey key: Key) throws {
        append(key: encoder.convertedKey(key), value: .int(Int64(value)))
    }

    mutating func encode(_ value: Int16, forKey key: Key) throws {
        append(key: encoder.convertedKey(key), value: .int(Int64(value)))
    }

    mutating func encode(_ value: Int32, forKey key: Key) throws {
        append(key: encoder.convertedKey(key), value: .int(Int64(value)))
    }

    mutating func encode(_ value: Int64, forKey key: Key) throws {
        append(key: encoder.convertedKey(key), value: .int(value))
    }

    mutating func encode(_ value: UInt, forKey key: Key) throws {
        append(key: encoder.convertedKey(key), value: .uint(UInt64(value)))
    }

    mutating func encode(_ value: UInt8, forKey key: Key) throws {
        append(key: encoder.convertedKey(key), value: .uint(UInt64(value)))
    }

    mutating func encode(_ value: UInt16, forKey key: Key) throws {
        append(key: encoder.convertedKey(key), value: .uint(UInt64(value)))
    }

    mutating func encode(_ value: UInt32, forKey key: Key) throws {
        append(key: encoder.convertedKey(key), value: .uint(UInt64(value)))
    }

    mutating func encode(_ value: UInt64, forKey key: Key) throws {
        append(key: encoder.convertedKey(key), value: .uint(value))
    }

    mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws {
        let nestedEncoder = createNestedEncoder(forKey: key)
        try nestedEncoder.encodeValue(value)
        if let encodedValue = nestedEncoder.value {
            append(key: encoder.convertedKey(key), value: encodedValue)
        }
    }

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy keyType: NestedKey.Type,
        forKey key: Key
    ) -> KeyedEncodingContainer<NestedKey> {
        let nestedEncoder = createNestedEncoder(forKey: key)
        let container = _BONJSONKeyedEncodingContainer<NestedKey>(
            encoder: nestedEncoder,
            codingPath: codingPath + [key]
        )

        // Store a reference to update when container is done
        let nestedPairs = container.pairs
        pairs.addNested(key: encoder.convertedKey(key), pairs: nestedPairs, encoder: encoder)

        return KeyedEncodingContainer(container)
    }

    mutating func nestedUnkeyedContainer(forKey key: Key) -> UnkeyedEncodingContainer {
        let nestedEncoder = createNestedEncoder(forKey: key)
        let container = _BONJSONUnkeyedEncodingContainer(
            encoder: nestedEncoder,
            codingPath: codingPath + [key]
        )

        // Store a reference to update when container is done
        pairs.addNestedArray(key: encoder.convertedKey(key), elements: container.elements, encoder: encoder)

        return container
    }

    mutating func superEncoder() -> Encoder {
        return superEncoder(forKey: Key(stringValue: "super")!)
    }

    mutating func superEncoder(forKey key: Key) -> Encoder {
        let nestedEncoder = createNestedEncoder(forKey: key)
        pairs.addNestedEncoder(key: encoder.convertedKey(key), nestedEncoder: nestedEncoder, encoder: encoder)
        return nestedEncoder
    }

    private func createNestedEncoder(forKey key: Key) -> _BONJSONEncoder {
        return _BONJSONEncoder(
            codingPath: codingPath + [key],
            userInfo: encoder.userInfo,
            dateEncodingStrategy: encoder.dateEncodingStrategy,
            dataEncodingStrategy: encoder.dataEncodingStrategy,
            nonConformingFloatEncodingStrategy: encoder.nonConformingFloatEncodingStrategy,
            keyEncodingStrategy: encoder.keyEncodingStrategy
        )
    }
}

/// Helper class to accumulate object pairs with reference semantics.
fileprivate final class _ObjectPairs {
    var pairs: [(String, _EncodedValue)] = []
    private var nestedContainers: [() -> Void] = []

    func append(_ pair: (String, _EncodedValue)) {
        // Finalize any pending nested containers
        for finalizer in nestedContainers {
            finalizer()
        }
        nestedContainers.removeAll()
        pairs.append(pair)
    }

    func addNested(key: String, pairs nestedPairs: _ObjectPairs, encoder: _BONJSONEncoder) {
        let index = pairs.count
        pairs.append((key, .object([])))
        nestedContainers.append { [weak self] in
            self?.pairs[index] = (key, .object(nestedPairs.pairs))
            encoder.value = .object(self?.pairs ?? [])
        }
    }

    func addNestedArray(key: String, elements: _ArrayElements, encoder: _BONJSONEncoder) {
        let index = pairs.count
        pairs.append((key, .array([])))
        nestedContainers.append { [weak self] in
            self?.pairs[index] = (key, .array(elements.elements))
            encoder.value = .object(self?.pairs ?? [])
        }
    }

    func addNestedEncoder(key: String, nestedEncoder: _BONJSONEncoder, encoder: _BONJSONEncoder) {
        let index = pairs.count
        pairs.append((key, .null))
        nestedContainers.append { [weak self] in
            self?.pairs[index] = (key, nestedEncoder.value ?? .null)
            encoder.value = .object(self?.pairs ?? [])
        }
    }

    func finalize(encoder: _BONJSONEncoder) {
        for finalizer in nestedContainers {
            finalizer()
        }
        nestedContainers.removeAll()
        encoder.value = .object(pairs)
    }
}

// MARK: - Unkeyed Encoding Container

struct _BONJSONUnkeyedEncodingContainer: UnkeyedEncodingContainer {
    let encoder: _BONJSONEncoder
    let codingPath: [CodingKey]

    /// The accumulated elements.
    fileprivate let elements: _ArrayElements

    var count: Int { elements.count }

    init(encoder: _BONJSONEncoder, codingPath: [CodingKey]) {
        self.encoder = encoder
        self.codingPath = codingPath
        self.elements = _ArrayElements()
        encoder.value = .array([])
    }

    private func append(_ value: _EncodedValue) {
        elements.append(value)
        encoder.value = .array(elements.elements)
    }

    mutating func encodeNil() throws {
        append(.null)
    }

    mutating func encode(_ value: Bool) throws {
        append(.bool(value))
    }

    mutating func encode(_ value: String) throws {
        append(.string(value))
    }

    mutating func encode(_ value: Double) throws {
        let encoded = try encoder.encodeFloat(value)
        append(encoded)
    }

    mutating func encode(_ value: Float) throws {
        let encoded = try encoder.encodeFloat(Double(value))
        append(encoded)
    }

    mutating func encode(_ value: Int) throws {
        append(.int(Int64(value)))
    }

    mutating func encode(_ value: Int8) throws {
        append(.int(Int64(value)))
    }

    mutating func encode(_ value: Int16) throws {
        append(.int(Int64(value)))
    }

    mutating func encode(_ value: Int32) throws {
        append(.int(Int64(value)))
    }

    mutating func encode(_ value: Int64) throws {
        append(.int(value))
    }

    mutating func encode(_ value: UInt) throws {
        append(.uint(UInt64(value)))
    }

    mutating func encode(_ value: UInt8) throws {
        append(.uint(UInt64(value)))
    }

    mutating func encode(_ value: UInt16) throws {
        append(.uint(UInt64(value)))
    }

    mutating func encode(_ value: UInt32) throws {
        append(.uint(UInt64(value)))
    }

    mutating func encode(_ value: UInt64) throws {
        append(.uint(value))
    }

    mutating func encode<T: Encodable>(_ value: T) throws {
        let nestedEncoder = createNestedEncoder()
        try nestedEncoder.encodeValue(value)
        if let encodedValue = nestedEncoder.value {
            append(encodedValue)
        }
    }

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy keyType: NestedKey.Type
    ) -> KeyedEncodingContainer<NestedKey> {
        let nestedEncoder = createNestedEncoder()
        let container = _BONJSONKeyedEncodingContainer<NestedKey>(
            encoder: nestedEncoder,
            codingPath: codingPath + [_BONJSONIndexKey(index: count)]
        )

        elements.addNested(pairs: container.pairs, encoder: encoder)

        return KeyedEncodingContainer(container)
    }

    mutating func nestedUnkeyedContainer() -> UnkeyedEncodingContainer {
        let nestedEncoder = createNestedEncoder()
        let container = _BONJSONUnkeyedEncodingContainer(
            encoder: nestedEncoder,
            codingPath: codingPath + [_BONJSONIndexKey(index: count)]
        )

        elements.addNestedArray(nestedElements: container.elements, encoder: encoder)

        return container
    }

    mutating func superEncoder() -> Encoder {
        let nestedEncoder = createNestedEncoder()
        elements.addNestedEncoder(nestedEncoder: nestedEncoder, encoder: encoder)
        return nestedEncoder
    }

    private func createNestedEncoder() -> _BONJSONEncoder {
        return _BONJSONEncoder(
            codingPath: codingPath + [_BONJSONIndexKey(index: count)],
            userInfo: encoder.userInfo,
            dateEncodingStrategy: encoder.dateEncodingStrategy,
            dataEncodingStrategy: encoder.dataEncodingStrategy,
            nonConformingFloatEncodingStrategy: encoder.nonConformingFloatEncodingStrategy,
            keyEncodingStrategy: encoder.keyEncodingStrategy
        )
    }
}

/// Helper class to accumulate array elements with reference semantics.
fileprivate final class _ArrayElements {
    var elements: [_EncodedValue] = []
    private var nestedContainers: [() -> Void] = []

    var count: Int { elements.count }

    func append(_ value: _EncodedValue) {
        // Finalize any pending nested containers
        for finalizer in nestedContainers {
            finalizer()
        }
        nestedContainers.removeAll()
        elements.append(value)
    }

    func addNested(pairs: _ObjectPairs, encoder: _BONJSONEncoder) {
        let index = elements.count
        elements.append(.object([]))
        nestedContainers.append { [weak self] in
            self?.elements[index] = .object(pairs.pairs)
            encoder.value = .array(self?.elements ?? [])
        }
    }

    func addNestedArray(nestedElements: _ArrayElements, encoder: _BONJSONEncoder) {
        let index = elements.count
        elements.append(.array([]))
        nestedContainers.append { [weak self] in
            self?.elements[index] = .array(nestedElements.elements)
            encoder.value = .array(self?.elements ?? [])
        }
    }

    func addNestedEncoder(nestedEncoder: _BONJSONEncoder, encoder: _BONJSONEncoder) {
        let index = elements.count
        elements.append(.null)
        nestedContainers.append { [weak self] in
            self?.elements[index] = nestedEncoder.value ?? .null
            encoder.value = .array(self?.elements ?? [])
        }
    }

    func finalize(encoder: _BONJSONEncoder) {
        for finalizer in nestedContainers {
            finalizer()
        }
        nestedContainers.removeAll()
        encoder.value = .array(elements)
    }
}

// MARK: - Single Value Encoding Container

struct _BONJSONSingleValueEncodingContainer: SingleValueEncodingContainer {
    let encoder: _BONJSONEncoder
    let codingPath: [CodingKey]

    init(encoder: _BONJSONEncoder, codingPath: [CodingKey]) {
        self.encoder = encoder
        self.codingPath = codingPath
    }

    mutating func encodeNil() throws {
        encoder.value = .null
    }

    mutating func encode(_ value: Bool) throws {
        encoder.value = .bool(value)
    }

    mutating func encode(_ value: String) throws {
        encoder.value = .string(value)
    }

    mutating func encode(_ value: Double) throws {
        encoder.value = try encoder.encodeFloat(value)
    }

    mutating func encode(_ value: Float) throws {
        encoder.value = try encoder.encodeFloat(Double(value))
    }

    mutating func encode(_ value: Int) throws {
        encoder.value = .int(Int64(value))
    }

    mutating func encode(_ value: Int8) throws {
        encoder.value = .int(Int64(value))
    }

    mutating func encode(_ value: Int16) throws {
        encoder.value = .int(Int64(value))
    }

    mutating func encode(_ value: Int32) throws {
        encoder.value = .int(Int64(value))
    }

    mutating func encode(_ value: Int64) throws {
        encoder.value = .int(value)
    }

    mutating func encode(_ value: UInt) throws {
        encoder.value = .uint(UInt64(value))
    }

    mutating func encode(_ value: UInt8) throws {
        encoder.value = .uint(UInt64(value))
    }

    mutating func encode(_ value: UInt16) throws {
        encoder.value = .uint(UInt64(value))
    }

    mutating func encode(_ value: UInt32) throws {
        encoder.value = .uint(UInt64(value))
    }

    mutating func encode(_ value: UInt64) throws {
        encoder.value = .uint(value)
    }

    mutating func encode<T: Encodable>(_ value: T) throws {
        try encoder.encodeValue(value)
    }
}

// MARK: - Helper Types

/// A coding key for array indices.
struct _BONJSONIndexKey: CodingKey {
    let index: Int

    var stringValue: String { "Index \(index)" }
    var intValue: Int? { index }

    init(index: Int) {
        self.index = index
    }

    init?(stringValue: String) {
        return nil
    }

    init?(intValue: Int) {
        self.index = intValue
    }
}

// MARK: - String Extensions

extension String {
    /// Converts a camelCase string to snake_case.
    func convertToSnakeCase() -> String {
        var result = ""
        for (index, char) in self.enumerated() {
            if char.isUppercase {
                if index > 0 {
                    result += "_"
                }
                result += char.lowercased()
            } else {
                result += String(char)
            }
        }
        return result
    }
}
