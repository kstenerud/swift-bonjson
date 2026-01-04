// ABOUTME: Public BONJSONDecoder API matching Apple's JSONDecoder interface.
// ABOUTME: Uses C position-map API for single-pass scanning and random access decoding.

import Foundation
import CKSBonjson

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

    /// Decodes a value of the given type from BONJSON data.
    ///
    /// - Parameters:
    ///   - type: The type to decode.
    ///   - data: The BONJSON data to decode.
    /// - Returns: A value of the requested type.
    /// - Throws: An error if decoding fails.
    public func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        // Build the position map using C API
        let map = try _PositionMap(data: data)

        let state = _MapDecoderState(
            map: map,
            userInfo: userInfo,
            dateDecodingStrategy: dateDecodingStrategy,
            dataDecodingStrategy: dataDecodingStrategy,
            nonConformingFloatDecodingStrategy: nonConformingFloatDecodingStrategy,
            keyDecodingStrategy: keyDecodingStrategy
        )

        let rootIndex = map.rootIndex
        let decoder = _MapDecoder(state: state, entryIndex: rootIndex, codingPath: [])

        // Handle special types that need custom decoding
        if type == Date.self {
            return try decoder.decodeDate() as! T
        }

        if type == Data.self {
            return try decoder.decodeData() as! T
        }

        if type == URL.self {
            let string = try decoder.decodeString()
            guard let url = URL(string: string) else {
                throw BONJSONDecodingError.invalidURL(string)
            }
            return url as! T
        }

        return try T(from: decoder)
    }
}

// MARK: - Errors

/// Errors that can occur during BONJSON decoding.
public enum BONJSONDecodingError: Error, CustomStringConvertible {
    case unexpectedEndOfData
    case invalidTypeCode(UInt8)
    case invalidUTF8String
    case invalidFloat
    case invalidURL(String)
    case containerDepthExceeded
    case expectedObjectKey
    case duplicateObjectKey(String)
    case typeMismatch(expected: String, actual: String)
    case keyNotFound(String)
    case dataRemaining
    case scanFailed(String)
    case mapFull

    public var description: String {
        switch self {
        case .unexpectedEndOfData:
            return "Unexpected end of data"
        case .invalidTypeCode(let code):
            return "Invalid type code: 0x\(String(code, radix: 16))"
        case .invalidUTF8String:
            return "Invalid UTF-8 string"
        case .invalidFloat:
            return "Invalid floating-point value"
        case .invalidURL(let string):
            return "Invalid URL: \(string)"
        case .containerDepthExceeded:
            return "Maximum container depth exceeded"
        case .expectedObjectKey:
            return "Expected object key (string)"
        case .duplicateObjectKey(let key):
            return "Duplicate object key: \(key)"
        case .typeMismatch(let expected, let actual):
            return "Type mismatch: expected \(expected), got \(actual)"
        case .keyNotFound(let key):
            return "Key not found: \(key)"
        case .dataRemaining:
            return "Data remaining after decoding"
        case .scanFailed(let message):
            return "Failed to scan BONJSON data: \(message)"
        case .mapFull:
            return "Position map buffer is full"
        }
    }
}

// MARK: - Position Map Wrapper

/// Wraps the C position map API for Swift use.
final class _PositionMap {
    /// The input data as a contiguous array - keeps pointer stable.
    private let inputBytes: [UInt8]

    /// The map context.
    private var context: KSBONJSONMapContext

    /// The entry buffer.
    private var entries: [KSBONJSONMapEntry]

    /// Precomputed subtree sizes for O(1) child access.
    private var subtreeSizes: [Int]

    /// Precomputed next sibling index for each entry (index after subtree).
    private var nextSibling: [Int]

    /// Actual entry count after scanning.
    private var entryCount: Int

    /// Root entry index.
    private(set) var rootIndex: size_t

