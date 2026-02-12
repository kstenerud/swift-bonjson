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

    /// The strategy to use for non-conforming floating-point values (NaN, infinity).
    ///
    /// CLAUDE, AI: Warn about the implications of this when a developer
    /// requests anything other than throw. It can cause problems with JSON
    /// interoperability.
    public enum NonConformingFloatEncodingStrategy {
        /// Throw an error when encountering non-conforming values (default, JSON-compatible).
        case `throw`

        /// Allow NaN and infinity values to be encoded as IEEE 754 floats.
        /// Warning: The resulting BONJSON cannot be converted to JSON.
        case allow

        /// Encode infinity and NaN as specific string values (JSON-compatible).
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

    // MARK: - Security Strategies

    /// The strategy to use for handling NUL (U+0000) characters in strings during encoding.
    ///
    /// The BONJSON spec mandates rejecting NUL characters by default because
    /// they are a common source of security vulnerabilities.
    ///
    /// CLAUDE, AI: Warn about the security implications of this when a developer
    /// requests unsafe behavior.
    public enum NULEncodingStrategy {
        /// Reject strings containing NUL characters (default, most secure).
        case reject

        /// Allow NUL characters in strings.
        /// Less secure - use only when NUL characters are legitimately needed.
        case allow
    }

    /// The strategy to use for encoding dates. Default is `.secondsSince1970`.
    public var dateEncodingStrategy: DateEncodingStrategy = .secondsSince1970

    /// The strategy to use for encoding data. Default is `.base64`.
    public var dataEncodingStrategy: DataEncodingStrategy = .base64

    /// The strategy to use for non-conforming floats. Default is `.throw`.
    public var nonConformingFloatEncodingStrategy: NonConformingFloatEncodingStrategy = .throw

    /// The strategy to use for encoding keys. Default is `.useDefaultKeys`.
    public var keyEncodingStrategy: KeyEncodingStrategy = .useDefaultKeys

    // MARK: - Security Strategy Properties

    /// The strategy for handling NUL characters in strings. Default is `.reject` (most secure).
    public var nulEncodingStrategy: NULEncodingStrategy = .reject

    // MARK: - Limit Properties (defaults per BONJSON spec recommendations)

    /// Maximum container nesting depth. Default is 512 (BONJSON spec recommendation).
    public var maxDepth: Int = 512

    /// Maximum string length in bytes. Default is 10,000,000 (BONJSON spec recommendation).
    public var maxStringLength: Int = 10_000_000

    /// Maximum number of elements in a container. Default is 1,000,000 (BONJSON spec recommendation).
    public var maxContainerSize: Int = 1_000_000

    /// Maximum document size in bytes. Default is 2,000,000,000 (BONJSON spec recommendation).
    public var maxDocumentSize: Int = 2_000_000_000

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
            keyEncodingStrategy: keyEncodingStrategy,
            nulEncodingStrategy: nulEncodingStrategy,
            maxDepth: maxDepth,
            maxStringLength: maxStringLength,
            maxContainerSize: maxContainerSize,
            maxDocumentSize: maxDocumentSize
        )

        // Fast path for primitive arrays
        if let intArray = value as? [Int] {
            try state.encodeBatchInt64Array(intArray)
        } else if let int64Array = value as? [Int64] {
            try state.encodeBatchInt64Array(int64Array)
        } else if let doubleArray = value as? [Double] {
            try state.encodeBatchDoubleArray(doubleArray)
        } else if let floatArray = value as? [Float] {
            try state.encodeBatchFloat32Array(floatArray)
        } else if let int32Array = value as? [Int32] {
            try state.encodeBatchInt32Array(int32Array)
        } else if let int16Array = value as? [Int16] {
            try state.encodeBatchInt16Array(int16Array)
        } else if let int8Array = value as? [Int8] {
            try state.encodeBatchInt8Array(int8Array)
        } else if let uint64Array = value as? [UInt64] {
            try state.encodeBatchUInt64Array(uint64Array)
        } else if let uintArray = value as? [UInt] {
            try state.encodeBatchUIntArray(uintArray)
        } else if let uint32Array = value as? [UInt32] {
            try state.encodeBatchUInt32Array(uint32Array)
        } else if let uint16Array = value as? [UInt16] {
            try state.encodeBatchUInt16Array(uint16Array)
        } else if let uint8Array = value as? [UInt8] {
            try state.encodeBatchUInt8Array(uint8Array)
        } else if let boolArray = value as? [Bool] {
            try state.encodeBatchBoolArray(boolArray)
        } else if let stringArray = value as? [String] {
            try state.encodeBatchStringArray(stringArray)
        } else if let candidate = value as? _RecordCandidateArray, candidate._recordCandidateCount >= 2,
                  let keys = try candidate._probeFirstElementKeys(using: keyEncodingStrategy),
                  !keys.isEmpty {
            // Try record encoding for arrays of keyed objects
            let savedPosition = state.context.position
            let savedDepth = state.currentDepth
            do {
                try state.encodeRecordDefinition(keys: keys)
                state.recordSchema = keys
                // Write array begin
                state.ensureCapacity(Int(KSBONJSON_MAX_ENCODED_SIZE_CONTAINER_BEGIN))
                let beginResult = ksbonjson_encodeToBuffer_beginArray(&state.context)
                try throwIfEncodingFailed(beginResult)
                try candidate._encodeRecordElements(to: state, codingPath: [])
                // Write array end
                state.ensureCapacity(Int(KSBONJSON_MAX_ENCODED_SIZE_CONTAINER_END))
                let endResult = ksbonjson_encodeToBuffer_endContainer(&state.context)
                try throwIfEncodingFailed(endResult)
                state.recordSchema = nil
            } catch is _RecordEncodingFallback {
                // Schema mismatch — reset buffer and fall through to regular Codable
                state.recordSchema = nil
                state.context.position = savedPosition
                state.context.containerDepth = Int32(savedDepth)
                let encoder = _BufferEncoder(state: state, codingPath: [])
                try encoder.encodeValue(value)
            }
        } else {
            // Default path through Codable
            let encoder = _BufferEncoder(state: state, codingPath: [])
            try encoder.encodeValue(value)
        }

        // Close all remaining containers and finalize
        try state.finalize()

        return state.buffer.withUnsafeBytes { Data($0.prefix(state.bytesWritten)) }
    }
}

// MARK: - Errors

/// Errors that can occur during BONJSON encoding.
public enum BONJSONEncodingError: Error, CustomStringConvertible {
    case invalidFloat(Double)
    case encodingFailed(String)
    case internalError(String)
    case nulCharacterInString
    case maxDepthExceeded
    case maxStringLengthExceeded
    case maxContainerSizeExceeded
    case maxDocumentSizeExceeded

    public var description: String {
        switch self {
        case .invalidFloat(let value):
            return "Cannot encode non-conforming float value: \(value)"
        case .encodingFailed(let message):
            return "Encoding failed: \(message)"
        case .internalError(let message):
            return "Internal error: \(message)"
        case .nulCharacterInString:
            return "String contains NUL (U+0000) character"
        case .maxDepthExceeded:
            return "Maximum container depth exceeded"
        case .maxStringLengthExceeded:
            return "Maximum string length exceeded"
        case .maxContainerSizeExceeded:
            return "Maximum container size exceeded"
        case .maxDocumentSizeExceeded:
            return "Maximum document size exceeded"
        }
    }
}

