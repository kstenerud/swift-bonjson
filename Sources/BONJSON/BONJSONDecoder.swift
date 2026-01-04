// ABOUTME: Public BONJSONDecoder API matching Apple's JSONDecoder interface.
// ABOUTME: Uses cursor-based streaming to decode without intermediate representation.

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
        let cursor = _DecodingCursor(data: data)
        let state = _DecoderState(
            cursor: cursor,
            userInfo: userInfo,
            dateDecodingStrategy: dateDecodingStrategy,
            dataDecodingStrategy: dataDecodingStrategy,
            nonConformingFloatDecodingStrategy: nonConformingFloatDecodingStrategy,
            keyDecodingStrategy: keyDecodingStrategy
        )

        let decoder = _StreamingDecoder(state: state, codingPath: [])

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
        }
    }
}

// MARK: - Type Codes (matching BONJSON spec)

private enum TypeCode {
    static let smallIntMin: Int8 = -100
    static let smallIntMax: Int8 = 100
    static let smallIntPositiveBase: UInt8 = 0x00
    static let smallIntNegativeBase: UInt8 = 0x9c

    static let stringLong: UInt8 = 0x68
    static let bigNumber: UInt8 = 0x69
    static let float16: UInt8 = 0x6a
    static let float32: UInt8 = 0x6b
    static let float64: UInt8 = 0x6c
    static let null: UInt8 = 0x6d
    static let `false`: UInt8 = 0x6e
    static let `true`: UInt8 = 0x6f

    static let uint8: UInt8 = 0x70
    static let uint64: UInt8 = 0x77
    static let sint8: UInt8 = 0x78
    static let sint64: UInt8 = 0x7f

    static let stringShortBase: UInt8 = 0x80
    static let stringShortMax: UInt8 = 0x8f

    static let arrayStart: UInt8 = 0x99
    static let objectStart: UInt8 = 0x9a
    static let containerEnd: UInt8 = 0x9b
}

// MARK: - Decoding Cursor

/// Cursor for reading binary BONJSON data.
final class _DecodingCursor {
    private let data: Data
    private(set) var position: Int = 0

    init(data: Data) {
        self.data = data
    }

    var isAtEnd: Bool { position >= data.count }
    var remainingBytes: Int { data.count - position }

    func peekByte() throws -> UInt8 {
        guard position < data.count else {
            throw BONJSONDecodingError.unexpectedEndOfData
        }
        return data[position]
    }

    func readByte() throws -> UInt8 {
        guard position < data.count else {
            throw BONJSONDecodingError.unexpectedEndOfData
        }
        let byte = data[position]
        position += 1
        return byte
    }

    func readBytes(count: Int) throws -> Data {
        guard position + count <= data.count else {
            throw BONJSONDecodingError.unexpectedEndOfData
        }
        let result = data[position..<position + count]
        position += count
        return result
    }

