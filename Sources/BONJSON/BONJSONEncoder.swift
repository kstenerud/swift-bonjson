// ABOUTME: Public BONJSONEncoder API matching Apple's JSONEncoder interface.
// ABOUTME: Uses the buffer-based C API for high-performance direct buffer encoding.

import Foundation
import CKSBonjson

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
        let state = _BufferEncoderState(
            userInfo: userInfo,
            dateEncodingStrategy: dateEncodingStrategy,
            dataEncodingStrategy: dataEncodingStrategy,
            nonConformingFloatEncodingStrategy: nonConformingFloatEncodingStrategy,
            keyEncodingStrategy: keyEncodingStrategy
        )

        // Fast path for primitive arrays
        if let intArray = value as? [Int] {
            try state.encodeBatchInt64Array(intArray)
        } else if let int64Array = value as? [Int64] {
            try state.encodeBatchInt64Array(int64Array)
        } else if let doubleArray = value as? [Double] {
            try state.encodeBatchDoubleArray(doubleArray)
        } else if let stringArray = value as? [String] {
            try state.encodeBatchStringArray(stringArray)
        } else {
            // Default path through Codable
            let encoder = _BufferEncoder(state: state, codingPath: [])
            try encoder.encodeValue(value)
        }

        // Close all remaining containers and finalize
        try state.finalize()

        return Data(state.buffer[0..<state.bytesWritten])
    }
}

// MARK: - Errors

/// Errors that can occur during BONJSON encoding.
public enum BONJSONEncodingError: Error, CustomStringConvertible {
    case invalidFloat(Double)
    case encodingFailed(String)
    case internalError(String)

    public var description: String {
        switch self {
        case .invalidFloat(let value):
            return "Cannot encode non-conforming float value: \(value)"
        case .encodingFailed(let message):
            return "Encoding failed: \(message)"
        case .internalError(let message):
            return "Internal error: \(message)"
        }
    }
}

// MARK: - Buffer-Based Encoder State

/// Shared mutable state for the buffer-based encoder.
/// Manages the buffer and C context directly for optimal performance.
final class _BufferEncoderState {
    /// The encoding buffer - Swift-managed, passed to C for direct writes.
    var buffer: [UInt8]

    /// The C encoder context.
    var context: KSBONJSONBufferEncodeContext

    /// Number of bytes written so far.
    var bytesWritten: Int {
        return Int(context.position)
    }

    let userInfo: [CodingUserInfoKey: Any]
    let dateEncodingStrategy: BONJSONEncoder.DateEncodingStrategy
    let dataEncodingStrategy: BONJSONEncoder.DataEncodingStrategy
    let nonConformingFloatEncodingStrategy: BONJSONEncoder.NonConformingFloatEncodingStrategy
    let keyEncodingStrategy: BONJSONEncoder.KeyEncodingStrategy

    /// Initial buffer size.
    private static let initialCapacity = 256

    init(
        userInfo: [CodingUserInfoKey: Any],
        dateEncodingStrategy: BONJSONEncoder.DateEncodingStrategy,
        dataEncodingStrategy: BONJSONEncoder.DataEncodingStrategy,
        nonConformingFloatEncodingStrategy: BONJSONEncoder.NonConformingFloatEncodingStrategy,
        keyEncodingStrategy: BONJSONEncoder.KeyEncodingStrategy
    ) {
        self.userInfo = userInfo
        self.dateEncodingStrategy = dateEncodingStrategy
        self.dataEncodingStrategy = dataEncodingStrategy
        self.nonConformingFloatEncodingStrategy = nonConformingFloatEncodingStrategy
        self.keyEncodingStrategy = keyEncodingStrategy

        self.buffer = [UInt8](repeating: 0, count: Self.initialCapacity)
        self.context = KSBONJSONBufferEncodeContext()

        // Initialize the buffer-based encoder
        buffer.withUnsafeMutableBufferPointer { bufferPtr in
            ksbonjson_encodeToBuffer_begin(
                &context,
                bufferPtr.baseAddress,
                bufferPtr.count
            )
        }
    }

    /// Current container depth.
    var currentDepth: Int {
        return Int(ksbonjson_encodeToBuffer_getDepth(&context))
    }

    /// Ensure buffer has enough capacity for the given additional bytes.
    @inline(__always)
    func ensureCapacity(_ additionalBytes: Int) {
        let required = bytesWritten + additionalBytes
        guard required > buffer.count else { return }
        growBuffer(to: required)
    }

    /// Grow buffer to at least the required size (slow path, not inlined).
    private func growBuffer(to required: Int) {
        // Grow buffer exponentially
        var newCapacity = buffer.count
        while newCapacity < required {
            newCapacity *= 2
        }

        buffer.reserveCapacity(newCapacity)
        buffer.append(contentsOf: repeatElement(0, count: newCapacity - buffer.count))

        // Update the C context with new buffer pointer
        buffer.withUnsafeMutableBufferPointer { bufferPtr in
            ksbonjson_encodeToBuffer_setBuffer(
                &context,
                bufferPtr.baseAddress,
                bufferPtr.count
            )
        }
    }