    init(data: Data) throws {
        // Copy to contiguous array to ensure stable pointer
        self.inputBytes = Array(data)

        // Estimate entry count
        let estimatedEntries = ksbonjson_map_estimateEntries(inputBytes.count)
        self.entries = [KSBONJSONMapEntry](repeating: KSBONJSONMapEntry(), count: Int(estimatedEntries))
        self.subtreeSizes = []  // Will be computed after scanning
        self.nextSibling = []   // Will be computed after scanning
        self.entryCount = 0
        self.context = KSBONJSONMapContext()
        self.rootIndex = 0  // Will be set after scanning

        // Initialize and scan using stable pointers
        try inputBytes.withUnsafeBufferPointer { inputPtr in
            try entries.withUnsafeMutableBufferPointer { entriesPtr in
                ksbonjson_map_begin(
                    &context,
                    inputPtr.baseAddress,
                    inputPtr.count,
                    entriesPtr.baseAddress,
                    entriesPtr.count
                )

                let status = ksbonjson_map_scan(&context)
                guard status == KSBONJSON_DECODE_OK else {
                    let message = ksbonjson_describeDecodeStatus(status).map { String(cString: $0) } ?? "Unknown error"
                    throw BONJSONDecodingError.scanFailed(message)
                }
            }
        }

        self.rootIndex = ksbonjson_map_root(&context)
        self.entryCount = Int(ksbonjson_map_count(&context))

        // Precompute subtree sizes and next sibling indices for O(1) child access
        self.subtreeSizes = computeSubtreeSizes()
        self.nextSibling = subtreeSizes.enumerated().map { $0.offset + $0.element }
    }

    /// Compute subtree sizes for all entries in reverse order.
    /// Each container's size = 1 + sum of child sizes.
    /// Primitives have size 1.
    private func computeSubtreeSizes() -> [Int] {
        var sizes = [Int](repeating: 1, count: entryCount)

        // Process in reverse order so children are computed before parents
        for i in stride(from: entryCount - 1, through: 0, by: -1) {
            let entry = entries[i]
            if entry.type == KSBONJSON_TYPE_ARRAY || entry.type == KSBONJSON_TYPE_OBJECT {
                var totalSize = 1  // Include self
                var childPos = Int(entry.data.container.firstChild)
                for _ in 0..<entry.data.container.count {
                    if childPos < entryCount {
                        totalSize += sizes[childPos]
                        childPos += sizes[childPos]
                    }
                }
                sizes[i] = totalSize
            }
            // Primitives already have size 1
        }

        return sizes
    }

    /// Get entry at index.
    func getEntry(at index: size_t) -> KSBONJSONMapEntry? {
        guard index >= 0 && index < entryCount else {
            return nil
        }
        return entries[Int(index)]
    }

    /// Get string data - reads from stored input bytes using entry offset/length.
    func getString(at index: size_t) -> String? {
        guard index >= 0 && index < entryCount else {
            return nil
        }

        let entry = entries[Int(index)]
        guard entry.type == KSBONJSON_TYPE_STRING else {
            return nil
        }

        let offset = Int(entry.data.string.offset)
        let length = Int(entry.data.string.length)

        guard offset >= 0 && offset + length <= inputBytes.count else {
            return nil
        }

        // Create string directly from the input bytes
        return inputBytes.withUnsafeBufferPointer { ptr in
            let start = ptr.baseAddress! + offset
            let buffer = UnsafeBufferPointer(start: start, count: length)
            return String(decoding: buffer, as: UTF8.self)
        }
    }

    /// Sentinel value indicating "not found".
    static let notFound: size_t = -1

    /// Get cached subtree size at index.
    @inline(__always)
    private func subtreeSize(at index: Int) -> Int {
        guard index >= 0 && index < subtreeSizes.count else {
            return 1
        }
        return subtreeSizes[index]
    }