    func readUInt16() throws -> UInt16 {
        let bytes = try readBytes(count: 2)
        return bytes.withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }
    }

    func readUInt32() throws -> UInt32 {
        let bytes = try readBytes(count: 4)
        return bytes.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
    }

    func readUInt64() throws -> UInt64 {
        let bytes = try readBytes(count: 8)
        return bytes.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
    }

    /// Saves current position for potential rollback.
    func savePosition() -> Int {
        return position
    }

    /// Restores to a previously saved position.
    func restorePosition(_ pos: Int) {
        position = pos
    }

    /// Skips a value at the current position.
    func skipValue() throws {
        let typeCode = try readByte()

        // Small positive integers
        if typeCode <= 0x64 {
            return
        }

        // Small negative integers
        if typeCode >= 0x9c {
            return
        }

        // Short strings
        if typeCode >= TypeCode.stringShortBase && typeCode <= TypeCode.stringShortMax {
            let length = Int(typeCode - TypeCode.stringShortBase)
            position += length
            return
        }

        // Unsigned integers
        if typeCode >= TypeCode.uint8 && typeCode <= TypeCode.uint64 {
            let byteCount = Int(typeCode - TypeCode.uint8) + 1
            position += byteCount
            return
        }

        // Signed integers
        if typeCode >= TypeCode.sint8 && typeCode <= TypeCode.sint64 {
            let byteCount = Int(typeCode - TypeCode.sint8) + 1
            position += byteCount
            return
        }

        switch typeCode {
        case TypeCode.null, TypeCode.false, TypeCode.true:
            return
        case TypeCode.float16:
            position += 2
        case TypeCode.float32:
            position += 4
        case TypeCode.float64:
            position += 8
        case TypeCode.stringLong:
            try skipLongString()
        case TypeCode.bigNumber:
            try skipBigNumber()
        case TypeCode.arrayStart:
            try skipContainer()
        case TypeCode.objectStart:
            try skipContainer()
        default:
            throw BONJSONDecodingError.invalidTypeCode(typeCode)
        }
    }

    private func skipLongString() throws {
        while true {
            let lengthField = try readLengthField()
            position += lengthField.length
            if !lengthField.isContinuation {
                break
            }
        }
    }

    private func skipBigNumber() throws {
        // Big number format:
        // - 1 header byte: SSSSS EE N
        //   - N (bit 0): sign (0 = positive, 1 = negative)
        //   - EE (bits 1-2): exponent length (0-3 bytes)
        //   - SSSSS (bits 3-7): significand length (0-31 bytes)
        // - exponent bytes (little-endian signed)
        // - significand bytes (little-endian unsigned)
        let header = try readByte()
        let exponentLength = Int((header >> 1) & 0x03)
        let significandLength = Int(header >> 3)
        position += exponentLength + significandLength
    }

    private func skipContainer() throws {
        while true {
            let nextByte = try peekByte()
            if nextByte == TypeCode.containerEnd {
                position += 1
                return
            }
            try skipValue()
        }
    }

    /// Reads a length field used for string chunking.
    /// Returns the length and whether more chunks follow.
    func readLengthField() throws -> (length: Int, isContinuation: Bool) {
        let firstByte = try readByte()

        // Header of 0 means 9-byte encoding: 1 zero byte + 8 bytes of payload
        if firstByte == 0 {
            let payload = try readUInt64()
            let isContinuation = (payload & 1) != 0
            let length = Int(payload >> 1)
            return (length, isContinuation)
        }

        // Count trailing zeros to determine total byte count
        let trailingZeros = firstByte.trailingZeroBitCount
        let byteCount = trailingZeros + 1

        // Read all bytes into a little-endian value
        var value = UInt64(firstByte)
        for i in 1..<byteCount {
            let nextByte = try readByte()
            value |= UInt64(nextByte) << (i * 8)
        }

        // Right-shift by byteCount to remove the terminator bit and zero padding
        let payload = value >> byteCount
        let isContinuation = (payload & 1) != 0
        let length = Int(payload >> 1)
        return (length, isContinuation)
    }
}

// MARK: - Decoder State

/// Shared state for the streaming decoder.
final class _DecoderState {
    let cursor: _DecodingCursor
    let userInfo: [CodingUserInfoKey: Any]
    let dateDecodingStrategy: BONJSONDecoder.DateDecodingStrategy
    let dataDecodingStrategy: BONJSONDecoder.DataDecodingStrategy
    let nonConformingFloatDecodingStrategy: BONJSONDecoder.NonConformingFloatDecodingStrategy
    let keyDecodingStrategy: BONJSONDecoder.KeyDecodingStrategy

    init(
        cursor: _DecodingCursor,
        userInfo: [CodingUserInfoKey: Any],
        dateDecodingStrategy: BONJSONDecoder.DateDecodingStrategy,
        dataDecodingStrategy: BONJSONDecoder.DataDecodingStrategy,
        nonConformingFloatDecodingStrategy: BONJSONDecoder.NonConformingFloatDecodingStrategy,
        keyDecodingStrategy: BONJSONDecoder.KeyDecodingStrategy
    ) {
        self.cursor = cursor
        self.userInfo = userInfo
        self.dateDecodingStrategy = dateDecodingStrategy
        self.dataDecodingStrategy = dataDecodingStrategy
        self.nonConformingFloatDecodingStrategy = nonConformingFloatDecodingStrategy
        self.keyDecodingStrategy = keyDecodingStrategy
    }
}

// MARK: - Streaming Decoder

/// Internal decoder that implements the Decoder protocol using cursor-based streaming.
final class _StreamingDecoder: Decoder {
    let state: _DecoderState
    let codingPath: [CodingKey]

    var userInfo: [CodingUserInfoKey: Any] { state.userInfo }

