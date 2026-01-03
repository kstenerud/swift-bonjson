// ABOUTME: Low-level BONJSON encoding primitives.
// ABOUTME: Handles binary encoding of all BONJSON types with efficient intrinsics usage.

import Foundation

/// Errors that can occur during BONJSON encoding.
public enum BONJSONEncodingError: Error {
    case containerDepthExceeded
    case invalidFloat(Double)  // NaN or infinity
    case invalidString  // Not valid UTF-8
    case stringTooLarge
    case internalError(String)
}

/// Low-level writer for BONJSON binary data.
/// Accumulates encoded bytes and provides methods for encoding each BONJSON type.
final class BONJSONWriter {
    /// The accumulated encoded bytes.
    private(set) var data: Data

    /// Current container depth for depth limiting.
    private var containerDepth: Int = 0

    /// Maximum allowed container depth.
    let maxContainerDepth: Int

    init(maxContainerDepth: Int = BONJSONConstants.maxContainerDepth) {
        self.data = Data()
        self.maxContainerDepth = maxContainerDepth
    }

    /// Resets the writer for reuse.
    func reset() {
        data.removeAll(keepingCapacity: true)
        containerDepth = 0
    }

    // MARK: - Primitive Writing

    /// Writes a single byte.
    @inline(__always)
    func writeByte(_ byte: UInt8) {
        data.append(byte)
    }

    /// Writes multiple bytes.
    @inline(__always)
    func writeBytes(_ bytes: [UInt8]) {
        data.append(contentsOf: bytes)
    }

    /// Writes raw data.
    @inline(__always)
    func writeData(_ bytes: Data) {
        data.append(bytes)
    }

    // MARK: - Length Field Encoding

    /// Encodes a length field with optional continuation bit.
    ///
    /// The length field uses a variable-width encoding:
    /// - For values 0-127 with no continuation: 1 byte
    /// - Larger values use more bytes, determined by leading zero count
    ///
    /// The continuation bit (LSB) indicates if more chunks follow for strings.
    func writeLengthField(_ length: Int, hasMoreChunks: Bool = false) {
        // Shift length left by 1 to make room for continuation bit
        var payload = UInt64(length) << 1
        if hasMoreChunks {
            payload |= 1
        }

        writeLengthPayload(payload)
    }

    /// Writes the encoded length payload.
    /// Uses efficient bit counting to determine byte width.
    private func writeLengthPayload(_ payload: UInt64) {
        if payload == 0 {
            writeByte(0)
            return
        }

        // Calculate number of bytes needed using leading zero count
        // This maps to __builtin_clzll in C
        let significantBits = 64 - payload.leadingZeroBitCount

        // Each byte holds 7 bits of payload (1 bit marks the header)
        // For 1 byte: up to 7 bits (0x7f)
        // For 2 bytes: up to 14 bits, etc.
        let byteCount = (significantBits + 6) / 7

        if byteCount <= 8 {
            // Standard encoding: first byte has a leading 1-bit marker
            // followed by zeros, then 7*n bits of payload in little-endian
            var encodedValue = payload << byteCount
            encodedValue |= UInt64(1) << (byteCount - 1)

            // Write in little-endian order
            for _ in 0..<byteCount {
                writeByte(UInt8(truncatingIfNeeded: encodedValue))
                encodedValue >>= 8
            }
        } else {
            // 9-byte encoding for very large values
            writeByte(0)
            var value = payload
            for _ in 0..<8 {
                writeByte(UInt8(truncatingIfNeeded: value))
                value >>= 8
            }
        }
    }

    // MARK: - Null and Boolean

    func writeNull() {
        writeByte(TypeCode.null)
    }

    func writeBool(_ value: Bool) {
        writeByte(value ? TypeCode.true : TypeCode.false)
    }

    // MARK: - Integer Encoding

    /// Encodes an integer using the smallest possible representation.
    func writeInt(_ value: Int64) {
        // Check if it fits in small int range (-100 to 100)
        if value >= Int64(TypeCode.smallIntMin) && value <= Int64(TypeCode.smallIntMax) {
            writeByte(TypeCode.smallInt(Int8(value)))
            return
        }

        // Determine byte count needed for signed representation
        let byteCount = signedByteCount(for: value)
        writeByte(TypeCode.signedInt(byteCount: byteCount))
        writeIntBytes(value, count: byteCount)
    }

    /// Encodes an unsigned integer using the smallest possible representation.
    func writeUInt(_ value: UInt64) {
        // Check if it fits in small int range (0 to 100)
        if value <= UInt64(TypeCode.smallIntMax) {
            writeByte(TypeCode.smallInt(Int8(value)))
            return
        }

        // Determine byte count needed for unsigned representation
        let unsignedBytes = unsignedByteCount(for: value)

        // Check if the value can be encoded as signed with the same byte count.
        // For this to work, the MSB of the encoded bytes must be 0 (to indicate positive).
        // Maximum positive value for n-byte signed: 2^(n*8-1) - 1
        let maxSignedValue = (UInt64(1) << (unsignedBytes * 8 - 1)) - 1
        if value <= maxSignedValue {
            // Can use signed encoding
            writeByte(TypeCode.signedInt(byteCount: unsignedBytes))
            writeIntBytes(Int64(value), count: unsignedBytes)
        } else {
            // Need unsigned encoding
            writeByte(TypeCode.unsignedInt(byteCount: unsignedBytes))
            writeUIntBytes(value, count: unsignedBytes)
        }
    }