    /// Get child entry index.
    func getChild(containerIndex: size_t, childIndex: size_t) -> size_t {
        guard containerIndex >= 0 && containerIndex < entryCount else {
            return Self.notFound
        }

        let entry = entries[Int(containerIndex)]
        guard entry.type == KSBONJSON_TYPE_ARRAY || entry.type == KSBONJSON_TYPE_OBJECT else {
            return Self.notFound
        }

        if childIndex >= entry.data.container.count {
            return Self.notFound
        }

        // Walk from firstChild, using nextSibling for O(1) per step
        var currentIndex = Int(entry.data.container.firstChild)
        for _ in 0..<childIndex {
            currentIndex = nextSibling[currentIndex]
        }

        return size_t(currentIndex)
    }

    /// Find key in object.
    func findKey(objectIndex: size_t, key: String) -> size_t {
        guard objectIndex >= 0 && objectIndex < entryCount else {
            return Self.notFound
        }

        let objEntry = entries[Int(objectIndex)]
        guard objEntry.type == KSBONJSON_TYPE_OBJECT else {
            return Self.notFound
        }

        // Object children are stored as key, value, key, value, ...
        let pairCount = Int(objEntry.data.container.count) / 2
        var currentIndex = Int(objEntry.data.container.firstChild)

        for _ in 0..<pairCount {
            let keyIndex = currentIndex
            guard keyIndex < entryCount else {
                break
            }

            let keyEntry = entries[keyIndex]

            // Advance past the key using nextSibling
            let valueIndex = nextSibling[keyIndex]
            // Advance past the value for next iteration
            currentIndex = nextSibling[valueIndex]

            guard keyEntry.type == KSBONJSON_TYPE_STRING else {
                continue
            }

            let keyOffset = Int(keyEntry.data.string.offset)
            let keyLength = Int(keyEntry.data.string.length)

            // Compare key strings
            if keyLength == key.utf8.count {
                let keyMatches = inputBytes.withUnsafeBufferPointer { ptr in
                    key.withCString { cString in
                        memcmp(ptr.baseAddress! + keyOffset, cString, keyLength) == 0
                    }
                }
                if keyMatches {
                    return size_t(valueIndex)
                }
            }
        }

        return Self.notFound
    }

    /// Get entry count.
    var count: size_t {
        return size_t(entries.count)
    }
}

// MARK: - Decoder State

/// Shared state for the map-based decoder.
final class _MapDecoderState {
    let map: _PositionMap
    let userInfo: [CodingUserInfoKey: Any]
    let dateDecodingStrategy: BONJSONDecoder.DateDecodingStrategy
    let dataDecodingStrategy: BONJSONDecoder.DataDecodingStrategy
    let nonConformingFloatDecodingStrategy: BONJSONDecoder.NonConformingFloatDecodingStrategy
    let keyDecodingStrategy: BONJSONDecoder.KeyDecodingStrategy

    init(
        map: _PositionMap,
        userInfo: [CodingUserInfoKey: Any],
        dateDecodingStrategy: BONJSONDecoder.DateDecodingStrategy,
        dataDecodingStrategy: BONJSONDecoder.DataDecodingStrategy,
        nonConformingFloatDecodingStrategy: BONJSONDecoder.NonConformingFloatDecodingStrategy,
        keyDecodingStrategy: BONJSONDecoder.KeyDecodingStrategy
    ) {
        self.map = map
        self.userInfo = userInfo
        self.dateDecodingStrategy = dateDecodingStrategy
        self.dataDecodingStrategy = dataDecodingStrategy
        self.nonConformingFloatDecodingStrategy = nonConformingFloatDecodingStrategy
        self.keyDecodingStrategy = keyDecodingStrategy
    }
}

// MARK: - Map-Based Decoder

/// Internal decoder that implements the Decoder protocol using the position map.
final class _MapDecoder: Decoder {
    let state: _MapDecoderState
    let entryIndex: size_t
    let codingPath: [CodingKey]

    var userInfo: [CodingUserInfoKey: Any] { state.userInfo }