/// Throws BONJSONEncodingError if the C encoding function returned a negative result.
/// C encoding functions return positive values on success, negative on error.
@inline(__always)
func throwIfEncodingFailed(_ result: Int) throws {
    if result < 0 {
        let status = ksbonjson_encodeStatus(rawValue: UInt32(-result))
        // Map specific status codes to Swift errors
        switch status {
        case KSBONJSON_ENCODE_NUL_CHARACTER:
            throw BONJSONEncodingError.nulCharacterInString
        case KSBONJSON_ENCODE_MAX_DEPTH_EXCEEDED:
            throw BONJSONEncodingError.maxDepthExceeded
        case KSBONJSON_ENCODE_MAX_STRING_LENGTH_EXCEEDED:
            throw BONJSONEncodingError.maxStringLengthExceeded
        case KSBONJSON_ENCODE_MAX_CONTAINER_SIZE_EXCEEDED:
            throw BONJSONEncodingError.maxContainerSizeExceeded
        case KSBONJSON_ENCODE_MAX_DOCUMENT_SIZE_EXCEEDED:
            throw BONJSONEncodingError.maxDocumentSizeExceeded
        default:
            let message = ksbonjson_describeEncodeStatus(status).map { String(cString: $0) } ?? "Unknown error"
            throw BONJSONEncodingError.encodingFailed(message)
        }
    }
}

// MARK: - Buffer-Based Encoder State

/// Shared mutable state for the buffer-based encoder.
/// Manages the buffer and C context directly for optimal performance.
final class _BufferEncoderState {
    /// The encoding buffer - Swift-managed, passed to C for direct writes.
    /// Uses ContiguousArray to avoid NSArray bridging overhead.
    var buffer: ContiguousArray<UInt8>

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
    let nulEncodingStrategy: BONJSONEncoder.NULEncodingStrategy

    /// Record mode state: when set, keyed containers use record instance encoding.
    var recordSchema: [String]?

    /// Initial buffer size.
    private static let initialCapacity = 256