    /// Close containers until we reach the target depth.
    func closeContainersToDepth(_ targetDepth: Int) throws {
        while currentDepth > targetDepth {
            ensureCapacity(Int(ksbonjson_maxEncodedSize_containerEnd()))
            let result = ksbonjson_encodeToBuffer_endContainer(&context)
            if result < 0 {
                throw BONJSONEncodingError.encodingFailed(
                    ksbonjson_describeEncodeStatus(ksbonjson_encodeStatus(rawValue: UInt32(-result))).map { String(cString: $0) } ?? "Unknown error"
                )
            }
        }
    }

    /// Finalize encoding - close all containers and end the document.
    func finalize() throws {
        // Close all open containers
        ensureCapacity(Int(ksbonjson_maxEncodedSize_containerEnd()) * (currentDepth + 1))
        let closeResult = ksbonjson_encodeToBuffer_endAllContainers(&context)
        if closeResult < 0 {
            throw BONJSONEncodingError.encodingFailed(
                ksbonjson_describeEncodeStatus(ksbonjson_encodeStatus(rawValue: UInt32(-closeResult))).map { String(cString: $0) } ?? "Unknown error"
            )
        }

        let endResult = ksbonjson_encodeToBuffer_end(&context)
        if endResult < 0 {
            throw BONJSONEncodingError.encodingFailed(
                ksbonjson_describeEncodeStatus(ksbonjson_encodeStatus(rawValue: UInt32(-endResult))).map { String(cString: $0) } ?? "Unknown error"
            )
        }
    }

    /// Batch encode an array of Int values.
    func encodeBatchInt64Array(_ values: [Int]) throws {
        ensureCapacity(Int(ksbonjson_maxEncodedSize_int64Array(values.count)))
        let result = values.withUnsafeBufferPointer { ptr in
            // Convert Int to Int64 pointer - safe on 64-bit platforms
            ptr.baseAddress!.withMemoryRebound(to: Int64.self, capacity: values.count) { int64Ptr in
                ksbonjson_encodeToBuffer_int64Array(&context, int64Ptr, values.count)
            }
        }
        if result < 0 {
            throw BONJSONEncodingError.encodingFailed(
                ksbonjson_describeEncodeStatus(ksbonjson_encodeStatus(rawValue: UInt32(-result))).map { String(cString: $0) } ?? "Unknown error"
            )
        }
    }

    /// Batch encode an array of Int64 values.
    func encodeBatchInt64Array(_ values: [Int64]) throws {
        ensureCapacity(Int(ksbonjson_maxEncodedSize_int64Array(values.count)))
        let result = values.withUnsafeBufferPointer { ptr in
            ksbonjson_encodeToBuffer_int64Array(&context, ptr.baseAddress, values.count)
        }
        if result < 0 {
            throw BONJSONEncodingError.encodingFailed(
                ksbonjson_describeEncodeStatus(ksbonjson_encodeStatus(rawValue: UInt32(-result))).map { String(cString: $0) } ?? "Unknown error"
            )
        }
    }

    /// Batch encode an array of Double values.
    func encodeBatchDoubleArray(_ values: [Double]) throws {
        ensureCapacity(Int(ksbonjson_maxEncodedSize_doubleArray(values.count)))
        let result = values.withUnsafeBufferPointer { ptr in
            ksbonjson_encodeToBuffer_doubleArray(&context, ptr.baseAddress, values.count)
        }
        if result < 0 {
            throw BONJSONEncodingError.encodingFailed(
                ksbonjson_describeEncodeStatus(ksbonjson_encodeStatus(rawValue: UInt32(-result))).map { String(cString: $0) } ?? "Unknown error"
            )
        }
    }

    /// Batch encode an array of String values.
    func encodeBatchStringArray(_ values: [String]) throws {
        // Calculate total UTF-8 length for capacity estimation
        var totalLength = 0
        for str in values {
            totalLength += str.utf8.count
        }

        ensureCapacity(Int(ksbonjson_maxEncodedSize_stringArray(values.count, totalLength)))

        // Convert strings to contiguous UTF-8 data and track offsets
        var utf8Data = [UInt8]()
        utf8Data.reserveCapacity(totalLength)
        var lengths = [Int]()
        lengths.reserveCapacity(values.count)

        for str in values {
            let utf8 = Array(str.utf8)
            lengths.append(utf8.count)
            utf8Data.append(contentsOf: utf8)
        }

        // Build array of pointers into the contiguous buffer
        let result = utf8Data.withUnsafeBufferPointer { dataPtr in
            var stringPtrs = [UnsafePointer<CChar>?]()
            stringPtrs.reserveCapacity(values.count)

            var offset = 0
            for length in lengths {
                if length == 0 {
                    // Empty string - use a valid empty pointer
                    stringPtrs.append(UnsafePointer<CChar>(bitPattern: 1))
                } else {
                    stringPtrs.append(UnsafeRawPointer(dataPtr.baseAddress! + offset).assumingMemoryBound(to: CChar.self))
                }
                offset += length
            }

            return stringPtrs.withUnsafeBufferPointer { ptrsPtr in
                lengths.withUnsafeBufferPointer { lengthsPtr in
                    ksbonjson_encodeToBuffer_stringArray(
                        &context,
                        ptrsPtr.baseAddress,
                        lengthsPtr.baseAddress,
                        values.count
                    )
                }
            }
        }

        if result < 0 {
            throw BONJSONEncodingError.encodingFailed(
                ksbonjson_describeEncodeStatus(ksbonjson_encodeStatus(rawValue: UInt32(-result))).map { String(cString: $0) } ?? "Unknown error"
            )
        }
    }
}