    init(state: _MapDecoderState, entryIndex: size_t, codingPath: [CodingKey]) {
        self.state = state
        self.entryIndex = entryIndex
        self.codingPath = codingPath
    }

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        guard let entry = state.map.getEntry(at: entryIndex) else {
            throw BONJSONDecodingError.unexpectedEndOfData
        }

        guard entry.type == KSBONJSON_TYPE_OBJECT else {
            throw BONJSONDecodingError.typeMismatch(expected: "object", actual: describeType(entry.type))
        }

        let container = _MapKeyedDecodingContainer<Key>(
            state: state,
            objectIndex: entryIndex,
            entry: entry,
            codingPath: codingPath
        )
        return KeyedDecodingContainer(container)
    }

    func unkeyedContainer() throws -> UnkeyedDecodingContainer {
        guard let entry = state.map.getEntry(at: entryIndex) else {
            throw BONJSONDecodingError.unexpectedEndOfData
        }

        guard entry.type == KSBONJSON_TYPE_ARRAY else {
            throw BONJSONDecodingError.typeMismatch(expected: "array", actual: describeType(entry.type))
        }

        return _MapUnkeyedDecodingContainer(
            state: state,
            arrayIndex: entryIndex,
            entry: entry,
            codingPath: codingPath
        )
    }

    func singleValueContainer() throws -> SingleValueDecodingContainer {
        return _MapSingleValueDecodingContainer(
            state: state,
            entryIndex: entryIndex,
            codingPath: codingPath
        )
    }

    // MARK: - Value Reading

    func decodeString() throws -> String {
        guard let entry = state.map.getEntry(at: entryIndex) else {
            throw BONJSONDecodingError.unexpectedEndOfData
        }

        guard entry.type == KSBONJSON_TYPE_STRING else {
            throw BONJSONDecodingError.typeMismatch(expected: "string", actual: describeType(entry.type))
        }

        guard let string = state.map.getString(at: entryIndex) else {
            throw BONJSONDecodingError.invalidUTF8String
        }

        return string
    }

    func decodeInt64() throws -> Int64 {
        guard let entry = state.map.getEntry(at: entryIndex) else {
            throw BONJSONDecodingError.unexpectedEndOfData
        }

        switch entry.type {
        case KSBONJSON_TYPE_INT:
            return entry.data.intValue
        case KSBONJSON_TYPE_UINT:
            let value = entry.data.uintValue
            guard value <= UInt64(Int64.max) else {
                throw BONJSONDecodingError.typeMismatch(expected: "Int64", actual: "UInt64 too large")
            }
            return Int64(value)
        default:
            throw BONJSONDecodingError.typeMismatch(expected: "integer", actual: describeType(entry.type))
        }
    }

    func decodeUInt64() throws -> UInt64 {
        guard let entry = state.map.getEntry(at: entryIndex) else {
            throw BONJSONDecodingError.unexpectedEndOfData
        }

        switch entry.type {
        case KSBONJSON_TYPE_UINT:
            return entry.data.uintValue
        case KSBONJSON_TYPE_INT:
            let value = entry.data.intValue
            guard value >= 0 else {
                throw BONJSONDecodingError.typeMismatch(expected: "UInt64", actual: "negative integer")
            }
            return UInt64(value)
        default:
            throw BONJSONDecodingError.typeMismatch(expected: "unsigned integer", actual: describeType(entry.type))
        }
    }

    func decodeDouble() throws -> Double {
        guard let entry = state.map.getEntry(at: entryIndex) else {
            throw BONJSONDecodingError.unexpectedEndOfData
        }

        switch entry.type {
        case KSBONJSON_TYPE_FLOAT:
            return entry.data.floatValue
        case KSBONJSON_TYPE_INT:
            return Double(entry.data.intValue)
        case KSBONJSON_TYPE_UINT:
            return Double(entry.data.uintValue)
        case KSBONJSON_TYPE_BIGNUMBER:
            // Convert big number to double
            let bn = entry.data.bigNumber
            let significand = Double(bn.significand)
            let result = significand * pow(10.0, Double(bn.exponent))
            return bn.sign < 0 ? -result : result
        default:
            throw BONJSONDecodingError.typeMismatch(expected: "float", actual: describeType(entry.type))
        }
    }

    func decodeBool() throws -> Bool {
        guard let entry = state.map.getEntry(at: entryIndex) else {
            throw BONJSONDecodingError.unexpectedEndOfData
        }

        switch entry.type {
        case KSBONJSON_TYPE_TRUE:
            return true
        case KSBONJSON_TYPE_FALSE:
            return false
        default:
            throw BONJSONDecodingError.typeMismatch(expected: "boolean", actual: describeType(entry.type))
        }
    }

    func decodeNil() -> Bool {
        guard let entry = state.map.getEntry(at: entryIndex) else {
            return false
        }
        return entry.type == KSBONJSON_TYPE_NULL
    }

    func decodeDate() throws -> Date {
        switch state.dateDecodingStrategy {
        case .secondsSince1970:
            let interval = try decodeDouble()
            return Date(timeIntervalSince1970: interval)

        case .millisecondsSince1970:
            let interval = try decodeDouble()
            return Date(timeIntervalSince1970: interval / 1000)

        case .iso8601:
            let string = try decodeString()
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard let date = formatter.date(from: string) else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(codingPath: codingPath, debugDescription: "Invalid ISO 8601 date: \(string)")
                )
            }
            return date

        case .formatted(let formatter):
            let string = try decodeString()
            guard let date = formatter.date(from: string) else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(codingPath: codingPath, debugDescription: "Invalid date: \(string)")
                )
            }
            return date

        case .custom(let closure):
            return try closure(self)
        }
    }

    func decodeData() throws -> Data {
        switch state.dataDecodingStrategy {
        case .base64:
            let string = try decodeString()
            guard let data = Data(base64Encoded: string) else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(codingPath: codingPath, debugDescription: "Invalid Base64 string")
                )
            }
            return data

        case .custom(let closure):
            return try closure(self)
        }
    }

    private func describeType(_ type: KSBONJSONValueType) -> String {
        switch type {
        case KSBONJSON_TYPE_NULL: return "null"
        case KSBONJSON_TYPE_TRUE: return "true"
        case KSBONJSON_TYPE_FALSE: return "false"
        case KSBONJSON_TYPE_INT: return "integer"
        case KSBONJSON_TYPE_UINT: return "unsigned integer"
        case KSBONJSON_TYPE_FLOAT: return "float"
        case KSBONJSON_TYPE_BIGNUMBER: return "big number"
        case KSBONJSON_TYPE_STRING: return "string"
        case KSBONJSON_TYPE_ARRAY: return "array"
        case KSBONJSON_TYPE_OBJECT: return "object"
        default: return "unknown"
        }
    }
}