    /// Writes integer bytes in little-endian order.
    private func writeIntBytes(_ value: Int64, count: Int) {
        var v = value
        for _ in 0..<count {
            writeByte(UInt8(truncatingIfNeeded: v))
            v >>= 8
        }
    }

    /// Writes unsigned integer bytes in little-endian order.
    private func writeUIntBytes(_ value: UInt64, count: Int) {
        var v = value
        for _ in 0..<count {
            writeByte(UInt8(truncatingIfNeeded: v))
            v >>= 8
        }
    }

    /// Calculates the minimum byte count needed for a signed integer.
    private func signedByteCount(for value: Int64) -> Int {
        if value >= 0 {
            // For positive values, we need sign bit to be 0
            // leadingZeroBitCount gives us how many leading zeros
            // We need ceil((64 - leadingZeroBitCount + 1) / 8) bytes
            let significantBits = 64 - value.leadingZeroBitCount + 1  // +1 for sign bit
            return max(1, (significantBits + 7) / 8)
        } else {
            // For negative values, use leading one bit count equivalent
            // ~value gives us the inverted bits, then count leading zeros
            let significantBits = 64 - (~value).leadingZeroBitCount + 1
            return max(1, (significantBits + 7) / 8)
        }
    }

    /// Calculates the minimum byte count needed for an unsigned integer.
    private func unsignedByteCount(for value: UInt64) -> Int {
        if value == 0 { return 1 }
        let significantBits = 64 - value.leadingZeroBitCount
        return (significantBits + 7) / 8
    }

    // MARK: - Floating Point Encoding

    /// Encodes a floating-point value using the smallest lossless representation.
    func writeFloat(_ value: Double) throws {
        // Check for invalid values (NaN and infinity are not allowed)
        guard value.isFinite else {
            throw BONJSONEncodingError.invalidFloat(value)
        }

        // Try to encode as integer if it's a whole number
        if let intValue = exactIntegerValue(from: value) {
            if intValue >= 0 {
                writeUInt(UInt64(intValue))
            } else {
                writeInt(intValue)
            }
            return
        }

        // Try float32 first (smaller), then fall back to float64
        let float32Value = Float(value)
        if Double(float32Value) == value {
            writeByte(TypeCode.float32)
            writeFloat32Bits(float32Value)
        } else {
            writeByte(TypeCode.float64)
            writeFloat64Bits(value)
        }
    }

    /// Writes float32 bits in little-endian order.
    private func writeFloat32Bits(_ value: Float) {
        var bits = value.bitPattern
        for _ in 0..<4 {
            writeByte(UInt8(truncatingIfNeeded: bits))
            bits >>= 8
        }
    }

    /// Writes float64 bits in little-endian order.
    private func writeFloat64Bits(_ value: Double) {
        var bits = value.bitPattern
        for _ in 0..<8 {
            writeByte(UInt8(truncatingIfNeeded: bits))
            bits >>= 8
        }
    }

    /// Returns the exact integer value if the double represents a whole number
    /// that fits in Int64, otherwise nil.
    private func exactIntegerValue(from value: Double) -> Int64? {
        guard value >= Double(Int64.min) && value <= Double(Int64.max) else {
            return nil
        }
        let intValue = Int64(value)
        guard Double(intValue) == value else {
            return nil
        }
        return intValue
    }

    // MARK: - String Encoding

    /// Encodes a string value.
    func writeString(_ value: String) {
        let utf8 = value.utf8
        let byteCount = utf8.count

        if byteCount <= TypeCode.stringShortMax {
            // Short string: type code encodes the length
            writeByte(TypeCode.stringShort(length: byteCount))
            data.append(contentsOf: utf8)
        } else {
            // Long string: type code + length field + data
            writeByte(TypeCode.stringLong)
            writeLengthField(byteCount, hasMoreChunks: false)
            data.append(contentsOf: utf8)
        }
    }

    /// Encodes string data with explicit UTF-8 bytes (for chunked encoding).
    func writeStringChunk(_ utf8Bytes: Data, isFinal: Bool) {
        writeLengthField(utf8Bytes.count, hasMoreChunks: !isFinal)
        writeData(utf8Bytes)
    }

    /// Begins a long string (for chunked encoding).
    func beginLongString() {
        writeByte(TypeCode.stringLong)
    }

    // MARK: - Container Encoding

    /// Begins an array container.
    func beginArray() throws {
        try incrementContainerDepth()
        writeByte(TypeCode.arrayStart)
    }

    /// Begins an object container.
    func beginObject() throws {
        try incrementContainerDepth()
        writeByte(TypeCode.objectStart)
    }

    /// Ends the current container (array or object).
    func endContainer() {
        containerDepth -= 1
        writeByte(TypeCode.containerEnd)
    }

    private func incrementContainerDepth() throws {
        containerDepth += 1
        if containerDepth > maxContainerDepth {
            throw BONJSONEncodingError.containerDepthExceeded
        }
    }
}