// MARK: - Buffer-Based Encoder

/// Internal encoder that implements the Encoder protocol using buffer-based C calls.
final class _BufferEncoder: Encoder {
    let state: _BufferEncoderState
    let codingPath: [CodingKey]

    var userInfo: [CodingUserInfoKey: Any] { state.userInfo }

    init(state: _BufferEncoderState, codingPath: [CodingKey]) {
        self.state = state
        self.codingPath = codingPath
    }

    func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
        let container = _BufferKeyedEncodingContainer<Key>(
            state: state,
            codingPath: codingPath
        )
        return KeyedEncodingContainer(container)
    }

    func unkeyedContainer() -> UnkeyedEncodingContainer {
        return _BufferUnkeyedEncodingContainer(
            state: state,
            codingPath: codingPath
        )
    }

    func singleValueContainer() -> SingleValueEncodingContainer {
        return _BufferSingleValueEncodingContainer(
            state: state,
            codingPath: codingPath
        )
    }

    /// Encodes a value, handling special types.
    func encodeValue<T: Encodable>(_ value: T) throws {
        // Handle special types
        if let date = value as? Date {
            try encodeDate(date)
            return
        }

        if let data = value as? Data {
            try encodeData(data)
            return
        }

        if let url = value as? URL {
            try encodeString(url.absoluteString)
            return
        }

        // Default encoding
        try value.encode(to: self)
    }

    /// Encodes a Date using the configured strategy.
    private func encodeDate(_ date: Date) throws {
        switch state.dateEncodingStrategy {
        case .secondsSince1970:
            try encodeFloat(date.timeIntervalSince1970)

        case .millisecondsSince1970:
            try encodeFloat(date.timeIntervalSince1970 * 1000)

        case .iso8601:
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            try encodeString(formatter.string(from: date))

        case .formatted(let formatter):
            try encodeString(formatter.string(from: date))

        case .custom(let closure):
            try closure(date, self)
        }
    }

    /// Encodes Data using the configured strategy.
    private func encodeData(_ data: Data) throws {
        switch state.dataEncodingStrategy {
        case .base64:
            try encodeString(data.base64EncodedString())

        case .custom(let closure):
            try closure(data, self)
        }
    }

    @inline(__always)
    func encodeString(_ value: String) throws {
        let utf8Count = value.utf8.count
        state.ensureCapacity(Int(ksbonjson_maxEncodedSize_string(utf8Count)))

        let result = value.withCString { cString in
            ksbonjson_encodeToBuffer_string(&state.context, cString, strlen(cString))
        }
        if result < 0 {
            throw BONJSONEncodingError.encodingFailed(
                ksbonjson_describeEncodeStatus(ksbonjson_encodeStatus(rawValue: UInt32(-result))).map { String(cString: $0) } ?? "Unknown error"
            )
        }
    }

    @inline(__always)
    func encodeFloat(_ value: Double) throws {
        // Fast path for finite values
        if value.isFinite {
            state.ensureCapacity(Int(ksbonjson_maxEncodedSize_float()))
            let result = ksbonjson_encodeToBuffer_float(&state.context, value)
            if result < 0 {
                throw BONJSONEncodingError.encodingFailed(
                    ksbonjson_describeEncodeStatus(ksbonjson_encodeStatus(rawValue: UInt32(-result))).map { String(cString: $0) } ?? "Unknown error"
                )
            }
            return
        }

        // Slow path for non-finite values
        switch state.nonConformingFloatEncodingStrategy {
        case .throw:
            throw BONJSONEncodingError.invalidFloat(value)
        case .convertToString(let posInf, let negInf, let nan):
            if value.isNaN {
                try encodeString(nan)
            } else if value == .infinity {
                try encodeString(posInf)
            } else {
                try encodeString(negInf)
            }
        }
    }

    /// Converts a key according to the key encoding strategy.
    func convertedKey(_ key: CodingKey) -> String {
        switch state.keyEncodingStrategy {
        case .useDefaultKeys:
            return key.stringValue
        case .convertToSnakeCase:
            return key.stringValue.convertToSnakeCase()
        case .custom(let converter):
            return converter(codingPath + [key]).stringValue
        }
    }
}

// MARK: - Keyed Encoding Container

struct _BufferKeyedEncodingContainer<Key: CodingKey>: KeyedEncodingContainerProtocol {
    let state: _BufferEncoderState
    let codingPath: [CodingKey]

    /// The depth when this container was created.
    let containerDepth: Int

    init(state: _BufferEncoderState, codingPath: [CodingKey]) {
        self.state = state
        self.codingPath = codingPath

        // Begin object
        state.ensureCapacity(Int(ksbonjson_maxEncodedSize_containerBegin()))
        let result = ksbonjson_encodeToBuffer_beginObject(&state.context)
        assert(result >= 0, "Failed to begin object")

        self.containerDepth = state.currentDepth
    }

    /// Ensures we're at the right depth before encoding a value.
    private func prepareToEncode() throws {
        try state.closeContainersToDepth(containerDepth)
    }