// MARK: - Keyed Decoding Container

struct _MapKeyedDecodingContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let state: _MapDecoderState
    let objectIndex: size_t
    let entry: KSBONJSONMapEntry
    let codingPath: [CodingKey]

    /// All keys in this object.
    private(set) var allKeys: [Key] = []

    init(state: _MapDecoderState, objectIndex: size_t, entry: KSBONJSONMapEntry, codingPath: [CodingKey]) {
        self.state = state
        self.objectIndex = objectIndex
        self.entry = entry
        self.codingPath = codingPath

        // Build allKeys
        let pairCount = Int(entry.data.container.count) / 2
        for i in 0..<pairCount {
            let keyIndex = state.map.getChild(containerIndex: objectIndex, childIndex: size_t(i * 2))
            if let keyString = state.map.getString(at: keyIndex) {
                let convertedKey = convertKey(keyString)
                if let key = Key(stringValue: convertedKey) {
                    allKeys.append(key)
                }
            }
        }
    }

    private func convertKey(_ key: String) -> String {
        switch state.keyDecodingStrategy {
        case .useDefaultKeys:
            return key
        case .convertFromSnakeCase:
            return key.convertFromSnakeCase()
        case .custom(let converter):
            return converter(codingPath + [_StringKey(stringValue: key)]).stringValue
        }
    }

    /// Find the original key string that matches the given key after conversion.
    private func findOriginalKey(_ key: Key) -> String {
        let pairCount = Int(entry.data.container.count) / 2
        for i in 0..<pairCount {
            let keyIndex = state.map.getChild(containerIndex: objectIndex, childIndex: size_t(i * 2))
            if let keyString = state.map.getString(at: keyIndex) {
                let convertedKey = convertKey(keyString)
                if convertedKey == key.stringValue {
                    return keyString
                }
            }
        }
        return key.stringValue
    }

    func contains(_ key: Key) -> Bool {
        let originalKey = findOriginalKey(key)
        let valueIndex = state.map.findKey(objectIndex: objectIndex, key: originalKey)
        return valueIndex != _PositionMap.notFound
    }

    private func valueIndex(forKey key: Key) throws -> size_t {
        let originalKey = findOriginalKey(key)
        let valueIdx = state.map.findKey(objectIndex: objectIndex, key: originalKey)
        guard valueIdx != _PositionMap.notFound else {
            throw DecodingError.keyNotFound(key, DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "Key '\(key.stringValue)' not found"
            ))
        }
        return valueIdx
    }

    private func decoder(forKey key: Key) throws -> _MapDecoder {
        let idx = try valueIndex(forKey: key)
        return _MapDecoder(state: state, entryIndex: idx, codingPath: codingPath + [key])
    }

    func decodeNil(forKey key: Key) throws -> Bool {
        let idx = try valueIndex(forKey: key)
        guard let entry = state.map.getEntry(at: idx) else {
            return false
        }
        return entry.type == KSBONJSON_TYPE_NULL
    }

    func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool {
        return try decoder(forKey: key).decodeBool()
    }

    func decode(_ type: String.Type, forKey key: Key) throws -> String {
        return try decoder(forKey: key).decodeString()
    }

    func decode(_ type: Double.Type, forKey key: Key) throws -> Double {
        return try decoder(forKey: key).decodeDouble()
    }

    func decode(_ type: Float.Type, forKey key: Key) throws -> Float {
        return Float(try decoder(forKey: key).decodeDouble())
    }

    func decode(_ type: Int.Type, forKey key: Key) throws -> Int {
        return Int(try decoder(forKey: key).decodeInt64())
    }

    func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 {
        return Int8(try decoder(forKey: key).decodeInt64())
    }

    func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 {
        return Int16(try decoder(forKey: key).decodeInt64())
    }

    func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 {
        return Int32(try decoder(forKey: key).decodeInt64())
    }

    func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 {
        return try decoder(forKey: key).decodeInt64()
    }

    func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt {
        return UInt(try decoder(forKey: key).decodeUInt64())
    }

    func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 {
        return UInt8(try decoder(forKey: key).decodeUInt64())
    }

    func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 {
        return UInt16(try decoder(forKey: key).decodeUInt64())
    }

    func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 {
        return UInt32(try decoder(forKey: key).decodeUInt64())
    }

    func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 {
        return try decoder(forKey: key).decodeUInt64()
    }

    func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
        let dec = try decoder(forKey: key)

        // Handle special types
        if type == Date.self {
            return try dec.decodeDate() as! T
        }
        if type == Data.self {
            return try dec.decodeData() as! T
        }
        if type == URL.self {
            let string = try dec.decodeString()
            guard let url = URL(string: string) else {
                throw BONJSONDecodingError.invalidURL(string)
            }
            return url as! T
        }

        return try T(from: dec)
    }

    func nestedContainer<NestedKey: CodingKey>(
        keyedBy type: NestedKey.Type,
        forKey key: Key
    ) throws -> KeyedDecodingContainer<NestedKey> {
        return try decoder(forKey: key).container(keyedBy: type)
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> UnkeyedDecodingContainer {
        return try decoder(forKey: key).unkeyedContainer()
    }

    func superDecoder() throws -> Decoder {
        return try superDecoder(forKey: Key(stringValue: "super")!)
    }

    func superDecoder(forKey key: Key) throws -> Decoder {
        return try decoder(forKey: key)
    }
}

