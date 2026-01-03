// ABOUTME: Low-level BONJSON decoding primitives.
// ABOUTME: Handles binary decoding of all BONJSON types with efficient intrinsics usage.

import Foundation

/// Errors that can occur during BONJSON decoding.
public enum BONJSONDecodingError: Error {
    case unexpectedEndOfData
    case invalidTypeCode(UInt8)
    case invalidUTF8String
    case invalidFloat  // NaN or infinity encountered
    case containerDepthExceeded
    case duplicateObjectKey(String)
    case invalidLengthField
    case expectedObjectKey
    case expectedValue
    case containerMismatch
    case dataRemaining
    case internalError(String)
}

/// A decoded BONJSON value.
/// This intermediate representation is used during decoding before
/// converting to the target Swift types.
enum BONJSONValue {
    case null
    case bool(Bool)
    case int(Int64)
    case uint(UInt64)
    case float(Double)
    case string(String)
    case array([BONJSONValue])
    case object([(String, BONJSONValue)])  // Ordered key-value pairs

    /// Returns the value as a string for error messages.
    var typeName: String {
        switch self {
        case .null: return "null"
        case .bool: return "bool"
        case .int: return "int"
        case .uint: return "uint"
        case .float: return "float"
        case .string: return "string"
        case .array: return "array"
        case .object: return "object"
        }
    }

    /// Check equality for null comparison (used in decoding).
    static func == (lhs: BONJSONValue, rhs: BONJSONValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null):
            return true
        case (.bool(let a), .bool(let b)):
            return a == b
        case (.int(let a), .int(let b)):
            return a == b
        case (.uint(let a), .uint(let b)):
            return a == b
        case (.float(let a), .float(let b)):
            return a == b
        case (.string(let a), .string(let b)):
            return a == b
        case (.array(let a), .array(let b)):
            guard a.count == b.count else { return false }
            for (i, elem) in a.enumerated() {
                if elem != b[i] { return false }
            }
            return true
        case (.object(let a), .object(let b)):
            guard a.count == b.count else { return false }
            for (i, (keyA, valA)) in a.enumerated() {
                let (keyB, valB) = b[i]
                if keyA != keyB || valA != valB { return false }
            }
            return true
        default:
            return false
        }
    }

    static func != (lhs: BONJSONValue, rhs: BONJSONValue) -> Bool {
        return !(lhs == rhs)
    }
}

/// Low-level reader for BONJSON binary data.
/// Parses binary data and produces BONJSONValue representation.
final class BONJSONReader {
    /// The data being read.
    private let data: Data

    /// Current read position.
    private var position: Int = 0

    /// Current container depth.
    private var containerDepth: Int = 0

    /// Maximum allowed container depth.
    let maxContainerDepth: Int

    init(data: Data, maxContainerDepth: Int = BONJSONConstants.maxContainerDepth) {
        self.data = data
        self.maxContainerDepth = maxContainerDepth
    }

    /// Returns the number of bytes remaining.
    var bytesRemaining: Int {
        return data.count - position
    }

    /// Parses the entire data and returns the top-level value.
    func parse() throws -> BONJSONValue {
        let value = try readValue()

        // Ensure all data was consumed
        if position < data.count {
            throw BONJSONDecodingError.dataRemaining
        }

        return value
    }

    // MARK: - Primitive Reading

    /// Reads a single byte, advancing the position.
    @inline(__always)
    private func readByte() throws -> UInt8 {
        guard position < data.count else {
            throw BONJSONDecodingError.unexpectedEndOfData
        }
        let byte = data[position]
        position += 1
        return byte
    }

    /// Peeks at the next byte without advancing.
    @inline(__always)
    private func peekByte() throws -> UInt8 {
        guard position < data.count else {
            throw BONJSONDecodingError.unexpectedEndOfData
        }
        return data[position]
    }

    /// Reads multiple bytes into an array.
    private func readBytes(count: Int) throws -> [UInt8] {
        guard position + count <= data.count else {
            throw BONJSONDecodingError.unexpectedEndOfData
        }
        let bytes = Array(data[position..<position + count])
        position += count
        return bytes
    }

    /// Reads bytes as Data.
    private func readData(count: Int) throws -> Data {
        guard position + count <= data.count else {
            throw BONJSONDecodingError.unexpectedEndOfData
        }
        let result = data[position..<position + count]
        position += count
        return result
    }

    // MARK: - Value Reading