    private func encodeKey(_ key: Key) throws {
        let keyString = convertedKey(key)
        let utf8Count = keyString.utf8.count
        state.ensureCapacity(Int(ksbonjson_maxEncodedSize_string(utf8Count)))

        let result = keyString.withCString { cString in
            ksbonjson_encodeToBuffer_string(&state.context, cString, strlen(cString))
        }
        if result < 0 {
            throw BONJSONEncodingError.encodingFailed(
                ksbonjson_describeEncodeStatus(ksbonjson_encodeStatus(rawValue: UInt32(-result))).map { String(cString: $0) } ?? "Unknown error"
            )
        }
    }

    func convertedKey(_ key: Key) -> String {
        switch state.keyEncodingStrategy {
        case .useDefaultKeys:
            return key.stringValue
        case .convertToSnakeCase:
            return key.stringValue.convertToSnakeCase()
        case .custom(let converter):
            return converter(codingPath + [key]).stringValue
        }
    }

    mutating func encodeNil(forKey key: Key) throws {
        try prepareToEncode()
        try encodeKey(key)
        state.ensureCapacity(Int(ksbonjson_maxEncodedSize_null()))
        let result = ksbonjson_encodeToBuffer_null(&state.context)
        if result < 0 {
            throw BONJSONEncodingError.encodingFailed(
                ksbonjson_describeEncodeStatus(ksbonjson_encodeStatus(rawValue: UInt32(-result))).map { String(cString: $0) } ?? "Unknown error"
            )
        }
    }

    mutating func encode(_ value: Bool, forKey key: Key) throws {
        try prepareToEncode()
        try encodeKey(key)
        state.ensureCapacity(Int(ksbonjson_maxEncodedSize_bool()))
        let result = ksbonjson_encodeToBuffer_bool(&state.context, value)
        if result < 0 {
            throw BONJSONEncodingError.encodingFailed(
                ksbonjson_describeEncodeStatus(ksbonjson_encodeStatus(rawValue: UInt32(-result))).map { String(cString: $0) } ?? "Unknown error"
            )
        }
    }

    mutating func encode(_ value: String, forKey key: Key) throws {
        try prepareToEncode()
        try encodeKey(key)
        let utf8Count = value.utf8.count
        state.ensureCapacity(Int(ksbonjson_maxEncodedSize_string(utf8Count)))

        let result = value.withCString { cString in
            ksbonjson_encodeToBuffer_string(&state.context, cString, strlen(cString))
        }
        if result < 0 {
            throw BONJSONEncodingError.encodingFailed(
                ksbonjson_describeEncodeStatus(ksbonjson_encodeStatus(rawValue: UInt32(-result))).map { String(cString: $0) } ?? "Unknown error"
            )
        }
    }

    mutating func encode(_ value: Double, forKey key: Key) throws {
        try prepareToEncode()
        try encodeKey(key)
        let encoder = _BufferEncoder(state: state, codingPath: codingPath + [key])
        try encoder.encodeFloat(value)
    }

    mutating func encode(_ value: Float, forKey key: Key) throws {
        try encode(Double(value), forKey: key)
    }

    mutating func encode(_ value: Int, forKey key: Key) throws {
        try prepareToEncode()
        try encodeKey(key)
        state.ensureCapacity(Int(ksbonjson_maxEncodedSize_int()))
        let result = ksbonjson_encodeToBuffer_int(&state.context, Int64(value))
        if result < 0 {
            throw BONJSONEncodingError.encodingFailed(
                ksbonjson_describeEncodeStatus(ksbonjson_encodeStatus(rawValue: UInt32(-result))).map { String(cString: $0) } ?? "Unknown error"
            )
        }
    }

    mutating func encode(_ value: Int8, forKey key: Key) throws {
        try prepareToEncode()
        try encodeKey(key)
        state.ensureCapacity(Int(ksbonjson_maxEncodedSize_int()))
        let result = ksbonjson_encodeToBuffer_int(&state.context, Int64(value))
        if result < 0 {
            throw BONJSONEncodingError.encodingFailed(
                ksbonjson_describeEncodeStatus(ksbonjson_encodeStatus(rawValue: UInt32(-result))).map { String(cString: $0) } ?? "Unknown error"
            )
        }
    }

    mutating func encode(_ value: Int16, forKey key: Key) throws {
        try prepareToEncode()
        try encodeKey(key)
        state.ensureCapacity(Int(ksbonjson_maxEncodedSize_int()))
        let result = ksbonjson_encodeToBuffer_int(&state.context, Int64(value))
        if result < 0 {
            throw BONJSONEncodingError.encodingFailed(
                ksbonjson_describeEncodeStatus(ksbonjson_encodeStatus(rawValue: UInt32(-result))).map { String(cString: $0) } ?? "Unknown error"
            )
        }
    }

    mutating func encode(_ value: Int32, forKey key: Key) throws {
        try prepareToEncode()
        try encodeKey(key)
        state.ensureCapacity(Int(ksbonjson_maxEncodedSize_int()))
        let result = ksbonjson_encodeToBuffer_int(&state.context, Int64(value))
        if result < 0 {
            throw BONJSONEncodingError.encodingFailed(
                ksbonjson_describeEncodeStatus(ksbonjson_encodeStatus(rawValue: UInt32(-result))).map { String(cString: $0) } ?? "Unknown error"
            )
        }
    }