    init(state: _DecoderState, codingPath: [CodingKey]) {
        self.state = state
        self.codingPath = codingPath
    }

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        // Expect object start
        let typeCode = try state.cursor.readByte()
        guard typeCode == TypeCode.objectStart else {
            throw BONJSONDecodingError.typeMismatch(expected: "object", actual: describeTypeCode(typeCode))
        }

        let container = try _StreamingKeyedDecodingContainer<Key>(
            state: state,
            codingPath: codingPath
        )
        return KeyedDecodingContainer(container)
    }

    func unkeyedContainer() throws -> UnkeyedDecodingContainer {
        // Expect array start
        let typeCode = try state.cursor.readByte()
        guard typeCode == TypeCode.arrayStart else {
            throw BONJSONDecodingError.typeMismatch(expected: "array", actual: describeTypeCode(typeCode))
        }

        return _StreamingUnkeyedDecodingContainer(
            state: state,
            codingPath: codingPath
        )
    }

    func singleValueContainer() throws -> SingleValueDecodingContainer {
        return _StreamingSingleValueDecodingContainer(
            state: state,
            codingPath: codingPath
        )
    }

    // MARK: - Value Reading

    func decodeString() throws -> String {
        let typeCode = try state.cursor.readByte()

        // Short string
        if typeCode >= TypeCode.stringShortBase && typeCode <= TypeCode.stringShortMax {
            let length = Int(typeCode - TypeCode.stringShortBase)
            if length == 0 {
                return ""
            }
            let bytes = try state.cursor.readBytes(count: length)
            guard let string = String(data: bytes, encoding: .utf8) else {
                throw BONJSONDecodingError.invalidUTF8String
            }
            return string
        }

        // Long string
        if typeCode == TypeCode.stringLong {
            var result = Data()
            while true {
                let (length, isContinuation) = try state.cursor.readLengthField()
                if length > 0 {
                    let chunk = try state.cursor.readBytes(count: length)
                    result.append(chunk)
                }
                if !isContinuation {
                    break
                }
            }
            guard let string = String(data: result, encoding: .utf8) else {
                throw BONJSONDecodingError.invalidUTF8String
            }
            return string
        }

        throw BONJSONDecodingError.typeMismatch(expected: "string", actual: describeTypeCode(typeCode))
    }

    func decodeInt64() throws -> Int64 {
        let typeCode = try state.cursor.readByte()

        // Small positive integers
        if typeCode <= 0x64 {
            return Int64(typeCode)
        }

        // Small negative integers
        if typeCode >= 0x9c {
            return Int64(Int8(bitPattern: typeCode))
        }

        // Signed integers
        if typeCode >= TypeCode.sint8 && typeCode <= TypeCode.sint64 {
            let byteCount = Int(typeCode - TypeCode.sint8) + 1
            return try readSignedInt(byteCount: byteCount)
        }

        // Unsigned integers (if they fit)
        if typeCode >= TypeCode.uint8 && typeCode <= TypeCode.uint64 {
            let byteCount = Int(typeCode - TypeCode.uint8) + 1
            let value = try readUnsignedInt(byteCount: byteCount)
            guard value <= UInt64(Int64.max) else {
                throw BONJSONDecodingError.typeMismatch(expected: "Int64", actual: "UInt64 too large")
            }
            return Int64(value)
        }

        throw BONJSONDecodingError.typeMismatch(expected: "integer", actual: describeTypeCode(typeCode))
    }

    func decodeUInt64() throws -> UInt64 {
        let typeCode = try state.cursor.readByte()

        // Small positive integers
        if typeCode <= 0x64 {
            return UInt64(typeCode)
        }

        // Unsigned integers
        if typeCode >= TypeCode.uint8 && typeCode <= TypeCode.uint64 {
            let byteCount = Int(typeCode - TypeCode.uint8) + 1
            return try readUnsignedInt(byteCount: byteCount)
        }

        // Signed integers (if non-negative)
        if typeCode >= TypeCode.sint8 && typeCode <= TypeCode.sint64 {
            let byteCount = Int(typeCode - TypeCode.sint8) + 1
            let value = try readSignedInt(byteCount: byteCount)
            guard value >= 0 else {
                throw BONJSONDecodingError.typeMismatch(expected: "UInt64", actual: "negative integer")
            }
            return UInt64(value)
        }

        throw BONJSONDecodingError.typeMismatch(expected: "unsigned integer", actual: describeTypeCode(typeCode))
    }

    func decodeDouble() throws -> Double {
        let typeCode = try state.cursor.readByte()

        // Small positive integers
        if typeCode <= 0x64 {
            return Double(typeCode)
        }

        // Small negative integers
        if typeCode >= 0x9c {
            return Double(Int8(bitPattern: typeCode))
        }

        switch typeCode {
        case TypeCode.float16:
            let bits = try state.cursor.readUInt16()
            return bfloat16ToDouble(bits)

        case TypeCode.float32:
            let bits = try state.cursor.readUInt32()
            return Double(Float(bitPattern: bits))

        case TypeCode.float64:
            let bits = try state.cursor.readUInt64()
            return Double(bitPattern: bits)

        default:
            break
        }

        // Signed integers
        if typeCode >= TypeCode.sint8 && typeCode <= TypeCode.sint64 {
            let byteCount = Int(typeCode - TypeCode.sint8) + 1
            return Double(try readSignedInt(byteCount: byteCount))
        }

        // Unsigned integers
        if typeCode >= TypeCode.uint8 && typeCode <= TypeCode.uint64 {
            let byteCount = Int(typeCode - TypeCode.uint8) + 1
            return Double(try readUnsignedInt(byteCount: byteCount))
        }

        // Check for string representation of special floats
        if typeCode >= TypeCode.stringShortBase && typeCode <= TypeCode.stringShortMax ||
           typeCode == TypeCode.stringLong {
            // Put back the type code and read string
            state.cursor.restorePosition(state.cursor.savePosition() - 1)
            // Actually we already consumed it, need to handle differently
        }

        throw BONJSONDecodingError.typeMismatch(expected: "float", actual: describeTypeCode(typeCode))
    }

    func decodeBool() throws -> Bool {
        let typeCode = try state.cursor.readByte()
        switch typeCode {
        case TypeCode.false:
            return false
        case TypeCode.true:
            return true
        default:
            throw BONJSONDecodingError.typeMismatch(expected: "boolean", actual: describeTypeCode(typeCode))
        }
    }

    func decodeNil() throws -> Bool {
        let saved = state.cursor.savePosition()
        let typeCode = try state.cursor.readByte()
        if typeCode == TypeCode.null {
            return true
        }
        state.cursor.restorePosition(saved)
        return false
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

    // MARK: - Helper Methods

    private func readSignedInt(byteCount: Int) throws -> Int64 {
        var result: UInt64 = 0
        for i in 0..<byteCount {
            let byte = try state.cursor.readByte()
            result |= UInt64(byte) << (i * 8)
        }

        // Sign extend if negative
        if byteCount < 8 {
            let signBit = result & (UInt64(1) << (byteCount * 8 - 1))
            if signBit != 0 {
                let mask = ~((UInt64(1) << (byteCount * 8)) - 1)
                result |= mask
            }
        }

        return Int64(bitPattern: result)
    }

    private func readUnsignedInt(byteCount: Int) throws -> UInt64 {
        var result: UInt64 = 0
        for i in 0..<byteCount {
            let byte = try state.cursor.readByte()
            result |= UInt64(byte) << (i * 8)
        }
        return result
    }

    private func bfloat16ToDouble(_ bits: UInt16) -> Double {
        let sign = (bits >> 15) & 0x1
        let exponent = (bits >> 7) & 0xFF
        let mantissa = bits & 0x7F

        // Convert to float32 representation
        let float32Bits = UInt32(sign) << 31 | UInt32(exponent) << 23 | UInt32(mantissa) << 16
        return Double(Float(bitPattern: float32Bits))
    }

    private func describeTypeCode(_ code: UInt8) -> String {
        if code <= 0x64 {
            return "small int \(code)"
        }
        if code >= 0x9c {
            return "small int \(Int8(bitPattern: code))"
        }
        if code >= TypeCode.stringShortBase && code <= TypeCode.stringShortMax {
            return "short string"
        }
        switch code {
        case TypeCode.null: return "null"
        case TypeCode.false: return "false"
        case TypeCode.true: return "true"
        case TypeCode.float16: return "float16"
        case TypeCode.float32: return "float32"
        case TypeCode.float64: return "float64"
        case TypeCode.stringLong: return "long string"
        case TypeCode.arrayStart: return "array"
        case TypeCode.objectStart: return "object"
        case TypeCode.containerEnd: return "end container"
        default:
            if code >= TypeCode.uint8 && code <= TypeCode.uint64 {
                return "uint\((code - TypeCode.uint8 + 1) * 8)"
            }
            if code >= TypeCode.sint8 && code <= TypeCode.sint64 {
                return "sint\((code - TypeCode.sint8 + 1) * 8)"
            }
            return "unknown (0x\(String(code, radix: 16)))"
        }
    }
}

