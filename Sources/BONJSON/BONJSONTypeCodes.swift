// ABOUTME: Defines all BONJSON type codes and related constants.
// ABOUTME: Type codes are single bytes that identify the data type and sometimes encode the value.

import Foundation

/// BONJSON type codes and constants.
///
/// Type code ranges:
/// - 0x00-0x64: Small positive integers (0-100)
/// - 0x68: Long string (with length field)
/// - 0x69: Big number (arbitrary precision)
/// - 0x6a-0x6c: Floating point (bfloat16, float32, float64)
/// - 0x6d: Null
/// - 0x6e-0x6f: Boolean (false, true)
/// - 0x70-0x77: Unsigned integers (1-8 bytes)
/// - 0x78-0x7f: Signed integers (1-8 bytes)
/// - 0x80-0x8f: Short strings (0-15 bytes, length in lower nibble)
/// - 0x99: Array start
/// - 0x9a: Object start
/// - 0x9b: Container end
/// - 0x9c-0xff: Small negative integers (-100 to -1)
enum TypeCode {
    // Small integers encode the value directly in the type code
    static let smallIntMin: Int8 = -100
    static let smallIntMax: Int8 = 100

    // Type codes for small positive integers: 0x00 to 0x64 (0 to 100)
    static let smallIntPositiveBase: UInt8 = 0x00

    // Type codes for small negative integers: 0x9c to 0xff (-100 to -1)
    // Formula: typeCode = 0x9c + (value + 100) = value + 0x100
    static let smallIntNegativeBase: UInt8 = 0x9c

    // Long string marker (followed by chunked length-prefixed UTF-8)
    static let stringLong: UInt8 = 0x68

    // Big number (arbitrary precision decimal)
    static let bigNumber: UInt8 = 0x69

    // Floating point types
    static let float16: UInt8 = 0x6a  // bfloat16
    static let float32: UInt8 = 0x6b  // IEEE 754 single
    static let float64: UInt8 = 0x6c  // IEEE 754 double

    // Null
    static let null: UInt8 = 0x6d

    // Booleans
    static let `false`: UInt8 = 0x6e
    static let `true`: UInt8 = 0x6f

    // Unsigned integers (1-8 bytes, little-endian)
    // Type code 0x70 + (byteCount - 1)
    static let uint8: UInt8 = 0x70
    static let uint16: UInt8 = 0x71
    static let uint24: UInt8 = 0x72
    static let uint32: UInt8 = 0x73
    static let uint40: UInt8 = 0x74
    static let uint48: UInt8 = 0x75
    static let uint56: UInt8 = 0x76
    static let uint64: UInt8 = 0x77

    // Signed integers (1-8 bytes, little-endian, two's complement)
    // Type code 0x78 + (byteCount - 1)
    static let sint8: UInt8 = 0x78
    static let sint16: UInt8 = 0x79
    static let sint24: UInt8 = 0x7a
    static let sint32: UInt8 = 0x7b
    static let sint40: UInt8 = 0x7c
    static let sint48: UInt8 = 0x7d
    static let sint56: UInt8 = 0x7e
    static let sint64: UInt8 = 0x7f

    // Short strings (0-15 bytes, length in lower nibble)
    // Type code 0x80 + length
    static let stringShortBase: UInt8 = 0x80
    static let stringShortMax: Int = 15

    // Container markers
    static let arrayStart: UInt8 = 0x99
    static let objectStart: UInt8 = 0x9a
    static let containerEnd: UInt8 = 0x9b

    /// Returns the type code for a small integer value.
    /// Precondition: value must be in range -100...100
    static func smallInt(_ value: Int8) -> UInt8 {
        if value >= 0 {
            return smallIntPositiveBase + UInt8(value)
        } else {
            // For negative values: -1 -> 0xff, -100 -> 0x9c
            return UInt8(truncatingIfNeeded: Int16(value) + 256)
        }
    }

    /// Returns the type code for a short string of the given length.
    /// Precondition: length must be in range 0...15
    static func stringShort(length: Int) -> UInt8 {
        return stringShortBase + UInt8(length)
    }

    /// Returns the type code for an unsigned integer with the given byte count.
    /// Precondition: byteCount must be in range 1...8
    static func unsignedInt(byteCount: Int) -> UInt8 {
        return uint8 + UInt8(byteCount - 1)
    }

    /// Returns the type code for a signed integer with the given byte count.
    /// Precondition: byteCount must be in range 1...8
    static func signedInt(byteCount: Int) -> UInt8 {
        return sint8 + UInt8(byteCount - 1)
    }

    /// Checks if a type code represents a small integer and returns its value.
    static func smallIntValue(from typeCode: UInt8) -> Int8? {
        if typeCode <= 0x64 {
            // Positive small int: 0x00-0x64 -> 0-100
            return Int8(typeCode)
        } else if typeCode >= 0x9c {
            // Negative small int: 0x9c-0xff -> -100 to -1
            return Int8(Int(typeCode) - 256)
        }
        return nil
    }

    /// Checks if a type code represents a short string and returns its length.
    static func shortStringLength(from typeCode: UInt8) -> Int? {
        if typeCode >= stringShortBase && typeCode <= stringShortBase + UInt8(stringShortMax) {
            return Int(typeCode - stringShortBase)
        }
        return nil
    }

    /// Checks if a type code represents an unsigned integer and returns its byte count.
    static func unsignedIntByteCount(from typeCode: UInt8) -> Int? {
        if typeCode >= uint8 && typeCode <= uint64 {
            return Int(typeCode - uint8) + 1
        }
        return nil
    }

    /// Checks if a type code represents a signed integer and returns its byte count.
    static func signedIntByteCount(from typeCode: UInt8) -> Int? {
        if typeCode >= sint8 && typeCode <= sint64 {
            return Int(typeCode - sint8) + 1
        }
        return nil
    }
}

/// Configuration constants for BONJSON encoding/decoding.
enum BONJSONConstants {
    /// Maximum container nesting depth (arrays and objects).
    static let maxContainerDepth = 200

    /// Default maximum chunk size for string chunking.
    static let defaultMaxChunkSize = 1024 * 1024  // 1MB
}