    mutating func encode(_ value: Int64, forKey key: Key) throws {
        try prepareToEncode()
        try encodeKey(key)
        state.ensureCapacity(Int(ksbonjson_maxEncodedSize_int()))
        let result = ksbonjson_encodeToBuffer_int(&state.context, value)
        if result < 0 {
            throw BONJSONEncodingError.encodingFailed(
                ksbonjson_describeEncodeStatus(ksbonjson_encodeStatus(rawValue: UInt32(-result))).map { String(cString: $0) } ?? "Unknown error"
            )
        }
    }

    mutating func encode(_ value: UInt, forKey key: Key) throws {
        try prepareToEncode()
        try encodeKey(key)
        state.ensureCapacity(Int(ksbonjson_maxEncodedSize_int()))
        let result = ksbonjson_encodeToBuffer_uint(&state.context, UInt64(value))
        if result < 0 {
            throw BONJSONEncodingError.encodingFailed(
                ksbonjson_describeEncodeStatus(ksbonjson_encodeStatus(rawValue: UInt32(-result))).map { String(cString: $0) } ?? "Unknown error"
            )
        }
    }

    mutating func encode(_ value: UInt8, forKey key: Key) throws {
        try prepareToEncode()
        try encodeKey(key)
        state.ensureCapacity(Int(ksbonjson_maxEncodedSize_int()))
        let result = ksbonjson_encodeToBuffer_uint(&state.context, UInt64(value))
        if result < 0 {
            throw BONJSONEncodingError.encodingFailed(
                ksbonjson_describeEncodeStatus(ksbonjson_encodeStatus(rawValue: UInt32(-result))).map { String(cString: $0) } ?? "Unknown error"
            )
        }
    }

    mutating func encode(_ value: UInt16, forKey key: Key) throws {
        try prepareToEncode()
        try encodeKey(key)
        state.ensureCapacity(Int(ksbonjson_maxEncodedSize_int()))
        let result = ksbonjson_encodeToBuffer_uint(&state.context, UInt64(value))
        if result < 0 {
            throw BONJSONEncodingError.encodingFailed(
                ksbonjson_describeEncodeStatus(ksbonjson_encodeStatus(rawValue: UInt32(-result))).map { String(cString: $0) } ?? "Unknown error"
            )
        }
    }

    mutating func encode(_ value: UInt32, forKey key: Key) throws {
        try prepareToEncode()
        try encodeKey(key)
        state.ensureCapacity(Int(ksbonjson_maxEncodedSize_int()))
        let result = ksbonjson_encodeToBuffer_uint(&state.context, UInt64(value))
        if result < 0 {
            throw BONJSONEncodingError.encodingFailed(
                ksbonjson_describeEncodeStatus(ksbonjson_encodeStatus(rawValue: UInt32(-result))).map { String(cString: $0) } ?? "Unknown error"
            )
        }
    }

    mutating func encode(_ value: UInt64, forKey key: Key) throws {
        try prepareToEncode()
        try encodeKey(key)
        state.ensureCapacity(Int(ksbonjson_maxEncodedSize_int()))
        let result = ksbonjson_encodeToBuffer_uint(&state.context, value)
        if result < 0 {
            throw BONJSONEncodingError.encodingFailed(
                ksbonjson_describeEncodeStatus(ksbonjson_encodeStatus(rawValue: UInt32(-result))).map { String(cString: $0) } ?? "Unknown error"
            )
        }
    }

    mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws {
        try prepareToEncode()
        try encodeKey(key)
        let encoder = _BufferEncoder(state: state, codingPath: codingPath + [key])
        try encoder.encodeValue(value)
    }

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy keyType: NestedKey.Type,
        forKey key: Key
    ) -> KeyedEncodingContainer<NestedKey> {
        do {
            try prepareToEncode()
            try encodeKey(key)
        } catch {
            assertionFailure("Failed to prepare nested container: \(error)")
        }

        let container = _BufferKeyedEncodingContainer<NestedKey>(
            state: state,
            codingPath: codingPath + [key]
        )
        return KeyedEncodingContainer(container)
    }

    mutating func nestedUnkeyedContainer(forKey key: Key) -> UnkeyedEncodingContainer {
        do {
            try prepareToEncode()
            try encodeKey(key)
        } catch {
            assertionFailure("Failed to prepare nested container: \(error)")
        }

        return _BufferUnkeyedEncodingContainer(
            state: state,
            codingPath: codingPath + [key]
        )
    }

    mutating func superEncoder() -> Encoder {
        return superEncoder(forKey: Key(stringValue: "super")!)
    }

    mutating func superEncoder(forKey key: Key) -> Encoder {
        do {
            try prepareToEncode()
            try encodeKey(key)
        } catch {
            assertionFailure("Failed to prepare super encoder: \(error)")
        }

        return _BufferEncoder(state: state, codingPath: codingPath + [key])
    }
}

// MARK: - Unkeyed Encoding Container

struct _BufferUnkeyedEncodingContainer: UnkeyedEncodingContainer {
    let state: _BufferEncoderState
    let codingPath: [CodingKey]

    /// The depth when this container was created.
    let containerDepth: Int

    private(set) var count: Int = 0

    init(state: _BufferEncoderState, codingPath: [CodingKey]) {
        self.state = state
        self.codingPath = codingPath

        // Begin array
        state.ensureCapacity(Int(ksbonjson_maxEncodedSize_containerBegin()))
        let result = ksbonjson_encodeToBuffer_beginArray(&state.context)
        assert(result >= 0, "Failed to begin array")

        self.containerDepth = state.currentDepth
    }