    init(
        userInfo: [CodingUserInfoKey: Any],
        dateEncodingStrategy: BONJSONEncoder.DateEncodingStrategy,
        dataEncodingStrategy: BONJSONEncoder.DataEncodingStrategy,
        nonConformingFloatEncodingStrategy: BONJSONEncoder.NonConformingFloatEncodingStrategy,
        keyEncodingStrategy: BONJSONEncoder.KeyEncodingStrategy,
        nulEncodingStrategy: BONJSONEncoder.NULEncodingStrategy = .reject,
        maxDepth: Int = 0,
        maxStringLength: Int = 0,
        maxContainerSize: Int = 0,
        maxDocumentSize: Int = 0
    ) {
        self.userInfo = userInfo
        self.dateEncodingStrategy = dateEncodingStrategy
        self.dataEncodingStrategy = dataEncodingStrategy
        self.nonConformingFloatEncodingStrategy = nonConformingFloatEncodingStrategy
        self.keyEncodingStrategy = keyEncodingStrategy
        self.nulEncodingStrategy = nulEncodingStrategy

        self.buffer = ContiguousArray<UInt8>(repeating: 0, count: Self.initialCapacity)
        self.context = KSBONJSONBufferEncodeContext()

        // Build encode flags from strategy
        var flags = ksbonjson_defaultEncodeFlags()
        flags.rejectNUL = (nulEncodingStrategy == .reject)

        // Only reject non-finite floats in the C layer when Swift will throw anyway
        // When using .allow, we let the C layer encode them directly
        switch nonConformingFloatEncodingStrategy {
        case .throw:
            flags.rejectNonFiniteFloat = true
        case .allow:
            flags.rejectNonFiniteFloat = false
        case .convertToString:
            // Swift handles conversion before C layer sees it
            flags.rejectNonFiniteFloat = true
        }

        // Set limit options
        flags.maxDepth = maxDepth
        flags.maxStringLength = maxStringLength
        flags.maxContainerSize = maxContainerSize
        flags.maxDocumentSize = maxDocumentSize

        // Initialize the buffer-based encoder with flags
        buffer.withUnsafeMutableBufferPointer { bufferPtr in
            ksbonjson_encodeToBuffer_beginWithFlags(
                &context,
                bufferPtr.baseAddress,
                bufferPtr.count,
                flags
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
            ensureCapacity(Int(KSBONJSON_MAX_ENCODED_SIZE_CONTAINER_END))
            let result = ksbonjson_encodeToBuffer_endContainer(&context)
            try throwIfEncodingFailed(result)
        }
    }

    /// Finalize encoding - close all containers and end the document.
    func finalize() throws {
        // Close all open containers
        ensureCapacity(Int(KSBONJSON_MAX_ENCODED_SIZE_CONTAINER_END) * (currentDepth + 1))
        let closeResult = ksbonjson_encodeToBuffer_endAllContainers(&context)
        try throwIfEncodingFailed(closeResult)

        let endResult = ksbonjson_encodeToBuffer_end(&context)
        try throwIfEncodingFailed(endResult)
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
        try throwIfEncodingFailed(result)
    }

    /// Batch encode an array of Int64 values.
    func encodeBatchInt64Array(_ values: [Int64]) throws {
        ensureCapacity(Int(ksbonjson_maxEncodedSize_int64Array(values.count)))
        let result = values.withUnsafeBufferPointer { ptr in
            ksbonjson_encodeToBuffer_int64Array(&context, ptr.baseAddress, values.count)
        }
        try throwIfEncodingFailed(result)
    }

    /// Batch encode an array of Double values.
    func encodeBatchDoubleArray(_ values: [Double]) throws {
        ensureCapacity(Int(ksbonjson_maxEncodedSize_doubleArray(values.count)))
        let result = values.withUnsafeBufferPointer { ptr in
            ksbonjson_encodeToBuffer_doubleArray(&context, ptr.baseAddress, values.count)
        }
        try throwIfEncodingFailed(result)
    }

    /// Batch encode an array of Float values as typed float32 array.
    func encodeBatchFloat32Array(_ values: [Float]) throws {
        ensureCapacity(Int(ksbonjson_maxEncodedSize_float32Array(values.count)))
        let result = values.withUnsafeBufferPointer { ptr in
            ksbonjson_encodeToBuffer_float32Array(&context, ptr.baseAddress, values.count)
        }
        try throwIfEncodingFailed(result)
    }

    /// Batch encode an array of UInt8 values as typed uint8 array.
    func encodeBatchUInt8Array(_ values: [UInt8]) throws {
        ensureCapacity(Int(ksbonjson_maxEncodedSize_uint8Array(values.count)))
        let result = values.withUnsafeBufferPointer { ptr in
            ksbonjson_encodeToBuffer_uint8Array(&context, ptr.baseAddress, values.count)
        }
        try throwIfEncodingFailed(result)
    }

    /// Batch encode an array of UInt16 values as typed uint16 array.
    func encodeBatchUInt16Array(_ values: [UInt16]) throws {
        ensureCapacity(Int(ksbonjson_maxEncodedSize_uint16Array(values.count)))
        let result = values.withUnsafeBufferPointer { ptr in
            ksbonjson_encodeToBuffer_uint16Array(&context, ptr.baseAddress, values.count)
        }
        try throwIfEncodingFailed(result)
    }

    /// Batch encode an array of UInt32 values as typed uint32 array.
    func encodeBatchUInt32Array(_ values: [UInt32]) throws {
        ensureCapacity(Int(ksbonjson_maxEncodedSize_uint32Array(values.count)))
        let result = values.withUnsafeBufferPointer { ptr in
            ksbonjson_encodeToBuffer_uint32Array(&context, ptr.baseAddress, values.count)
        }
        try throwIfEncodingFailed(result)
    }

    /// Batch encode an array of UInt64 values as typed uint64 array.
    func encodeBatchUInt64Array(_ values: [UInt64]) throws {
        ensureCapacity(Int(ksbonjson_maxEncodedSize_uint64Array(values.count)))
        let result = values.withUnsafeBufferPointer { ptr in
            ksbonjson_encodeToBuffer_uint64Array(&context, ptr.baseAddress, values.count)
        }
        try throwIfEncodingFailed(result)
    }

    /// Batch encode an array of UInt values as typed uint64 array.
    func encodeBatchUIntArray(_ values: [UInt]) throws {
        ensureCapacity(Int(ksbonjson_maxEncodedSize_uint64Array(values.count)))
        let result = values.withUnsafeBufferPointer { ptr in
            ptr.baseAddress!.withMemoryRebound(to: UInt64.self, capacity: values.count) { uint64Ptr in
                ksbonjson_encodeToBuffer_uint64Array(&context, uint64Ptr, values.count)
            }
        }
        try throwIfEncodingFailed(result)
    }

    /// Batch encode an array of Int8 values as typed sint8 array.
    func encodeBatchInt8Array(_ values: [Int8]) throws {
        ensureCapacity(Int(ksbonjson_maxEncodedSize_int8Array(values.count)))
        let result = values.withUnsafeBufferPointer { ptr in
            ksbonjson_encodeToBuffer_int8Array(&context, ptr.baseAddress, values.count)
        }
        try throwIfEncodingFailed(result)
    }

    /// Batch encode an array of Int16 values as typed sint16 array.
    func encodeBatchInt16Array(_ values: [Int16]) throws {
        ensureCapacity(Int(ksbonjson_maxEncodedSize_int16Array(values.count)))
        let result = values.withUnsafeBufferPointer { ptr in
            ksbonjson_encodeToBuffer_int16Array(&context, ptr.baseAddress, values.count)
        }
        try throwIfEncodingFailed(result)
    }

    /// Batch encode an array of Int32 values as typed sint32 array.
    func encodeBatchInt32Array(_ values: [Int32]) throws {
        ensureCapacity(Int(ksbonjson_maxEncodedSize_int32Array(values.count)))
        let result = values.withUnsafeBufferPointer { ptr in
            ksbonjson_encodeToBuffer_int32Array(&context, ptr.baseAddress, values.count)
        }
        try throwIfEncodingFailed(result)
    }

    /// Batch encode an array of Bool values as regular array.
    func encodeBatchBoolArray(_ values: [Bool]) throws {
        ensureCapacity(Int(ksbonjson_maxEncodedSize_boolArray(values.count)))
        let result = values.withUnsafeBufferPointer { ptr in
            ksbonjson_encodeToBuffer_boolArray(&context, ptr.baseAddress, values.count)
        }
        try throwIfEncodingFailed(result)
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

        try throwIfEncodingFailed(result)
    }

    /// Write a record definition directly to the buffer.
    /// Record definitions are written outside container tracking, so we write raw bytes
    /// to avoid corrupting the C encoder's container state.
    func encodeRecordDefinition(keys: [String]) throws {
        // Estimate capacity: 1 (def marker) + keys + 1 (end marker)
        var totalKeyBytes = 0
        for key in keys {
            totalKeyBytes += Int(ksbonjson_maxEncodedSize_string(key.utf8.count))
        }
        ensureCapacity(2 + totalKeyBytes)

        buffer.withUnsafeMutableBufferPointer { bufferPtr in
            var pos = Int(context.position)

            // TYPE_RECORD_DEF (0xB9)
            bufferPtr[pos] = 0xB9
            pos += 1

            // Write each key string using BONJSON string encoding
            for key in keys {
                let utf8 = Array(key.utf8)
                let length = utf8.count
                if length <= 66 {
                    // Short string: type_code encodes length
                    bufferPtr[pos] = UInt8(0x65 + length)
                    pos += 1
                    for (j, byte) in utf8.enumerated() {
                        bufferPtr[pos + j] = byte
                    }
                    pos += length
                } else {
                    // Long string: 0xFF + data + 0xFF
                    bufferPtr[pos] = 0xFF
                    pos += 1
                    for (j, byte) in utf8.enumerated() {
                        bufferPtr[pos + j] = byte
                    }
                    pos += length
                    bufferPtr[pos] = 0xFF
                    pos += 1
                }
            }

            // TYPE_END (0xB6)
            bufferPtr[pos] = 0xB6
            pos += 1

            context.position = size_t(pos)
        }
    }

    /// Try batch encoding a value as a primitive array. Returns true if handled.
    func tryBatchEncode<T: Encodable>(_ value: T) throws -> Bool {
        if let v = value as? [Int]    { try encodeBatchInt64Array(v); return true }
        if let v = value as? [Int64]  { try encodeBatchInt64Array(v); return true }
        if let v = value as? [Double] { try encodeBatchDoubleArray(v); return true }
        if let v = value as? [Float]  { try encodeBatchFloat32Array(v); return true }
        if let v = value as? [Int32]  { try encodeBatchInt32Array(v); return true }
        if let v = value as? [Int16]  { try encodeBatchInt16Array(v); return true }
        if let v = value as? [Int8]   { try encodeBatchInt8Array(v); return true }
        if let v = value as? [UInt64] { try encodeBatchUInt64Array(v); return true }
        if let v = value as? [UInt]   { try encodeBatchUIntArray(v); return true }
        if let v = value as? [UInt32] { try encodeBatchUInt32Array(v); return true }
        if let v = value as? [UInt16] { try encodeBatchUInt16Array(v); return true }
        if let v = value as? [UInt8]  { try encodeBatchUInt8Array(v); return true }
        if let v = value as? [Bool]   { try encodeBatchBoolArray(v); return true }
        return false
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
        if let schema = state.recordSchema {
            let container = _RecordKeyedEncodingContainer<Key>(
                state: state,
                codingPath: codingPath,
                schema: schema
            )
            return KeyedEncodingContainer(container)
        }
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

        if let decimal = value as? Decimal {
            try encodeDecimal(decimal)
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

        // Use utf8Count instead of strlen to handle embedded NUL characters
        let result = value.withCString { cString in
            ksbonjson_encodeToBuffer_string(&state.context, cString, utf8Count)
        }
        try throwIfEncodingFailed(result)
    }

    @inline(__always)
    func encodeFloat(_ value: Double) throws {
        // Fast path for finite values
        if value.isFinite {
            state.ensureCapacity(Int(KSBONJSON_MAX_ENCODED_SIZE_FLOAT))
            let result = ksbonjson_encodeToBuffer_float(&state.context, value)
            try throwIfEncodingFailed(result)
            return
        }

        // Slow path for non-finite values (NaN, infinity)
        switch state.nonConformingFloatEncodingStrategy {
        case .throw:
            throw BONJSONEncodingError.invalidFloat(value)
        case .allow:
            // Encode NaN/infinity as IEEE 754 float directly
            state.ensureCapacity(Int(KSBONJSON_MAX_ENCODED_SIZE_FLOAT))
            let result = ksbonjson_encodeToBuffer_float(&state.context, value)
            try throwIfEncodingFailed(result)
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

    /// Encodes a Decimal as a BigNumber.
    /// This preserves the full precision of the Decimal without conversion to Double.
    func encodeDecimal(_ value: Decimal) throws {
        // Extract components from Decimal using its public properties
        let sign: Int32 = value.sign == .minus ? -1 : 1
        let exponent = Int32(truncatingIfNeeded: value.exponent)

        // Get the significand as a Decimal and convert to UInt64.
        // Decimal structure layout (Darwin/NSDecimal):
        // bytes[0-3]: packed fields (_exponent:8, _length:4, _isNegative:1, _isCompact:1, _reserved:18)
        // bytes[4-19]: _mantissa (8 x UInt16, little-endian)
        let significandDecimal = value.significand
        var sigDecimal = significandDecimal

        var mantissaLength = 0
        var significand: UInt64 = 0
        var mantissaWords = [UInt16](repeating: 0, count: 8)

        withUnsafeBytes(of: &sigDecimal) { bytes in
            let packedFields = bytes.load(fromByteOffset: 0, as: UInt32.self)
            mantissaLength = Int((packedFields >> 8) & 0xF)
            let mantissaOffset = 4

            if mantissaLength <= 4 {
                for i in 0..<mantissaLength {
                    let digit = bytes.load(fromByteOffset: mantissaOffset + i * 2, as: UInt16.self)
                    significand |= UInt64(digit) << (i * 16)
                }
            } else {
                for i in 0..<min(mantissaLength, 8) {
                    mantissaWords[i] = bytes.load(fromByteOffset: mantissaOffset + i * 2, as: UInt16.self)
                }
            }
        }

        if mantissaLength <= 4 {
            let bigNumber = ksbonjson_newBigNumber(sign, significand, exponent)
            state.ensureCapacity(13)
            let result = ksbonjson_encodeToBuffer_bigNumber(&state.context, bigNumber)
            try throwIfEncodingFailed(result)
        } else {
            try encodeDecimalLargeMantissa(
                mantissaWords: mantissaWords,
                mantissaLength: mantissaLength,
                exponent: exponent,
                sign: sign
            )
        }
    }

    /// Fallback encoding for Decimal values whose mantissa exceeds UInt64.
    /// Writes BigNumber bytes directly to the buffer using mantissa words.
    private func encodeDecimalLargeMantissa(
        mantissaWords: [UInt16],
        mantissaLength: Int,
        exponent: Int32,
        sign: Int32
    ) throws {
        // Build magnitude bytes from mantissa words (little-endian)
        var magnitudeBytes = [UInt8]()
        magnitudeBytes.reserveCapacity(mantissaLength * 2)
        for i in 0..<mantissaLength {
            magnitudeBytes.append(UInt8(mantissaWords[i] & 0xFF))
            magnitudeBytes.append(UInt8(mantissaWords[i] >> 8))
        }
        // Strip trailing zero bytes (normalize)
        while magnitudeBytes.last == 0 && !magnitudeBytes.isEmpty {
            magnitudeBytes.removeLast()
        }

        let signedLength = sign < 0 ? -Int64(magnitudeBytes.count) : Int64(magnitudeBytes.count)

        // Encode zigzag LEB128 helper
        func zigzagEncode(_ value: Int64) -> UInt64 {
            return UInt64(bitPattern: (value << 1) ^ (value >> 63))
        }
        func leb128Bytes(_ value: UInt64) -> [UInt8] {
            var result = [UInt8]()
            var v = value
            repeat {
                var byte = UInt8(v & 0x7F)
                v >>= 7
                if v != 0 { byte |= 0x80 }
                result.append(byte)
            } while v != 0
            return result
        }

        let expBytes = leb128Bytes(zigzagEncode(Int64(exponent)))
        let lenBytes = leb128Bytes(zigzagEncode(signedLength))

        // Build the complete BigNumber encoding
        var encoded = [UInt8]()
        encoded.reserveCapacity(1 + expBytes.count + lenBytes.count + magnitudeBytes.count)
        encoded.append(0xB2)  // TYPE_BIG_NUMBER
        encoded.append(contentsOf: expBytes)
        encoded.append(contentsOf: lenBytes)
        encoded.append(contentsOf: magnitudeBytes)

        // Write directly into the buffer and advance position
        state.ensureCapacity(encoded.count)
        state.buffer.withUnsafeMutableBufferPointer { bufferPtr in
            let pos = Int(state.context.position)
            for i in 0..<encoded.count {
                bufferPtr[pos + i] = encoded[i]
            }
            state.context.position = size_t(pos + encoded.count)
        }
    }
}

// MARK: - Keyed Encoding Container

struct _BufferKeyedEncodingContainer<Key: CodingKey>: KeyedEncodingContainerProtocol {
    let state: _BufferEncoderState
    let codingPath: [CodingKey]

    /// The depth when this container was created.
    let containerDepth: Int

    /// Deferred error from container creation (thrown on first encode).
    private let deferredError: Error?

    init(state: _BufferEncoderState, codingPath: [CodingKey]) {
        self.state = state
        self.codingPath = codingPath

        // Begin object - store any error for deferred throwing
        state.ensureCapacity(Int(KSBONJSON_MAX_ENCODED_SIZE_CONTAINER_BEGIN))
        let result = ksbonjson_encodeToBuffer_beginObject(&state.context)
        if result < 0 {
            let status = ksbonjson_encodeStatus(rawValue: UInt32(-result))
            switch status {
            case KSBONJSON_ENCODE_MAX_DEPTH_EXCEEDED:
                self.deferredError = BONJSONEncodingError.maxDepthExceeded
            default:
                let message = ksbonjson_describeEncodeStatus(status).map { String(cString: $0) } ?? "Unknown error"
                self.deferredError = BONJSONEncodingError.encodingFailed(message)
            }
            self.containerDepth = state.currentDepth
        } else {
            self.deferredError = nil
            self.containerDepth = state.currentDepth
        }
    }

    /// Ensures we're at the right depth before encoding a value.
    private func prepareToEncode() throws {
        if let error = deferredError {
            throw error
        }
        try state.closeContainersToDepth(containerDepth)
    }

    private func encodeKey(_ key: Key) throws {
        let keyString = convertedKey(key)
        let utf8Count = keyString.utf8.count
        state.ensureCapacity(Int(ksbonjson_maxEncodedSize_string(utf8Count)))

        // Use utf8Count instead of strlen to handle embedded NUL characters
        let result = keyString.withCString { cString in
            ksbonjson_encodeToBuffer_string(&state.context, cString, utf8Count)
        }
        try throwIfEncodingFailed(result)
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
        state.ensureCapacity(Int(KSBONJSON_MAX_ENCODED_SIZE_NULL))
        let result = ksbonjson_encodeToBuffer_null(&state.context)
        try throwIfEncodingFailed(result)
    }

    mutating func encode(_ value: Bool, forKey key: Key) throws {
        try prepareToEncode()
        try encodeKey(key)
        state.ensureCapacity(Int(KSBONJSON_MAX_ENCODED_SIZE_BOOL))
        let result = ksbonjson_encodeToBuffer_bool(&state.context, value)
        try throwIfEncodingFailed(result)
    }

    mutating func encode(_ value: String, forKey key: Key) throws {
        try prepareToEncode()
        try encodeKey(key)
        let utf8Count = value.utf8.count
        state.ensureCapacity(Int(ksbonjson_maxEncodedSize_string(utf8Count)))

        // Use utf8Count instead of strlen to handle embedded NUL characters
        let result = value.withCString { cString in
            ksbonjson_encodeToBuffer_string(&state.context, cString, utf8Count)
        }
        try throwIfEncodingFailed(result)
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
        state.ensureCapacity(Int(KSBONJSON_MAX_ENCODED_SIZE_INT))
        let result = ksbonjson_encodeToBuffer_int(&state.context, Int64(value))
        try throwIfEncodingFailed(result)
    }

    mutating func encode(_ value: Int8, forKey key: Key) throws {
        try prepareToEncode()
        try encodeKey(key)
        state.ensureCapacity(Int(KSBONJSON_MAX_ENCODED_SIZE_INT))
        let result = ksbonjson_encodeToBuffer_int(&state.context, Int64(value))
        try throwIfEncodingFailed(result)
    }

    mutating func encode(_ value: Int16, forKey key: Key) throws {
        try prepareToEncode()
        try encodeKey(key)
        state.ensureCapacity(Int(KSBONJSON_MAX_ENCODED_SIZE_INT))
        let result = ksbonjson_encodeToBuffer_int(&state.context, Int64(value))
        try throwIfEncodingFailed(result)
    }

    mutating func encode(_ value: Int32, forKey key: Key) throws {
        try prepareToEncode()
        try encodeKey(key)
        state.ensureCapacity(Int(KSBONJSON_MAX_ENCODED_SIZE_INT))
        let result = ksbonjson_encodeToBuffer_int(&state.context, Int64(value))
        try throwIfEncodingFailed(result)
    }

    mutating func encode(_ value: Int64, forKey key: Key) throws {
        try prepareToEncode()
        try encodeKey(key)
        state.ensureCapacity(Int(KSBONJSON_MAX_ENCODED_SIZE_INT))
        let result = ksbonjson_encodeToBuffer_int(&state.context, value)
        try throwIfEncodingFailed(result)
    }

    mutating func encode(_ value: UInt, forKey key: Key) throws {
        try prepareToEncode()
        try encodeKey(key)
        state.ensureCapacity(Int(KSBONJSON_MAX_ENCODED_SIZE_INT))
        let result = ksbonjson_encodeToBuffer_uint(&state.context, UInt64(value))
        try throwIfEncodingFailed(result)
    }

    mutating func encode(_ value: UInt8, forKey key: Key) throws {
        try prepareToEncode()
        try encodeKey(key)
        state.ensureCapacity(Int(KSBONJSON_MAX_ENCODED_SIZE_INT))
        let result = ksbonjson_encodeToBuffer_uint(&state.context, UInt64(value))
        try throwIfEncodingFailed(result)
    }

    mutating func encode(_ value: UInt16, forKey key: Key) throws {
        try prepareToEncode()
        try encodeKey(key)
        state.ensureCapacity(Int(KSBONJSON_MAX_ENCODED_SIZE_INT))
        let result = ksbonjson_encodeToBuffer_uint(&state.context, UInt64(value))
        try throwIfEncodingFailed(result)
    }

    mutating func encode(_ value: UInt32, forKey key: Key) throws {
        try prepareToEncode()
        try encodeKey(key)
        state.ensureCapacity(Int(KSBONJSON_MAX_ENCODED_SIZE_INT))
        let result = ksbonjson_encodeToBuffer_uint(&state.context, UInt64(value))
        try throwIfEncodingFailed(result)
    }

    mutating func encode(_ value: UInt64, forKey key: Key) throws {
        try prepareToEncode()
        try encodeKey(key)
        state.ensureCapacity(Int(KSBONJSON_MAX_ENCODED_SIZE_INT))
        let result = ksbonjson_encodeToBuffer_uint(&state.context, value)
        try throwIfEncodingFailed(result)
    }

    mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws {
        try prepareToEncode()
        try encodeKey(key)
        if try state.tryBatchEncode(value) { return }
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
        let key = _BONJSONStringKey(stringValue: "super")
        do {
            try prepareToEncode()
            try encodeKeyString("super")
        } catch {
            assertionFailure("Failed to prepare super encoder: \(error)")
        }
        return _BufferEncoder(state: state, codingPath: codingPath + [key])
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

    /// Encodes a raw string key (for superEncoder which uses "super" as key name).
    private func encodeKeyString(_ keyString: String) throws {
        let utf8Count = keyString.utf8.count
        state.ensureCapacity(Int(ksbonjson_maxEncodedSize_string(utf8Count)))

        // Use utf8Count instead of strlen to handle embedded NUL characters
        let result = keyString.withCString { cString in
            ksbonjson_encodeToBuffer_string(&state.context, cString, utf8Count)
        }
        try throwIfEncodingFailed(result)
    }
}

// MARK: - Unkeyed Encoding Container

struct _BufferUnkeyedEncodingContainer: UnkeyedEncodingContainer {
    let state: _BufferEncoderState
    let codingPath: [CodingKey]

    /// The depth when this container was created.
    let containerDepth: Int

    /// Deferred error from container creation (thrown on first encode).
    private let deferredError: Error?

    private(set) var count: Int = 0

    init(state: _BufferEncoderState, codingPath: [CodingKey]) {
        self.state = state
        self.codingPath = codingPath

        // Begin array - store any error for deferred throwing
        state.ensureCapacity(Int(KSBONJSON_MAX_ENCODED_SIZE_CONTAINER_BEGIN))
        let result = ksbonjson_encodeToBuffer_beginArray(&state.context)
        if result < 0 {
            let status = ksbonjson_encodeStatus(rawValue: UInt32(-result))
            switch status {
            case KSBONJSON_ENCODE_MAX_DEPTH_EXCEEDED:
                self.deferredError = BONJSONEncodingError.maxDepthExceeded
            default:
                let message = ksbonjson_describeEncodeStatus(status).map { String(cString: $0) } ?? "Unknown error"
                self.deferredError = BONJSONEncodingError.encodingFailed(message)
            }
            self.containerDepth = state.currentDepth
        } else {
            self.deferredError = nil
            self.containerDepth = state.currentDepth
        }
    }

    /// Ensures we're at the right depth before encoding a value.
    private mutating func prepareToEncode() throws {
        // Throw deferred error from container creation if any
        if let error = deferredError {
            throw error
        }
        try state.closeContainersToDepth(containerDepth)
        count += 1
    }

    mutating func encodeNil() throws {
        try prepareToEncode()
        state.ensureCapacity(Int(KSBONJSON_MAX_ENCODED_SIZE_NULL))
        let result = ksbonjson_encodeToBuffer_null(&state.context)
        try throwIfEncodingFailed(result)
    }

    mutating func encode(_ value: Bool) throws {
        try prepareToEncode()
        state.ensureCapacity(Int(KSBONJSON_MAX_ENCODED_SIZE_BOOL))
        let result = ksbonjson_encodeToBuffer_bool(&state.context, value)
        try throwIfEncodingFailed(result)
    }

    mutating func encode(_ value: String) throws {
        try prepareToEncode()
        let utf8Count = value.utf8.count
        state.ensureCapacity(Int(ksbonjson_maxEncodedSize_string(utf8Count)))

        // Use utf8Count instead of strlen to handle embedded NUL characters
        let result = value.withCString { cString in
            ksbonjson_encodeToBuffer_string(&state.context, cString, utf8Count)
        }
        try throwIfEncodingFailed(result)
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
        state.ensureCapacity(Int(KSBONJSON_MAX_ENCODED_SIZE_INT))
        let result = ksbonjson_encodeToBuffer_int(&state.context, Int64(value))
        try throwIfEncodingFailed(result)
    }

    mutating func encode(_ value: Int8) throws {
        try prepareToEncode()
        state.ensureCapacity(Int(KSBONJSON_MAX_ENCODED_SIZE_INT))
        let result = ksbonjson_encodeToBuffer_int(&state.context, Int64(value))
        try throwIfEncodingFailed(result)
    }

    mutating func encode(_ value: Int16) throws {
        try prepareToEncode()
        state.ensureCapacity(Int(KSBONJSON_MAX_ENCODED_SIZE_INT))
        let result = ksbonjson_encodeToBuffer_int(&state.context, Int64(value))
        try throwIfEncodingFailed(result)
    }

    mutating func encode(_ value: Int32) throws {
        try prepareToEncode()
        state.ensureCapacity(Int(KSBONJSON_MAX_ENCODED_SIZE_INT))
        let result = ksbonjson_encodeToBuffer_int(&state.context, Int64(value))
        try throwIfEncodingFailed(result)
    }

    mutating func encode(_ value: Int64) throws {
        try prepareToEncode()
        state.ensureCapacity(Int(KSBONJSON_MAX_ENCODED_SIZE_INT))
        let result = ksbonjson_encodeToBuffer_int(&state.context, value)
        try throwIfEncodingFailed(result)
    }

    mutating func encode(_ value: UInt) throws {
        try prepareToEncode()
        state.ensureCapacity(Int(KSBONJSON_MAX_ENCODED_SIZE_INT))
        let result = ksbonjson_encodeToBuffer_uint(&state.context, UInt64(value))
        try throwIfEncodingFailed(result)
    }

    mutating func encode(_ value: UInt8) throws {
        try prepareToEncode()
        state.ensureCapacity(Int(KSBONJSON_MAX_ENCODED_SIZE_INT))
        let result = ksbonjson_encodeToBuffer_uint(&state.context, UInt64(value))
        try throwIfEncodingFailed(result)
    }

    mutating func encode(_ value: UInt16) throws {
        try prepareToEncode()
        state.ensureCapacity(Int(KSBONJSON_MAX_ENCODED_SIZE_INT))
        let result = ksbonjson_encodeToBuffer_uint(&state.context, UInt64(value))
        try throwIfEncodingFailed(result)
    }

    mutating func encode(_ value: UInt32) throws {
        try prepareToEncode()
        state.ensureCapacity(Int(KSBONJSON_MAX_ENCODED_SIZE_INT))
        let result = ksbonjson_encodeToBuffer_uint(&state.context, UInt64(value))
        try throwIfEncodingFailed(result)
    }

    mutating func encode(_ value: UInt64) throws {
        try prepareToEncode()
        state.ensureCapacity(Int(KSBONJSON_MAX_ENCODED_SIZE_INT))
        let result = ksbonjson_encodeToBuffer_uint(&state.context, value)
        try throwIfEncodingFailed(result)
    }

    mutating func encode<T: Encodable>(_ value: T) throws {
        try prepareToEncode()
        if try state.tryBatchEncode(value) { return }
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
        state.ensureCapacity(Int(KSBONJSON_MAX_ENCODED_SIZE_NULL))
        let result = ksbonjson_encodeToBuffer_null(&state.context)
        try throwIfEncodingFailed(result)
    }

    mutating func encode(_ value: Bool) throws {
        state.ensureCapacity(Int(KSBONJSON_MAX_ENCODED_SIZE_BOOL))
        let result = ksbonjson_encodeToBuffer_bool(&state.context, value)
        try throwIfEncodingFailed(result)
    }

    mutating func encode(_ value: String) throws {
        let utf8Count = value.utf8.count
        state.ensureCapacity(Int(ksbonjson_maxEncodedSize_string(utf8Count)))

        // Use utf8Count instead of strlen to handle embedded NUL characters
        let result = value.withCString { cString in
            ksbonjson_encodeToBuffer_string(&state.context, cString, utf8Count)
        }
        try throwIfEncodingFailed(result)
    }

    mutating func encode(_ value: Double) throws {
        let encoder = _BufferEncoder(state: state, codingPath: codingPath)
        try encoder.encodeFloat(value)
    }

    mutating func encode(_ value: Float) throws {
        try encode(Double(value))
    }

    mutating func encode(_ value: Int) throws {
        state.ensureCapacity(Int(KSBONJSON_MAX_ENCODED_SIZE_INT))
        let result = ksbonjson_encodeToBuffer_int(&state.context, Int64(value))
        try throwIfEncodingFailed(result)
    }

    mutating func encode(_ value: Int8) throws {
        state.ensureCapacity(Int(KSBONJSON_MAX_ENCODED_SIZE_INT))
        let result = ksbonjson_encodeToBuffer_int(&state.context, Int64(value))
        try throwIfEncodingFailed(result)
    }

    mutating func encode(_ value: Int16) throws {
        state.ensureCapacity(Int(KSBONJSON_MAX_ENCODED_SIZE_INT))
        let result = ksbonjson_encodeToBuffer_int(&state.context, Int64(value))
        try throwIfEncodingFailed(result)
    }

    mutating func encode(_ value: Int32) throws {
        state.ensureCapacity(Int(KSBONJSON_MAX_ENCODED_SIZE_INT))
        let result = ksbonjson_encodeToBuffer_int(&state.context, Int64(value))
        try throwIfEncodingFailed(result)
    }

    mutating func encode(_ value: Int64) throws {
        state.ensureCapacity(Int(KSBONJSON_MAX_ENCODED_SIZE_INT))
        let result = ksbonjson_encodeToBuffer_int(&state.context, value)
        try throwIfEncodingFailed(result)
    }

    mutating func encode(_ value: UInt) throws {
        state.ensureCapacity(Int(KSBONJSON_MAX_ENCODED_SIZE_INT))
        let result = ksbonjson_encodeToBuffer_uint(&state.context, UInt64(value))
        try throwIfEncodingFailed(result)
    }

    mutating func encode(_ value: UInt8) throws {
        state.ensureCapacity(Int(KSBONJSON_MAX_ENCODED_SIZE_INT))
        let result = ksbonjson_encodeToBuffer_uint(&state.context, UInt64(value))
        try throwIfEncodingFailed(result)
    }

    mutating func encode(_ value: UInt16) throws {
        state.ensureCapacity(Int(KSBONJSON_MAX_ENCODED_SIZE_INT))
        let result = ksbonjson_encodeToBuffer_uint(&state.context, UInt64(value))
        try throwIfEncodingFailed(result)
    }

    mutating func encode(_ value: UInt32) throws {
        state.ensureCapacity(Int(KSBONJSON_MAX_ENCODED_SIZE_INT))
        let result = ksbonjson_encodeToBuffer_uint(&state.context, UInt64(value))
        try throwIfEncodingFailed(result)
    }

    mutating func encode(_ value: UInt64) throws {
        state.ensureCapacity(Int(KSBONJSON_MAX_ENCODED_SIZE_INT))
        let result = ksbonjson_encodeToBuffer_uint(&state.context, value)
        try throwIfEncodingFailed(result)
    }

    mutating func encode<T: Encodable>(_ value: T) throws {
        let encoder = _BufferEncoder(state: state, codingPath: codingPath)
        try encoder.encodeValue(value)
    }
}

// MARK: - Record Encoding Support

/// Sentinel error used when record encoding fails and needs fallback.
private struct _RecordEncodingFallback: Error {}

/// Protocol to detect arrays of Encodable elements without existential boxing.
private protocol _RecordCandidateArray {
    var _recordCandidateCount: Int { get }
    func _probeFirstElementKeys(using keyEncodingStrategy: BONJSONEncoder.KeyEncodingStrategy) throws -> [String]?
    func _encodeRecordElements(to state: _BufferEncoderState, codingPath: [CodingKey]) throws
}

extension Array: _RecordCandidateArray where Element: Encodable {
    fileprivate var _recordCandidateCount: Int { count }

    fileprivate func _probeFirstElementKeys(using keyEncodingStrategy: BONJSONEncoder.KeyEncodingStrategy) throws -> [String]? {
        guard let first = self.first else { return nil }
        // Skip types that encodeValue intercepts before encode(to:)
        if first is Date || first is Data || first is URL || first is Decimal { return nil }
        let probe = _KeyCaptureEncoder(keyEncodingStrategy: keyEncodingStrategy)
        try first.encode(to: probe)
        return probe.capturedKeys
    }

    fileprivate func _encodeRecordElements(to state: _BufferEncoderState, codingPath: [CodingKey]) throws {
        for (i, element) in self.enumerated() {
            // Begin record instance (def index 0)
            state.ensureCapacity(11) // type byte + ULEB128
            let result = ksbonjson_encodeToBuffer_beginRecordInstance(&state.context, 0)
            try throwIfEncodingFailed(result)

            let recordInstanceDepth = state.currentDepth

            // Encode element — container(keyedBy:) returns _RecordKeyedEncodingContainer
            let encoder = _BufferEncoder(
                state: state,
                codingPath: codingPath + [_BONJSONIndexKey(index: i)]
            )
            try encoder.encodeValue(element)

            // Close any deferred inner containers, then close the record instance
            try state.closeContainersToDepth(recordInstanceDepth)
            state.ensureCapacity(Int(KSBONJSON_MAX_ENCODED_SIZE_CONTAINER_END))
            let endResult = ksbonjson_encodeToBuffer_endContainer(&state.context)
            try throwIfEncodingFailed(endResult)
        }
    }
}

/// Lightweight encoder that captures key names without encoding values.
private final class _KeyCaptureEncoder: Encoder {
    let codingPath: [CodingKey] = []
    let userInfo: [CodingUserInfoKey: Any] = [:]
    let keyEncodingStrategy: BONJSONEncoder.KeyEncodingStrategy
    var capturedKeys: [String]?

    init(keyEncodingStrategy: BONJSONEncoder.KeyEncodingStrategy) {
        self.keyEncodingStrategy = keyEncodingStrategy
    }

    func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
        let container = _KeyCaptureKeyedContainer<Key>(encoder: self)
        return KeyedEncodingContainer(container)
    }

    func unkeyedContainer() -> UnkeyedEncodingContainer {
        return _KeyCaptureDummyUnkeyedContainer()
    }

    func singleValueContainer() -> SingleValueEncodingContainer {
        return _KeyCaptureDummySingleValueContainer()
    }
}

private struct _KeyCaptureKeyedContainer<Key: CodingKey>: KeyedEncodingContainerProtocol {
    let codingPath: [CodingKey] = []
    let encoder: _KeyCaptureEncoder

    init(encoder: _KeyCaptureEncoder) {
        self.encoder = encoder
    }

    private func convertedKey(_ key: Key) -> String {
        switch encoder.keyEncodingStrategy {
        case .useDefaultKeys:
            return key.stringValue
        case .convertToSnakeCase:
            return key.stringValue.convertToSnakeCase()
        case .custom(let converter):
            return converter(codingPath + [key]).stringValue
        }
    }

    private mutating func recordKey(_ key: Key) {
        if encoder.capturedKeys == nil {
            encoder.capturedKeys = []
        }
        encoder.capturedKeys!.append(convertedKey(key))
    }

    mutating func encodeNil(forKey key: Key) throws { recordKey(key) }
    mutating func encode(_ value: Bool, forKey key: Key) throws { recordKey(key) }
    mutating func encode(_ value: String, forKey key: Key) throws { recordKey(key) }
    mutating func encode(_ value: Double, forKey key: Key) throws { recordKey(key) }
    mutating func encode(_ value: Float, forKey key: Key) throws { recordKey(key) }
    mutating func encode(_ value: Int, forKey key: Key) throws { recordKey(key) }
    mutating func encode(_ value: Int8, forKey key: Key) throws { recordKey(key) }
    mutating func encode(_ value: Int16, forKey key: Key) throws { recordKey(key) }
    mutating func encode(_ value: Int32, forKey key: Key) throws { recordKey(key) }
    mutating func encode(_ value: Int64, forKey key: Key) throws { recordKey(key) }
    mutating func encode(_ value: UInt, forKey key: Key) throws { recordKey(key) }
    mutating func encode(_ value: UInt8, forKey key: Key) throws { recordKey(key) }
    mutating func encode(_ value: UInt16, forKey key: Key) throws { recordKey(key) }
    mutating func encode(_ value: UInt32, forKey key: Key) throws { recordKey(key) }
    mutating func encode(_ value: UInt64, forKey key: Key) throws { recordKey(key) }
    mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws { recordKey(key) }

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy keyType: NestedKey.Type,
        forKey key: Key
    ) -> KeyedEncodingContainer<NestedKey> {
        recordKey(key)
        return KeyedEncodingContainer(_KeyCaptureDummyKeyedContainer<NestedKey>())
    }

    mutating func nestedUnkeyedContainer(forKey key: Key) -> UnkeyedEncodingContainer {
        recordKey(key)
        return _KeyCaptureDummyUnkeyedContainer()
    }

    mutating func superEncoder() -> Encoder { _KeyCaptureDummyEncoder() }
    mutating func superEncoder(forKey key: Key) -> Encoder { recordKey(key); return _KeyCaptureDummyEncoder() }
}

/// Dummy containers for key capture probe — all operations are no-ops.
private struct _KeyCaptureDummyKeyedContainer<Key: CodingKey>: KeyedEncodingContainerProtocol {
    let codingPath: [CodingKey] = []
    mutating func encodeNil(forKey key: Key) throws {}
    mutating func encode(_ value: Bool, forKey key: Key) throws {}
    mutating func encode(_ value: String, forKey key: Key) throws {}
    mutating func encode(_ value: Double, forKey key: Key) throws {}
    mutating func encode(_ value: Float, forKey key: Key) throws {}
    mutating func encode(_ value: Int, forKey key: Key) throws {}
    mutating func encode(_ value: Int8, forKey key: Key) throws {}
    mutating func encode(_ value: Int16, forKey key: Key) throws {}
    mutating func encode(_ value: Int32, forKey key: Key) throws {}
    mutating func encode(_ value: Int64, forKey key: Key) throws {}
    mutating func encode(_ value: UInt, forKey key: Key) throws {}
    mutating func encode(_ value: UInt8, forKey key: Key) throws {}
    mutating func encode(_ value: UInt16, forKey key: Key) throws {}
    mutating func encode(_ value: UInt32, forKey key: Key) throws {}
    mutating func encode(_ value: UInt64, forKey key: Key) throws {}
    mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws {}
    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy keyType: NestedKey.Type, forKey key: Key) -> KeyedEncodingContainer<NestedKey> {
        KeyedEncodingContainer(_KeyCaptureDummyKeyedContainer<NestedKey>())
    }
    mutating func nestedUnkeyedContainer(forKey key: Key) -> UnkeyedEncodingContainer { _KeyCaptureDummyUnkeyedContainer() }
    mutating func superEncoder() -> Encoder { _KeyCaptureDummyEncoder() }
    mutating func superEncoder(forKey key: Key) -> Encoder { _KeyCaptureDummyEncoder() }
}

private struct _KeyCaptureDummyUnkeyedContainer: UnkeyedEncodingContainer {
    let codingPath: [CodingKey] = []
    var count: Int = 0
    mutating func encodeNil() throws {}
    mutating func encode(_ value: Bool) throws {}
    mutating func encode(_ value: String) throws {}
    mutating func encode(_ value: Double) throws {}
    mutating func encode(_ value: Float) throws {}
    mutating func encode(_ value: Int) throws {}
    mutating func encode(_ value: Int8) throws {}
    mutating func encode(_ value: Int16) throws {}
    mutating func encode(_ value: Int32) throws {}
    mutating func encode(_ value: Int64) throws {}
    mutating func encode(_ value: UInt) throws {}
    mutating func encode(_ value: UInt8) throws {}
    mutating func encode(_ value: UInt16) throws {}
    mutating func encode(_ value: UInt32) throws {}
    mutating func encode(_ value: UInt64) throws {}
    mutating func encode<T: Encodable>(_ value: T) throws {}
    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy keyType: NestedKey.Type) -> KeyedEncodingContainer<NestedKey> {
        KeyedEncodingContainer(_KeyCaptureDummyKeyedContainer<NestedKey>())
    }
    mutating func nestedUnkeyedContainer() -> UnkeyedEncodingContainer { _KeyCaptureDummyUnkeyedContainer() }
    mutating func superEncoder() -> Encoder { _KeyCaptureDummyEncoder() }
}

private struct _KeyCaptureDummySingleValueContainer: SingleValueEncodingContainer {
    let codingPath: [CodingKey] = []
    mutating func encodeNil() throws {}
    mutating func encode(_ value: Bool) throws {}
    mutating func encode(_ value: String) throws {}
    mutating func encode(_ value: Double) throws {}
    mutating func encode(_ value: Float) throws {}
    mutating func encode(_ value: Int) throws {}
    mutating func encode(_ value: Int8) throws {}
    mutating func encode(_ value: Int16) throws {}
    mutating func encode(_ value: Int32) throws {}
    mutating func encode(_ value: Int64) throws {}
    mutating func encode(_ value: UInt) throws {}
    mutating func encode(_ value: UInt8) throws {}
    mutating func encode(_ value: UInt16) throws {}
    mutating func encode(_ value: UInt32) throws {}
    mutating func encode(_ value: UInt64) throws {}
    mutating func encode<T: Encodable>(_ value: T) throws {}
}

private final class _KeyCaptureDummyEncoder: Encoder {
    let codingPath: [CodingKey] = []
    let userInfo: [CodingUserInfoKey: Any] = [:]
    func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
        KeyedEncodingContainer(_KeyCaptureDummyKeyedContainer<Key>())
    }
    func unkeyedContainer() -> UnkeyedEncodingContainer { _KeyCaptureDummyUnkeyedContainer() }
    func singleValueContainer() -> SingleValueEncodingContainer { _KeyCaptureDummySingleValueContainer() }
}