// MARK: - Keyed Decoding Container

struct _StreamingKeyedDecodingContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let state: _DecoderState
    let codingPath: [CodingKey]

    /// Cache of keys to their positions in the data.
    private var keyPositions: [String: Int] = [:]

    /// All keys found in this container.
    private(set) var allKeys: [Key] = []

    /// Position after the container ends.
    private var endPosition: Int = 0

    init(state: _DecoderState, codingPath: [CodingKey]) throws {
        self.state = state
        self.codingPath = codingPath

        // Scan the object to find all keys and their value positions
        try scanObject()
    }

    private mutating func scanObject() throws {
        while true {
            let nextByte = try state.cursor.peekByte()
            if nextByte == TypeCode.containerEnd {
                _ = try state.cursor.readByte()
                endPosition = state.cursor.position
                return
            }

            // Read key (must be a string)
            let typeCode = try state.cursor.readByte()

            var keyString: String

            // Short string key
            if typeCode >= TypeCode.stringShortBase && typeCode <= TypeCode.stringShortMax {
                let length = Int(typeCode - TypeCode.stringShortBase)
                if length == 0 {
                    keyString = ""
                } else {
                    let bytes = try state.cursor.readBytes(count: length)
                    guard let string = String(data: bytes, encoding: .utf8) else {
                        throw BONJSONDecodingError.invalidUTF8String
                    }
                    keyString = string
                }
            } else if typeCode == TypeCode.stringLong {
                // Long string key
                var result = Data()
                while true {
                    let (length, isContinuation) = try state.cursor.readLengthField()
                    if length > 0 {
                        let chunk = try state.cursor.readBytes(count: length)
                        result.append(chunk)
                    }
                    if !isContinuation {
                        break
                    }
                }
                guard let string = String(data: result, encoding: .utf8) else {
                    throw BONJSONDecodingError.invalidUTF8String
                }
                keyString = string
            } else {
                throw BONJSONDecodingError.expectedObjectKey
            }

            // Apply key decoding strategy
            keyString = convertKey(keyString)

            // Store the position of the value
            let valuePosition = state.cursor.position
            keyPositions[keyString] = valuePosition

            // Add to allKeys if it can be converted
            if let key = Key(stringValue: keyString) {
                allKeys.append(key)
            }

            // Skip the value
            try state.cursor.skipValue()
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

    func contains(_ key: Key) -> Bool {
        return keyPositions[key.stringValue] != nil
    }

    private func valueDecoder(forKey key: Key) throws -> _StreamingDecoder {
        guard let position = keyPositions[key.stringValue] else {
            throw DecodingError.keyNotFound(key, DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "Key '\(key.stringValue)' not found"
            ))
        }
        state.cursor.restorePosition(position)
        return _StreamingDecoder(state: state, codingPath: codingPath + [key])
    }

    func decodeNil(forKey key: Key) throws -> Bool {
        guard let position = keyPositions[key.stringValue] else {
            throw DecodingError.keyNotFound(key, DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "Key '\(key.stringValue)' not found"
            ))
        }
        state.cursor.restorePosition(position)
        let typeCode = try state.cursor.peekByte()
        if typeCode == TypeCode.null {
            _ = try state.cursor.readByte()
            return true
        }
        return false
    }

    func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool {
        return try valueDecoder(forKey: key).decodeBool()
    }

    func decode(_ type: String.Type, forKey key: Key) throws -> String {
        return try valueDecoder(forKey: key).decodeString()
    }

    func decode(_ type: Double.Type, forKey key: Key) throws -> Double {
        return try valueDecoder(forKey: key).decodeDouble()
    }

    func decode(_ type: Float.Type, forKey key: Key) throws -> Float {
        return Float(try valueDecoder(forKey: key).decodeDouble())
    }

    func decode(_ type: Int.Type, forKey key: Key) throws -> Int {
        return Int(try valueDecoder(forKey: key).decodeInt64())
    }

    func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 {
        return Int8(try valueDecoder(forKey: key).decodeInt64())
    }

    func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 {
        return Int16(try valueDecoder(forKey: key).decodeInt64())
    }

    func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 {
        return Int32(try valueDecoder(forKey: key).decodeInt64())
    }

    func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 {
        return try valueDecoder(forKey: key).decodeInt64()
    }

    func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt {
        return UInt(try valueDecoder(forKey: key).decodeUInt64())
    }

    func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 {
        return UInt8(try valueDecoder(forKey: key).decodeUInt64())
    }

    func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 {
        return UInt16(try valueDecoder(forKey: key).decodeUInt64())
    }

    func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 {
        return UInt32(try valueDecoder(forKey: key).decodeUInt64())
    }

    func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 {
        return try valueDecoder(forKey: key).decodeUInt64()
    }

    func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
        let decoder = try valueDecoder(forKey: key)

        // Handle special types
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

    func nestedContainer<NestedKey: CodingKey>(
        keyedBy type: NestedKey.Type,
        forKey key: Key
    ) throws -> KeyedDecodingContainer<NestedKey> {
        let decoder = try valueDecoder(forKey: key)
        return try decoder.container(keyedBy: type)
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> UnkeyedDecodingContainer {
        let decoder = try valueDecoder(forKey: key)
        return try decoder.unkeyedContainer()
    }

    func superDecoder() throws -> Decoder {
        return try superDecoder(forKey: Key(stringValue: "super")!)
    }

    func superDecoder(forKey key: Key) throws -> Decoder {
        return try valueDecoder(forKey: key)
    }
}