    /// Ensures we're at the right depth before encoding a value.
    private mutating func prepareToEncode() throws {
        try state.closeContainersToDepth(containerDepth)
        count += 1
    }

    mutating func encodeNil() throws {
        try prepareToEncode()
        state.ensureCapacity(Int(ksbonjson_maxEncodedSize_null()))
        let result = ksbonjson_encodeToBuffer_null(&state.context)
        if result < 0 {
            throw BONJSONEncodingError.encodingFailed(
                ksbonjson_describeEncodeStatus(ksbonjson_encodeStatus(rawValue: UInt32(-result))).map { String(cString: $0) } ?? "Unknown error"
            )
        }
    }

    mutating func encode(_ value: Bool) throws {
        try prepareToEncode()
        state.ensureCapacity(Int(ksbonjson_maxEncodedSize_bool()))
        let result = ksbonjson_encodeToBuffer_bool(&state.context, value)
        if result < 0 {
            throw BONJSONEncodingError.encodingFailed(
                ksbonjson_describeEncodeStatus(ksbonjson_encodeStatus(rawValue: UInt32(-result))).map { String(cString: $0) } ?? "Unknown error"
            )
        }
    }

    mutating func encode(_ value: String) throws {
        try prepareToEncode()
        let utf8Count = value.utf8.count
        state.ensureCapacity(Int(ksbonjson_maxEncodedSize_string(utf8Count)))

        let result = value.withCString { cString in
            ksbonjson_encodeToBuffer_string(&state.context, cString, strlen(cString))
        }
        if result < 0 {
            throw BONJSONEncodingError.encodingFailed(
                ksbonjson_describeEncodeStatus(ksbonjson_encodeStatus(rawValue: UInt32(-result))).map { String(cString: $0) } ?? "Unknown error"
            )
        }
    }

    mutating func encode(_ value: Double) throws {
        try prepareToEncode()
        let encoder = _BufferEncoder(state: state, codingPath: codingPath + [_BONJSONIndexKey(index: count - 1)])
        try encoder.encodeFloat(value)
    }

    mutating func encode(_ value: Float) throws {
        try encode(Double(value))
    }

    mutating func encode(_ value: Int) throws {
        try prepareToEncode()
        state.ensureCapacity(Int(ksbonjson_maxEncodedSize_int()))
        let result = ksbonjson_encodeToBuffer_int(&state.context, Int64(value))
        if result < 0 {
            throw BONJSONEncodingError.encodingFailed(
                ksbonjson_describeEncodeStatus(ksbonjson_encodeStatus(rawValue: UInt32(-result))).map { String(cString: $0) } ?? "Unknown error"
            )
        }
    }

    mutating func encode(_ value: Int8) throws {
        try prepareToEncode()
        state.ensureCapacity(Int(ksbonjson_maxEncodedSize_int()))
        let result = ksbonjson_encodeToBuffer_int(&state.context, Int64(value))
        if result < 0 {
            throw BONJSONEncodingError.encodingFailed(
                ksbonjson_describeEncodeStatus(ksbonjson_encodeStatus(rawValue: UInt32(-result))).map { String(cString: $0) } ?? "Unknown error"
            )
        }
    }

    mutating func encode(_ value: Int16) throws {
        try prepareToEncode()
        state.ensureCapacity(Int(ksbonjson_maxEncodedSize_int()))
        let result = ksbonjson_encodeToBuffer_int(&state.context, Int64(value))
        if result < 0 {
            throw BONJSONEncodingError.encodingFailed(
                ksbonjson_describeEncodeStatus(ksbonjson_encodeStatus(rawValue: UInt32(-result))).map { String(cString: $0) } ?? "Unknown error"
            )
        }
    }

    mutating func encode(_ value: Int32) throws {
        try prepareToEncode()
        state.ensureCapacity(Int(ksbonjson_maxEncodedSize_int()))
        let result = ksbonjson_encodeToBuffer_int(&state.context, Int64(value))
        if result < 0 {
            throw BONJSONEncodingError.encodingFailed(
                ksbonjson_describeEncodeStatus(ksbonjson_encodeStatus(rawValue: UInt32(-result))).map { String(cString: $0) } ?? "Unknown error"
            )
        }
    }

    mutating func encode(_ value: Int64) throws {
        try prepareToEncode()
        state.ensureCapacity(Int(ksbonjson_maxEncodedSize_int()))
        let result = ksbonjson_encodeToBuffer_int(&state.context, value)
        if result < 0 {
            throw BONJSONEncodingError.encodingFailed(
                ksbonjson_describeEncodeStatus(ksbonjson_encodeStatus(rawValue: UInt32(-result))).map { String(cString: $0) } ?? "Unknown error"
            )
        }
    }

    mutating func encode(_ value: UInt) throws {
        try prepareToEncode()
        state.ensureCapacity(Int(ksbonjson_maxEncodedSize_int()))
        let result = ksbonjson_encodeToBuffer_uint(&state.context, UInt64(value))
        if result < 0 {
            throw BONJSONEncodingError.encodingFailed(
                ksbonjson_describeEncodeStatus(ksbonjson_encodeStatus(rawValue: UInt32(-result))).map { String(cString: $0) } ?? "Unknown error"
            )
        }
    }