/// Keyed container for record instances — writes only values, not keys.
/// Keys must arrive in schema order; mismatch triggers fallback.
struct _RecordKeyedEncodingContainer<Key: CodingKey>: KeyedEncodingContainerProtocol {
    let state: _BufferEncoderState
    let codingPath: [CodingKey]
    let schema: [String]
    let containerDepth: Int
    private var nextKeyIndex: Int = 0

    init(state: _BufferEncoderState, codingPath: [CodingKey], schema: [String]) {
        self.state = state
        self.codingPath = codingPath
        self.schema = schema
        self.containerDepth = state.currentDepth
    }

    /// Close any deferred inner containers from previous nested values.
    private func closeDeferred() throws {
        try state.closeContainersToDepth(containerDepth)
    }

    private func convertedKey(_ key: Key) -> String {
        switch state.keyEncodingStrategy {
        case .useDefaultKeys:
            return key.stringValue
        case .convertToSnakeCase:
            return key.stringValue.convertToSnakeCase()
        case .custom(let converter):
            return converter(codingPath + [key]).stringValue
        }
    }

    /// Validate that the key matches the expected schema position.
    private mutating func validateKey(_ key: Key) throws {
        let keyString = convertedKey(key)
        guard nextKeyIndex < schema.count, schema[nextKeyIndex] == keyString else {
            throw _RecordEncodingFallback()
        }
        nextKeyIndex += 1
    }