// MARK: - Unkeyed Decoding Container

struct _MapUnkeyedDecodingContainer: UnkeyedDecodingContainer {
    let state: _MapDecoderState
    let arrayIndex: size_t
    let entry: KSBONJSONMapEntry
    let codingPath: [CodingKey]

    private(set) var currentIndex: Int = 0

    var count: Int? { Int(entry.data.container.count) }

    var isAtEnd: Bool {
        return currentIndex >= Int(entry.data.container.count)
    }

    init(state: _MapDecoderState, arrayIndex: size_t, entry: KSBONJSONMapEntry, codingPath: [CodingKey]) {
        self.state = state
        self.arrayIndex = arrayIndex
        self.entry = entry
        self.codingPath = codingPath
    }

    private mutating func nextDecoder() throws -> _MapDecoder {
        guard !isAtEnd else {
            throw DecodingError.valueNotFound(Any.self, DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "Unkeyed container is at end"
            ))
        }

        let childIndex = state.map.getChild(containerIndex: arrayIndex, childIndex: size_t(currentIndex))
        let decoder = _MapDecoder(
            state: state,
            entryIndex: childIndex,
            codingPath: codingPath + [_BONJSONIndexKey(index: currentIndex)]
        )
        currentIndex += 1
        return decoder
    }

    mutating func decodeNil() throws -> Bool {
        guard !isAtEnd else { return false }
        let childIndex = state.map.getChild(containerIndex: arrayIndex, childIndex: size_t(currentIndex))
        guard let entry = state.map.getEntry(at: childIndex) else {
            return false
        }
        if entry.type == KSBONJSON_TYPE_NULL {
            currentIndex += 1
            return true
        }
        return false
    }

    mutating func decode(_ type: Bool.Type) throws -> Bool {
        return try nextDecoder().decodeBool()
    }

    mutating func decode(_ type: String.Type) throws -> String {
        return try nextDecoder().decodeString()
    }

    mutating func decode(_ type: Double.Type) throws -> Double {
        return try nextDecoder().decodeDouble()
    }

    mutating func decode(_ type: Float.Type) throws -> Float {
        return Float(try nextDecoder().decodeDouble())
    }

    mutating func decode(_ type: Int.Type) throws -> Int {
        return Int(try nextDecoder().decodeInt64())
    }

    mutating func decode(_ type: Int8.Type) throws -> Int8 {
        return Int8(try nextDecoder().decodeInt64())
    }

    mutating func decode(_ type: Int16.Type) throws -> Int16 {
        return Int16(try nextDecoder().decodeInt64())
    }

    mutating func decode(_ type: Int32.Type) throws -> Int32 {
        return Int32(try nextDecoder().decodeInt64())
    }

    mutating func decode(_ type: Int64.Type) throws -> Int64 {
        return try nextDecoder().decodeInt64()
    }

    mutating func decode(_ type: UInt.Type) throws -> UInt {
        return UInt(try nextDecoder().decodeUInt64())
    }

    mutating func decode(_ type: UInt8.Type) throws -> UInt8 {
        return UInt8(try nextDecoder().decodeUInt64())
    }

    mutating func decode(_ type: UInt16.Type) throws -> UInt16 {
        return UInt16(try nextDecoder().decodeUInt64())
    }

    mutating func decode(_ type: UInt32.Type) throws -> UInt32 {
        return UInt32(try nextDecoder().decodeUInt64())
    }

    mutating func decode(_ type: UInt64.Type) throws -> UInt64 {
        return try nextDecoder().decodeUInt64()
    }

    mutating func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let decoder = try nextDecoder()

        if type == Date.self {
            return try decoder.decodeDate() as! T
        }
        if type == Data.self {
            return try decoder.decodeData() as! T
        }
        if type == URL.self {
            let string = try decoder.decodeString()
            guard let url = URL(string: string) else {
                throw BONJSONDecodingError.invalidURL(string)
            }
            return url as! T
        }

        return try T(from: decoder)
    }

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy type: NestedKey.Type
    ) throws -> KeyedDecodingContainer<NestedKey> {
        return try nextDecoder().container(keyedBy: type)
    }

    mutating func nestedUnkeyedContainer() throws -> UnkeyedDecodingContainer {
        return try nextDecoder().unkeyedContainer()
    }

    mutating func superDecoder() throws -> Decoder {
        return try nextDecoder()
    }
}