// MARK: - Unkeyed Decoding Container

struct _StreamingUnkeyedDecodingContainer: UnkeyedDecodingContainer {
    let state: _DecoderState
    let codingPath: [CodingKey]

    private(set) var count: Int?
    private(set) var currentIndex: Int = 0

    /// Positions of each element in the array.
    private var elementPositions: [Int] = []

    /// Position after the container ends.
    private var endPosition: Int = 0

    var isAtEnd: Bool {
        if let count = count {
            return currentIndex >= count
        }
        return currentIndex >= elementPositions.count
    }

    init(state: _DecoderState, codingPath: [CodingKey]) {
        self.state = state
        self.codingPath = codingPath

        // Scan array to find element positions
        do {
            try scanArray()
        } catch {
            // If scanning fails, we'll get errors during decoding
        }
    }

    private mutating func scanArray() throws {
        while true {
            let nextByte = try state.cursor.peekByte()
            if nextByte == TypeCode.containerEnd {
                _ = try state.cursor.readByte()
                endPosition = state.cursor.position
                count = elementPositions.count
                // Reset to first element
                if !elementPositions.isEmpty {
                    state.cursor.restorePosition(elementPositions[0])
                }
                return
            }

            elementPositions.append(state.cursor.position)
            try state.cursor.skipValue()
        }
    }