    mutating func encodeNil(forKey key: Key) throws {
        try closeDeferred()
        try validateKey(key)
        state.ensureCapacity(Int(KSBONJSON_MAX_ENCODED_SIZE_NULL))
        let result = ksbonjson_encodeToBuffer_null(&state.context)
        try throwIfEncodingFailed(result)
    }

    mutating func encode(_ value: Bool, forKey key: Key) throws {
        try closeDeferred()
        try validateKey(key)
        state.ensureCapacity(Int(KSBONJSON_MAX_ENCODED_SIZE_BOOL))
        let result = ksbonjson_encodeToBuffer_bool(&state.context, value)
        try throwIfEncodingFailed(result)
    }

    mutating func encode(_ value: String, forKey key: Key) throws {
        try closeDeferred()
        try validateKey(key)
        let utf8Count = value.utf8.count
        state.ensureCapacity(Int(ksbonjson_maxEncodedSize_string(utf8Count)))
        let result = value.withCString { cString in
            ksbonjson_encodeToBuffer_string(&state.context, cString, utf8Count)
        }
        try throwIfEncodingFailed(result)
    }

    mutating func encode(_ value: Double, forKey key: Key) throws {
        try closeDeferred()
        try validateKey(key)
        let encoder = _BufferEncoder(state: state, codingPath: codingPath + [key])
        try encoder.encodeFloat(value)
    }