// MARK: - Single Value Decoding Container

struct _MapSingleValueDecodingContainer: SingleValueDecodingContainer {
    let state: _MapDecoderState
    let entryIndex: size_t
    let codingPath: [CodingKey]

    init(state: _MapDecoderState, entryIndex: size_t, codingPath: [CodingKey]) {
        self.state = state
        self.entryIndex = entryIndex
        self.codingPath = codingPath
    }

    private func makeDecoder() -> _MapDecoder {
        return _MapDecoder(state: state, entryIndex: entryIndex, codingPath: codingPath)
    }

    func decodeNil() -> Bool {
        return makeDecoder().decodeNil()
    }

    func decode(_ type: Bool.Type) throws -> Bool {
        return try makeDecoder().decodeBool()
    }

    func decode(_ type: String.Type) throws -> String {
        return try makeDecoder().decodeString()
    }

    func decode(_ type: Double.Type) throws -> Double {
        return try makeDecoder().decodeDouble()
    }

    func decode(_ type: Float.Type) throws -> Float {
        return Float(try makeDecoder().decodeDouble())
    }

    func decode(_ type: Int.Type) throws -> Int {
        return Int(try makeDecoder().decodeInt64())
    }

    func decode(_ type: Int8.Type) throws -> Int8 {
        return Int8(try makeDecoder().decodeInt64())
    }