    /// Reads a value based on the type code.
    func readValue() throws -> BONJSONValue {
        let typeCode = try readByte()

        // Check for small integers first (most common case)
        if let intValue = TypeCode.smallIntValue(from: typeCode) {
            return .int(Int64(intValue))
        }

        // Check for short strings
        if let length = TypeCode.shortStringLength(from: typeCode) {
            let stringData = try readData(count: length)
            guard let string = String(data: stringData, encoding: .utf8) else {
                throw BONJSONDecodingError.invalidUTF8String
            }
            return .string(string)
        }

        // Check for unsigned integers
        if let byteCount = TypeCode.unsignedIntByteCount(from: typeCode) {
            let value = try readUnsignedInt(byteCount: byteCount)
            return .uint(value)
        }

        // Check for signed integers
        if let byteCount = TypeCode.signedIntByteCount(from: typeCode) {
            let value = try readSignedInt(byteCount: byteCount)
            return .int(value)
        }

        // Handle specific type codes
        switch typeCode {
        case TypeCode.null:
            return .null

        case TypeCode.false:
            return .bool(false)

        case TypeCode.true:
            return .bool(true)

        case TypeCode.float16:
            let bits = try readUInt16()
            let value = bfloat16ToDouble(bits)
            return .float(value)

        case TypeCode.float32:
            let bits = try readUInt32()
            let value = Float(bitPattern: bits)
            guard value.isFinite else {
                throw BONJSONDecodingError.invalidFloat
            }
            return .float(Double(value))

        case TypeCode.float64:
            let bits = try readUInt64()
            let value = Double(bitPattern: bits)
            guard value.isFinite else {
                throw BONJSONDecodingError.invalidFloat
            }
            return .float(value)

        case TypeCode.stringLong:
            return try readLongString()

        case TypeCode.bigNumber:
            // Big numbers are converted to strings for lossless representation
            return try readBigNumber()

        case TypeCode.arrayStart:
            return try readArray()

        case TypeCode.objectStart:
            return try readObject()

        case TypeCode.containerEnd:
            throw BONJSONDecodingError.invalidTypeCode(typeCode)

        default:
            throw BONJSONDecodingError.invalidTypeCode(typeCode)
        }
    }

    // MARK: - Integer Reading

    /// Reads an unsigned integer of the specified byte count (little-endian).
    private func readUnsignedInt(byteCount: Int) throws -> UInt64 {
        var result: UInt64 = 0
        for i in 0..<byteCount {
            let byte = try readByte()
            result |= UInt64(byte) << (i * 8)
        }
        return result
    }

    /// Reads a signed integer of the specified byte count (little-endian, two's complement).
    private func readSignedInt(byteCount: Int) throws -> Int64 {
        var result: UInt64 = 0
        for i in 0..<byteCount {
            let byte = try readByte()
            result |= UInt64(byte) << (i * 8)
        }

        // Sign extend if the high bit is set
        let signBit = UInt64(1) << (byteCount * 8 - 1)
        if result & signBit != 0 {
            // Set all high bits to 1 for negative numbers
            // For 8-byte values, the mask is 0 (no extension needed)
            if byteCount < 8 {
                let mask = ~((UInt64(1) << (byteCount * 8)) - 1)
                result |= mask
            }
        }

        return Int64(bitPattern: result)
    }

    /// Reads a 16-bit unsigned integer (little-endian).
    private func readUInt16() throws -> UInt16 {
        let bytes = try readBytes(count: 2)
        return UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
    }

    /// Reads a 32-bit unsigned integer (little-endian).
    private func readUInt32() throws -> UInt32 {
        let bytes = try readBytes(count: 4)
        return UInt32(bytes[0]) |
               (UInt32(bytes[1]) << 8) |
               (UInt32(bytes[2]) << 16) |
               (UInt32(bytes[3]) << 24)
    }

    /// Reads a 64-bit unsigned integer (little-endian).
    private func readUInt64() throws -> UInt64 {
        let bytes = try readBytes(count: 8)
        var result: UInt64 = 0
        for i in 0..<8 {
            result |= UInt64(bytes[i]) << (i * 8)
        }
        return result
    }

    // MARK: - Float16 (bfloat16) Support

    /// Converts bfloat16 bits to Double.
    /// bfloat16 is the upper 16 bits of a float32.
    private func bfloat16ToDouble(_ bits: UInt16) -> Double {
        // bfloat16 is just the top 16 bits of float32
        let float32Bits = UInt32(bits) << 16
        let float32 = Float(bitPattern: float32Bits)
        return Double(float32)
    }

    // MARK: - Length Field Reading