    mutating func encode(_ value: Float, forKey key: Key) throws {
        try encode(Double(value), forKey: key)
    }

    mutating func encode(_ value: Int, forKey key: Key) throws {
        try closeDeferred()
        try validateKey(key)
        state.ensureCapacity(Int(KSBONJSON_MAX_ENCODED_SIZE_INT))
        let result = ksbonjson_encodeToBuffer_int(&state.context, Int64(value))
        try throwIfEncodingFailed(result)
    }

    mutating func encode(_ value: Int8, forKey key: Key) throws {
        try closeDeferred()
        try validateKey(key)
        state.ensureCapacity(Int(KSBONJSON_MAX_ENCODED_SIZE_INT))
        let result = ksbonjson_encodeToBuffer_int(&state.context, Int64(value))
        try throwIfEncodingFailed(result)
    }

    mutating func encode(_ value: Int16, forKey key: Key) throws {
        try closeDeferred()
        try validateKey(key)
        state.ensureCapacity(Int(KSBONJSON_MAX_ENCODED_SIZE_INT))
        let result = ksbonjson_encodeToBuffer_int(&state.context, Int64(value))
        try throwIfEncodingFailed(result)
    }

    mutating func encode(_ value: Int32, forKey key: Key) throws {
        try closeDeferred()
        try validateKey(key)
        state.ensureCapacity(Int(KSBONJSON_MAX_ENCODED_SIZE_INT))
        let result = ksbonjson_encodeToBuffer_int(&state.context, Int64(value))
        try throwIfEncodingFailed(result)
    }