    mutating func encode(_ value: UInt8) throws {
        try prepareToEncode()
        state.ensureCapacity(Int(ksbonjson_maxEncodedSize_int()))
        let result = ksbonjson_encodeToBuffer_uint(&state.context, UInt64(value))
        if result < 0 {
            throw BONJSONEncodingError.encodingFailed(
                ksbonjson_describeEncodeStatus(ksbonjson_encodeStatus(rawValue: UInt32(-result))).map { String(cString: $0) } ?? "Unknown error"
            )
        }
    }

    mutating func encode(_ value: UInt16) throws {
        try prepareToEncode()
        state.ensureCapacity(Int(ksbonjson_maxEncodedSize_int()))
        let result = ksbonjson_encodeToBuffer_uint(&state.context, UInt64(value))
        if result < 0 {
            throw BONJSONEncodingError.encodingFailed(
                ksbonjson_describeEncodeStatus(ksbonjson_encodeStatus(rawValue: UInt32(-result))).map { String(cString: $0) } ?? "Unknown error"
            )
        }
    }

    mutating func encode(_ value: UInt32) throws {
        try prepareToEncode()
        state.ensureCapacity(Int(ksbonjson_maxEncodedSize_int()))
        let result = ksbonjson_encodeToBuffer_uint(&state.context, UInt64(value))
        if result < 0 {
            throw BONJSONEncodingError.encodingFailed(
                ksbonjson_describeEncodeStatus(ksbonjson_encodeStatus(rawValue: UInt32(-result))).map { String(cString: $0) } ?? "Unknown error"
            )
        }
    }

    mutating func encode(_ value: UInt64) throws {
        try prepareToEncode()
        state.ensureCapacity(Int(ksbonjson_maxEncodedSize_int()))
        let result = ksbonjson_encodeToBuffer_uint(&state.context, value)
        if result < 0 {
            throw BONJSONEncodingError.encodingFailed(
                ksbonjson_describeEncodeStatus(ksbonjson_encodeStatus(rawValue: UInt32(-result))).map { String(cString: $0) } ?? "Unknown error"
            )
        }
    }

    mutating func encode<T: Encodable>(_ value: T) throws {
        try prepareToEncode()
        let encoder = _BufferEncoder(state: state, codingPath: codingPath + [_BONJSONIndexKey(index: count - 1)])
        try encoder.encodeValue(value)
    }

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy keyType: NestedKey.Type
    ) -> KeyedEncodingContainer<NestedKey> {
        do {
            try prepareToEncode()
        } catch {
            assertionFailure("Failed to prepare nested container: \(error)")
        }

        let container = _BufferKeyedEncodingContainer<NestedKey>(
            state: state,
            codingPath: codingPath + [_BONJSONIndexKey(index: count - 1)]
        )
        return KeyedEncodingContainer(container)
    }

    mutating func nestedUnkeyedContainer() -> UnkeyedEncodingContainer {
        do {
            try prepareToEncode()
        } catch {
            assertionFailure("Failed to prepare nested container: \(error)")
        }

        return _BufferUnkeyedEncodingContainer(
            state: state,
            codingPath: codingPath + [_BONJSONIndexKey(index: count - 1)]
        )
    }

    mutating func superEncoder() -> Encoder {
        do {
            try prepareToEncode()
        } catch {
            assertionFailure("Failed to prepare super encoder: \(error)")
        }

        return _BufferEncoder(state: state, codingPath: codingPath + [_BONJSONIndexKey(index: count - 1)])
    }
}

// MARK: - Single Value Encoding Container

struct _BufferSingleValueEncodingContainer: SingleValueEncodingContainer {
    let state: _BufferEncoderState
    let codingPath: [CodingKey]

    init(state: _BufferEncoderState, codingPath: [CodingKey]) {
        self.state = state
        self.codingPath = codingPath
    }

    mutating func encodeNil() throws {
        state.ensureCapacity(Int(ksbonjson_maxEncodedSize_null()))
        let result = ksbonjson_encodeToBuffer_null(&state.context)
        if result < 0 {
            throw BONJSONEncodingError.encodingFailed(
                ksbonjson_describeEncodeStatus(ksbonjson_encodeStatus(rawValue: UInt32(-result))).map { String(cString: $0) } ?? "Unknown error"
            )
        }
    }

    mutating func encode(_ value: Bool) throws {
        state.ensureCapacity(Int(ksbonjson_maxEncodedSize_bool()))
        let result = ksbonjson_encodeToBuffer_bool(&state.context, value)
        if result < 0 {
            throw BONJSONEncodingError.encodingFailed(
                ksbonjson_describeEncodeStatus(ksbonjson_encodeStatus(rawValue: UInt32(-result))).map { String(cString: $0) } ?? "Unknown error"
            )
        }
    }

    mutating func encode(_ value: String) throws {
        let utf8Count = value.utf8.count
        state.ensureCapacity(Int(ksbonjson_maxEncodedSize_string(utf8Count)))

        let result = value.withCString { cString in
            ksbonjson_encodeToBuffer_string(&state.context, cString, strlen(cString))
        }
        if result < 0 {
            throw BONJSONEncodingError.encodingFailed(
                ksbonjson_describeEncodeStatus(ksbonjson_encodeStatus(rawValue: UInt32(-result))).map { String(cString: $0) } ?? "Unknown error"
            )
        }
    }