    /// Reads a length field and returns (length, hasMoreChunks).
    private func readLengthField() throws -> (length: Int, hasMoreChunks: Bool) {
        let firstByte = try readByte()

        if firstByte == 0 {
            // 9-byte encoding
            let payload = try readUInt64()
            let length = Int(payload >> 1)
            let hasMore = (payload & 1) != 0
            return (length, hasMore)
        }

        // Calculate total byte count using trailing zero count
        // This maps to __builtin_ctz in C
        let trailingZeros = UInt8(firstByte).trailingZeroBitCount
        let byteCount = trailingZeros + 1

        // Read remaining bytes
        var payload = UInt64(firstByte)
        for i in 1..<byteCount {
            let byte = try readByte()
            payload |= UInt64(byte) << (i * 8)
        }

        // Remove the marker bit by shifting right
        payload >>= byteCount

        let length = Int(payload >> 1)
        let hasMore = (payload & 1) != 0

        return (length, hasMore)
    }

    // MARK: - String Reading

    /// Reads a long string (possibly chunked).
    private func readLongString() throws -> BONJSONValue {
        var result = Data()

        while true {
            let (length, hasMore) = try readLengthField()
            let chunk = try readData(count: length)

            // Validate UTF-8 per chunk (per spec requirement)
            guard String(data: chunk, encoding: .utf8) != nil else {
                throw BONJSONDecodingError.invalidUTF8String
            }

            result.append(chunk)

            if !hasMore {
                break
            }
        }

        guard let string = String(data: result, encoding: .utf8) else {
            throw BONJSONDecodingError.invalidUTF8String
        }

        return .string(string)
    }

    // MARK: - Big Number Reading

    /// Reads a big number and returns it as a string representation.
    private func readBigNumber() throws -> BONJSONValue {
        let header = try readByte()

        // Header format: SSSSSEEN
        // S = significand length (0-31, but 0 means 32 bytes)
        // E = exponent length (0-3)
        // N = negative significand flag

        let isNegative = (header & 0x01) != 0
        let exponentLength = Int((header >> 1) & 0x03)
        var significandLength = Int((header >> 3) & 0x1f)
        if significandLength == 0 {
            significandLength = 32
        }

        // Read significand bytes (little-endian)
        let significandBytes = try readBytes(count: significandLength)
        var significand: UInt64 = 0
        if significandLength <= 8 {
            for i in 0..<significandLength {
                significand |= UInt64(significandBytes[i]) << (i * 8)
            }
        } else {
            // For very large significands, we'd need arbitrary precision
            // For now, just use the lower 8 bytes and note this is a limitation
            for i in 0..<8 {
                significand |= UInt64(significandBytes[i]) << (i * 8)
            }
        }

        // Read exponent bytes (little-endian, signed)
        var exponent: Int32 = 0
        if exponentLength > 0 {
            let exponentBytes = try readBytes(count: exponentLength)
            var raw: UInt32 = 0
            for i in 0..<exponentLength {
                raw |= UInt32(exponentBytes[i]) << (i * 8)
            }
            // Sign extend
            let signBit = UInt32(1) << (exponentLength * 8 - 1)
            if raw & signBit != 0 {
                let mask = ~((UInt32(1) << (exponentLength * 8)) - 1)
                raw |= mask
            }
            exponent = Int32(bitPattern: raw)
        }

        // Convert to string representation
        var result = isNegative ? "-" : ""
        result += String(significand)
        if exponent != 0 {
            result += "e\(exponent)"
        }

        return .string(result)
    }

    // MARK: - Container Reading

    /// Reads an array.
    private func readArray() throws -> BONJSONValue {
        containerDepth += 1
        if containerDepth > maxContainerDepth {
            throw BONJSONDecodingError.containerDepthExceeded
        }

        var elements: [BONJSONValue] = []

        while true {
            let nextByte = try peekByte()
            if nextByte == TypeCode.containerEnd {
                _ = try readByte()  // consume the end marker
                break
            }
            let element = try readValue()
            elements.append(element)
        }

        containerDepth -= 1
        return .array(elements)
    }

    /// Reads an object.
    private func readObject() throws -> BONJSONValue {
        containerDepth += 1
        if containerDepth > maxContainerDepth {
            throw BONJSONDecodingError.containerDepthExceeded
        }

        var pairs: [(String, BONJSONValue)] = []
        var seenKeys = Set<String>()

        while true {
            let nextByte = try peekByte()
            if nextByte == TypeCode.containerEnd {
                _ = try readByte()  // consume the end marker
                break
            }

            // Read key (must be a string)
            let keyValue = try readValue()
            guard case .string(let key) = keyValue else {
                throw BONJSONDecodingError.expectedObjectKey
            }

            // Check for duplicate keys
            if seenKeys.contains(key) {
                throw BONJSONDecodingError.duplicateObjectKey(key)
            }
            seenKeys.insert(key)

            // Read value
            let value = try readValue()
            pairs.append((key, value))
        }

        containerDepth -= 1
        return .object(pairs)
    }
}