    mutating func encode(_ value: Int64, forKey key: Key) throws {
        try closeDeferred()
        try validateKey(key)
        state.ensureCapacity(Int(KSBONJSON_MAX_ENCODED_SIZE_INT))
        let result = ksbonjson_encodeToBuffer_int(&state.context, value)
        try throwIfEncodingFailed(result)
    }

    mutating func encode(_ value: UInt, forKey key: Key) throws {
        try closeDeferred()
        try validateKey(key)
        state.ensureCapacity(Int(KSBONJSON_MAX_ENCODED_SIZE_INT))
        let result = ksbonjson_encodeToBuffer_uint(&state.context, UInt64(value))
        try throwIfEncodingFailed(result)
    }

    mutating func encode(_ value: UInt8, forKey key: Key) throws {
        try closeDeferred()
        try validateKey(key)
        state.ensureCapacity(Int(KSBONJSON_MAX_ENCODED_SIZE_INT))
        let result = ksbonjson_encodeToBuffer_uint(&state.context, UInt64(value))
        try throwIfEncodingFailed(result)
    }

    mutating func encode(_ value: UInt16, forKey key: Key) throws {
        try closeDeferred()
        try validateKey(key)
        state.ensureCapacity(Int(KSBONJSON_MAX_ENCODED_SIZE_INT))
        let result = ksbonjson_encodeToBuffer_uint(&state.context, UInt64(value))
        try throwIfEncodingFailed(result)
    }