    mutating func encode(_ value: Double) throws {
        let encoder = _BufferEncoder(state: state, codingPath: codingPath)
        try encoder.encodeFloat(value)
    }

    mutating func encode(_ value: Float) throws {
        try encode(Double(value))
    }

    mutating func encode(_ value: Int) throws {
        state.ensureCapacity(Int(ksbonjson_maxEncodedSize_int()))
        let result = ksbonjson_encodeToBuffer_int(&state.context, Int64(value))
        if result < 0 {
            throw BONJSONEncodingError.encodingFailed(
                ksbonjson_describeEncodeStatus(ksbonjson_encodeStatus(rawValue: UInt32(-result))).map { String(cString: $0) } ?? "Unknown error"
            )
        }
    }

    mutating func encode(_ value: Int8) throws {
        state.ensureCapacity(Int(ksbonjson_maxEncodedSize_int()))
        let result = ksbonjson_encodeToBuffer_int(&state.context, Int64(value))
        if result < 0 {
            throw BONJSONEncodingError.encodingFailed(
                ksbonjson_describeEncodeStatus(ksbonjson_encodeStatus(rawValue: UInt32(-result))).map { String(cString: $0) } ?? "Unknown error"
            )
        }
    }

    mutating func encode(_ value: Int16) throws {
        state.ensureCapacity(Int(ksbonjson_maxEncodedSize_int()))
        let result = ksbonjson_encodeToBuffer_int(&state.context, Int64(value))
        if result < 0 {
            throw BONJSONEncodingError.encodingFailed(
                ksbonjson_describeEncodeStatus(ksbonjson_encodeStatus(rawValue: UInt32(-result))).map { String(cString: $0) } ?? "Unknown error"
            )
        }
    }

    mutating func encode(_ value: Int32) throws {
        state.ensureCapacity(Int(ksbonjson_maxEncodedSize_int()))
        let result = ksbonjson_encodeToBuffer_int(&state.context, Int64(value))
        if result < 0 {
            throw BONJSONEncodingError.encodingFailed(
                ksbonjson_describeEncodeStatus(ksbonjson_encodeStatus(rawValue: UInt32(-result))).map { String(cString: $0) } ?? "Unknown error"
            )
        }
    }

    mutating func encode(_ value: Int64) throws {
        state.ensureCapacity(Int(ksbonjson_maxEncodedSize_int()))
        let result = ksbonjson_encodeToBuffer_int(&state.context, value)
        if result < 0 {
            throw BONJSONEncodingError.encodingFailed(
                ksbonjson_describeEncodeStatus(ksbonjson_encodeStatus(rawValue: UInt32(-result))).map { String(cString: $0) } ?? "Unknown error"
            )
        }
    }

    mutating func encode(_ value: UInt) throws {
        state.ensureCapacity(Int(ksbonjson_maxEncodedSize_int()))
        let result = ksbonjson_encodeToBuffer_uint(&state.context, UInt64(value))
        if result < 0 {
            throw BONJSONEncodingError.encodingFailed(
                ksbonjson_describeEncodeStatus(ksbonjson_encodeStatus(rawValue: UInt32(-result))).map { String(cString: $0) } ?? "Unknown error"
            )
        }
    }

    mutating func encode(_ value: UInt8) throws {
        state.ensureCapacity(Int(ksbonjson_maxEncodedSize_int()))
        let result = ksbonjson_encodeToBuffer_uint(&state.context, UInt64(value))
        if result < 0 {
            throw BONJSONEncodingError.encodingFailed(
                ksbonjson_describeEncodeStatus(ksbonjson_encodeStatus(rawValue: UInt32(-result))).map { String(cString: $0) } ?? "Unknown error"
            )
        }
    }

    mutating func encode(_ value: UInt16) throws {
        state.ensureCapacity(Int(ksbonjson_maxEncodedSize_int()))
        let result = ksbonjson_encodeToBuffer_uint(&state.context, UInt64(value))
        if result < 0 {
            throw BONJSONEncodingError.encodingFailed(
                ksbonjson_describeEncodeStatus(ksbonjson_encodeStatus(rawValue: UInt32(-result))).map { String(cString: $0) } ?? "Unknown error"
            )
        }
    }

    mutating func encode(_ value: UInt32) throws {
        state.ensureCapacity(Int(ksbonjson_maxEncodedSize_int()))
        let result = ksbonjson_encodeToBuffer_uint(&state.context, UInt64(value))
        if result < 0 {
            throw BONJSONEncodingError.encodingFailed(
                ksbonjson_describeEncodeStatus(ksbonjson_encodeStatus(rawValue: UInt32(-result))).map { String(cString: $0) } ?? "Unknown error"
            )
        }
    }

    mutating func encode(_ value: UInt64) throws {
        state.ensureCapacity(Int(ksbonjson_maxEncodedSize_int()))
        let result = ksbonjson_encodeToBuffer_uint(&state.context, value)
        if result < 0 {
            throw BONJSONEncodingError.encodingFailed(
                ksbonjson_describeEncodeStatus(ksbonjson_encodeStatus(rawValue: UInt32(-result))).map { String(cString: $0) } ?? "Unknown error"
            )
        }
    }

    mutating func encode<T: Encodable>(_ value: T) throws {
        let encoder = _BufferEncoder(state: state, codingPath: codingPath)
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