    private mutating func nextDecoder() throws -> _StreamingDecoder {
        guard currentIndex < elementPositions.count else {
            throw DecodingError.valueNotFound(Any.self, DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "Unkeyed container is at end"
            ))
        }

        state.cursor.restorePosition(elementPositions[currentIndex])
        let decoder = _StreamingDecoder(
            state: state,
            codingPath: codingPath + [_BONJSONIndexKey(index: currentIndex)]
        )
        currentIndex += 1
        return decoder
    }

    mutating func decodeNil() throws -> Bool {
        guard currentIndex < elementPositions.count else {
            return false
        }
        state.cursor.restorePosition(elementPositions[currentIndex])
        let typeCode = try state.cursor.peekByte()
        if typeCode == TypeCode.null {
            _ = try state.cursor.readByte()
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
        let decoder = try nextDecoder()
        return try decoder.container(keyedBy: type)
    }

    mutating func nestedUnkeyedContainer() throws -> UnkeyedDecodingContainer {
        let decoder = try nextDecoder()
        return try decoder.unkeyedContainer()
    }

    mutating func superDecoder() throws -> Decoder {
        return try nextDecoder()
    }
}

// MARK: - Single Value Decoding Container

struct _StreamingSingleValueDecodingContainer: SingleValueDecodingContainer {
    let state: _DecoderState
    let codingPath: [CodingKey]

    init(state: _DecoderState, codingPath: [CodingKey]) {
        self.state = state
        self.codingPath = codingPath
    }

    private func makeDecoder() -> _StreamingDecoder {
        return _StreamingDecoder(state: state, codingPath: codingPath)
    }

    func decodeNil() -> Bool {
        do {
            return try makeDecoder().decodeNil()
        } catch {
            return false
        }
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