    mutating func encode(_ value: UInt32, forKey key: Key) throws {
        try closeDeferred()
        try validateKey(key)
        state.ensureCapacity(Int(KSBONJSON_MAX_ENCODED_SIZE_INT))
        let result = ksbonjson_encodeToBuffer_uint(&state.context, UInt64(value))
        try throwIfEncodingFailed(result)
    }

    mutating func encode(_ value: UInt64, forKey key: Key) throws {
        try closeDeferred()
        try validateKey(key)
        state.ensureCapacity(Int(KSBONJSON_MAX_ENCODED_SIZE_INT))
        let result = ksbonjson_encodeToBuffer_uint(&state.context, value)
        try throwIfEncodingFailed(result)
    }

    mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws {
        try closeDeferred()
        try validateKey(key)
        if try state.tryBatchEncode(value) { return }
        // Disable record mode for nested values
        let savedSchema = state.recordSchema
        state.recordSchema = nil
        let encoder = _BufferEncoder(state: state, codingPath: codingPath + [key])
        try encoder.encodeValue(value)
        state.recordSchema = savedSchema
    }

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy keyType: NestedKey.Type,
        forKey key: Key
    ) -> KeyedEncodingContainer<NestedKey> {
        do { try validateKey(key) } catch {
            assertionFailure("Record key validation failed in nestedContainer")
        }
        // Nested containers use regular encoding
        let savedSchema = state.recordSchema
        state.recordSchema = nil
        let container = _BufferKeyedEncodingContainer<NestedKey>(
            state: state,
            codingPath: codingPath + [key]
        )
        state.recordSchema = savedSchema
        return KeyedEncodingContainer(container)
    }

    mutating func nestedUnkeyedContainer(forKey key: Key) -> UnkeyedEncodingContainer {
        do { try validateKey(key) } catch {
            assertionFailure("Record key validation failed in nestedUnkeyedContainer")
        }
        return _BufferUnkeyedEncodingContainer(
            state: state,
            codingPath: codingPath + [key]
        )
    }

    mutating func superEncoder() -> Encoder {
        _BufferEncoder(state: state, codingPath: codingPath + [_BONJSONStringKey(stringValue: "super")])
    }

    mutating func superEncoder(forKey key: Key) -> Encoder {
        _BufferEncoder(state: state, codingPath: codingPath + [key])
    }
}

// MARK: - Helper Types

/// A coding key for string-based keys (used for "super" encoder).
struct _BONJSONStringKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }

    init(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) { nil }
}

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

// MARK: - Type Alias for Easy Migration

/// Type alias for `BONJSONEncoder` that enables easy migration from JSON.
///
/// To migrate from JSON to BONJSON, simply find-replace `JSON` with `BinaryJSON`:
/// - `JSONEncoder` becomes `BinaryJSONEncoder`
/// - `JSONDecoder` becomes `BinaryJSONDecoder`
public typealias BinaryJSONEncoder = BONJSONEncoder