    func decode(_ type: Int16.Type) throws -> Int16 {
        return Int16(try makeDecoder().decodeInt64())
    }

    func decode(_ type: Int32.Type) throws -> Int32 {
        return Int32(try makeDecoder().decodeInt64())
    }

    func decode(_ type: Int64.Type) throws -> Int64 {
        return try makeDecoder().decodeInt64()
    }

    func decode(_ type: UInt.Type) throws -> UInt {
        return UInt(try makeDecoder().decodeUInt64())
    }

    func decode(_ type: UInt8.Type) throws -> UInt8 {
        return UInt8(try makeDecoder().decodeUInt64())
    }

    func decode(_ type: UInt16.Type) throws -> UInt16 {
        return UInt16(try makeDecoder().decodeUInt64())
    }

    func decode(_ type: UInt32.Type) throws -> UInt32 {
        return UInt32(try makeDecoder().decodeUInt64())
    }

    func decode(_ type: UInt64.Type) throws -> UInt64 {
        return try makeDecoder().decodeUInt64()
    }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let decoder = makeDecoder()

        if type == Date.self {
            return try decoder.decodeDate() as! T
        }
        if type == Data.self {
            return try decoder.decodeData() as! T
        }
        if type == URL.self {
            let string = try decoder.decodeString()
            guard let url = URL(string: string) else {
                throw BONJSONDecodingError.invalidURL(string)
            }
            return url as! T
        }

        return try T(from: decoder)
    }
}

// MARK: - Helper CodingKey Types

/// A simple CodingKey for string keys.
struct _StringKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

// _BONJSONIndexKey is defined in BONJSONEncoder.swift

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
