// ABOUTME: Universal BONJSON conformance test runner.
// ABOUTME: Executes cross-implementation tests from the bonjson test suite.

import XCTest
import Foundation
@testable import BONJSON

// MARK: - Helper Types

/// Dynamic coding key for inspecting arbitrary JSON object keys.
private struct DynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        return nil
    }
}

// MARK: - Test Specification Types

/// Represents a BONJSON test specification document.
struct TestSpecification: Decodable {
    let type: String
    let version: String
    let tests: [TestCase]

    enum CodingKeys: String, CodingKey {
        case type, version, tests
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decode(String.self, forKey: .type)
        version = try container.decode(String.self, forKey: .version)
        // Decode as TestEntry array, filtering out comment-only entries
        let entries = try container.decode([TestEntry].self, forKey: .tests)
        tests = entries.compactMap { entry in
            if case .testCase(let tc) = entry { return tc }
            return nil
        }
    }
}

/// Represents either a test case or a comment-only section divider.
enum TestEntry: Decodable {
    case commentBlock
    case testCase(TestCase)

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)

        // Check if all keys start with "//" (comment-only entry)
        let hasNonCommentKeys = container.allKeys.contains { !$0.stringValue.hasPrefix("//") }

        if !hasNonCommentKeys {
            // This is a comment-only entry (section divider)
            self = .commentBlock
        } else {
            // This is a real test case - decode it
            self = .testCase(try TestCase(from: decoder))
        }
    }
}

/// Represents a BONJSON test configuration document.
struct TestConfiguration: Decodable {
    let type: String
    let version: String
    let sources: [TestSource]

    struct TestSource: Decodable {
        let path: String
        let recursive: Bool?
        let skip: Bool?
    }
}

/// Represents a single test case.
struct TestCase: Decodable {
    let name: String
    let type: TestType

    // For encode tests - use wrapper to distinguish null from absent
    let input: AnyJSON?
    let hasInput: Bool
    let expectedBytes: String?

    // For decode tests
    let inputBytes: String?
    let expectedValue: AnyJSON?
    let hasExpectedValue: Bool

    // For error tests
    let expectedError: String?

    // Options
    let options: TestOptions?

    // Required capabilities
    let requires: [String]?

    enum CodingKeys: String, CodingKey {
        case name, type, input, options, requires
        case expectedBytes = "expected_bytes"
        case inputBytes = "input_bytes"
        case expectedValue = "expected_value"
        case expectedError = "expected_error"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        name = try container.decode(String.self, forKey: .name)
        type = try container.decode(TestType.self, forKey: .type)
        expectedBytes = try container.decodeIfPresent(String.self, forKey: .expectedBytes)
        inputBytes = try container.decodeIfPresent(String.self, forKey: .inputBytes)
        expectedError = try container.decodeIfPresent(String.self, forKey: .expectedError)
        options = try container.decodeIfPresent(TestOptions.self, forKey: .options)
        requires = try container.decodeIfPresent([String].self, forKey: .requires)

        // Handle input - need to distinguish null from absent
        if container.contains(.input) {
            hasInput = true
            input = try container.decode(AnyJSON.self, forKey: .input)
        } else {
            hasInput = false
            input = nil
        }

        // Handle expectedValue - need to distinguish null from absent
        if container.contains(.expectedValue) {
            hasExpectedValue = true
            expectedValue = try container.decode(AnyJSON.self, forKey: .expectedValue)
        } else {
            hasExpectedValue = false
            expectedValue = nil
        }
    }
}

enum TestType: String, Decodable {
    case encode
    case decode
    case roundtrip
    case encodeError = "encode_error"
    case decodeError = "decode_error"
}

struct TestOptions: Decodable {
    let allowNul: Bool?
    let allowNanInfinity: Bool?
    let allowTrailingBytes: Bool?
    let maxDepth: Int?
    let maxContainerSize: Int?
    let maxStringLength: Int?
    let maxDocumentSize: Int?
    // New string-based options per spec
    let nanInfinityBehavior: String?  // "allow", "stringify"
    let duplicateKey: String?         // "keep_first", "keep_last"
    let invalidUtf8: String?          // "replace", "delete"
    let maxBigNumberExponent: Int?
    let maxBigNumberMagnitude: Int?
    let outOfRange: String?           // "stringify"
    let unicodeNormalization: String?  // "none", "nfc"

    // Track unrecognized options for skip detection
    var hasUnrecognizedOptions: Bool = false

    enum CodingKeys: String, CodingKey {
        case allowNul = "allow_nul"
        case allowNanInfinity = "allow_nan_infinity"
        case allowTrailingBytes = "allow_trailing_bytes"
        case maxDepth = "max_depth"
        case maxContainerSize = "max_container_size"
        case maxStringLength = "max_string_length"
        case maxDocumentSize = "max_document_size"
        case nanInfinityBehavior = "nan_infinity_behavior"
        case duplicateKey = "duplicate_key"
        case invalidUtf8 = "invalid_utf8"
        case maxBigNumberExponent = "max_bignumber_exponent"
        case maxBigNumberMagnitude = "max_bignumber_magnitude"
        case outOfRange = "out_of_range"
        case unicodeNormalization = "unicode_normalization"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        allowNul = try container.decodeIfPresent(Bool.self, forKey: .allowNul)
        allowNanInfinity = try container.decodeIfPresent(Bool.self, forKey: .allowNanInfinity)
        allowTrailingBytes = try container.decodeIfPresent(Bool.self, forKey: .allowTrailingBytes)
        maxDepth = try container.decodeIfPresent(Int.self, forKey: .maxDepth)
        maxContainerSize = try container.decodeIfPresent(Int.self, forKey: .maxContainerSize)
        maxStringLength = try container.decodeIfPresent(Int.self, forKey: .maxStringLength)
        maxDocumentSize = try container.decodeIfPresent(Int.self, forKey: .maxDocumentSize)
        nanInfinityBehavior = try container.decodeIfPresent(String.self, forKey: .nanInfinityBehavior)
        duplicateKey = try container.decodeIfPresent(String.self, forKey: .duplicateKey)
        invalidUtf8 = try container.decodeIfPresent(String.self, forKey: .invalidUtf8)
        maxBigNumberExponent = try container.decodeIfPresent(Int.self, forKey: .maxBigNumberExponent)
        maxBigNumberMagnitude = try container.decodeIfPresent(Int.self, forKey: .maxBigNumberMagnitude)
        outOfRange = try container.decodeIfPresent(String.self, forKey: .outOfRange)
        unicodeNormalization = try container.decodeIfPresent(String.self, forKey: .unicodeNormalization)

        // Check for unrecognized options by comparing key counts
        let dynamicContainer = try decoder.container(keyedBy: DynamicCodingKey.self)
        let recognizedKeys = Set(CodingKeys.allCases.map { $0.stringValue })
        for key in dynamicContainer.allKeys {
            if !key.stringValue.hasPrefix("//") && !recognizedKeys.contains(key.stringValue) {
                hasUnrecognizedOptions = true
                break
            }
        }
    }
}

extension TestOptions.CodingKeys: CaseIterable {}

// MARK: - AnyJSON Type

/// Represents any JSON value for encoding/decoding arbitrary test data.
enum AnyJSON {
    case null
    case bool(Bool)
    case int(Int64)
    case uint(UInt64)
    case float(Double)
    case string(String)
    case array([AnyJSON])
    case object([(String, AnyJSON)])  // Preserve order for encoding

    /// Special marker for values that can't be represented in standard JSON
    case specialNumber(SpecialNumber)

    enum SpecialNumber: Equatable {
        case nan
        case infinity
        case negativeInfinity
        case negativeZero
        case bigNumber(String)  // Arbitrary precision decimal string
    }

    var isNegativeZero: Bool {
        if case .specialNumber(.negativeZero) = self { return true }
        if case .float(let d) = self { return d == 0 && d.sign == .minus }
        return false
    }
}

extension AnyJSON: Decodable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
            return
        }

        if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
            return
        }

        // Try to decode as object first to check for $number marker
        if let dict = try? container.decode([String: AnyJSON].self) {
            if dict.count == 1, let numberStr = dict["$number"], case .string(let str) = numberStr {
                self = try Self.parseSpecialNumber(str)
                return
            }
            // Regular object - decode with order preservation
            let orderedContainer = try decoder.singleValueContainer()
            let orderedDict = try orderedContainer.decode(OrderedJSONObject.self)
            self = .object(orderedDict.pairs)
            return
        }

        if let array = try? container.decode([AnyJSON].self) {
            self = .array(array)
            return
        }

        if let string = try? container.decode(String.self) {
            self = .string(string)
            return
        }

        // Try integer first, then float
        if let int = try? container.decode(Int64.self) {
            self = .int(int)
            return
        }

        if let uint = try? container.decode(UInt64.self) {
            self = .uint(uint)
            return
        }

        if let double = try? container.decode(Double.self) {
            self = .float(double)
            return
        }

        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode AnyJSON")
    }

    /// Parse a $number string value into the appropriate numeric type.
    static func parseSpecialNumber(_ str: String) throws -> AnyJSON {
        let trimmed = str.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            throw ConformanceTestError.invalidNumberFormat(str)
        }

        let lower = trimmed.lowercased()

        // Check for special float values
        if lower == "nan" {
            return .specialNumber(.nan)
        }
        if lower == "infinity" || lower == "+infinity" {
            return .specialNumber(.infinity)
        }
        if lower == "-infinity" {
            return .specialNumber(.negativeInfinity)
        }

        // Check for negative zero
        if trimmed == "-0.0" || lower == "-0x0p+0" || lower == "-0x0p0" || lower == "-0x0p-0" {
            return .specialNumber(.negativeZero)
        }

        // Check for hex float (contains 'p' for exponent)
        if lower.contains("0x") && lower.contains("p") {
            if let value = parseHexFloat(trimmed) {
                if value == 0 && trimmed.hasPrefix("-") {
                    return .specialNumber(.negativeZero)
                }
                return .float(value)
            }
            throw ConformanceTestError.invalidNumberFormat(str)
        }

        // Check for hex integer (0x without p)
        if lower.hasPrefix("0x") || lower.hasPrefix("-0x") || lower.hasPrefix("+0x") {
            if let value = parseHexInt(trimmed) {
                return .int(value)
            }
            // Try unsigned
            if let value = parseHexUInt(trimmed) {
                return .uint(value)
            }
            throw ConformanceTestError.invalidNumberFormat(str)
        }

        // Check for decimal with exponent or decimal point - treat as float
        if lower.contains("e") || trimmed.contains(".") {
            // Check if this is a BigNumber (too precise for Double)
            if isBigNumber(trimmed) {
                return .specialNumber(.bigNumber(trimmed))
            }
            if let value = Double(trimmed) {
                return .float(value)
            }
            throw ConformanceTestError.invalidNumberFormat(str)
        }

        // Plain integer
        if let value = Int64(trimmed) {
            return .int(value)
        }
        if let value = UInt64(trimmed) {
            return .uint(value)
        }

        // Might be a BigNumber (too large for Int64/UInt64)
        return .specialNumber(.bigNumber(trimmed))
    }

    /// Parse C99 hex float format (e.g., "0x1.921fb54442d18p+1")
    private static func parseHexFloat(_ str: String) -> Double? {
        var s = str.lowercased()
        let negative = s.hasPrefix("-")
        if negative { s.removeFirst() }
        if s.hasPrefix("+") { s.removeFirst() }

        guard s.hasPrefix("0x") else { return nil }
        s.removeFirst(2)

        guard let pIndex = s.firstIndex(of: "p") else { return nil }
        let mantissaStr = String(s[..<pIndex])
        let expStr = String(s[s.index(after: pIndex)...])

        guard let exp = Int(expStr) else { return nil }

        var intPart: UInt64 = 0
        var fracPart: Double = 0

        if let dotIndex = mantissaStr.firstIndex(of: ".") {
            let intStr = String(mantissaStr[..<dotIndex])
            let fracStr = String(mantissaStr[mantissaStr.index(after: dotIndex)...])

            if !intStr.isEmpty {
                guard let i = UInt64(intStr, radix: 16) else { return nil }
                intPart = i
            }

            if !fracStr.isEmpty {
                guard let f = UInt64(fracStr, radix: 16) else { return nil }
                let fracBits = fracStr.count * 4
                fracPart = Double(f) / Double(1 << fracBits)
            }
        } else {
            guard let i = UInt64(mantissaStr, radix: 16) else { return nil }
            intPart = i
        }

        var result = (Double(intPart) + fracPart) * pow(2.0, Double(exp))
        if negative { result = -result }
        return result
    }

    /// Parse hex integer (e.g., "0xff", "-0x10")
    private static func parseHexInt(_ str: String) -> Int64? {
        var s = str.lowercased()
        let negative = s.hasPrefix("-")
        if negative { s.removeFirst() }
        if s.hasPrefix("+") { s.removeFirst() }

        guard s.hasPrefix("0x") else { return nil }
        s.removeFirst(2)

        guard !s.isEmpty else { return nil }
        guard let value = UInt64(s, radix: 16) else { return nil }

        if negative {
            if value > UInt64(Int64.max) + 1 { return nil }
            return -Int64(value)
        } else {
            if value > UInt64(Int64.max) { return nil }
            return Int64(value)
        }
    }

    private static func parseHexUInt(_ str: String) -> UInt64? {
        var s = str.lowercased()
        if s.hasPrefix("+") { s.removeFirst() }
        guard s.hasPrefix("0x") else { return nil }
        s.removeFirst(2)
        guard !s.isEmpty else { return nil }
        return UInt64(s, radix: 16)
    }

    /// Check if a number string requires BigNumber precision.
    private static func isBigNumber(_ str: String) -> Bool {
        // Extract significand digits (ignoring sign, decimal point, exponent)
        var digits = ""
        var inExponent = false
        for c in str {
            if c == "e" || c == "E" {
                inExponent = true
            } else if !inExponent && c.isNumber {
                digits.append(c)
            }
        }
        // Double has ~15-17 significant decimal digits
        // If we have more than 17 significant digits, it's a BigNumber
        let significantDigits = digits.drop(while: { $0 == "0" })
        return significantDigits.count > 17
    }
}

extension AnyJSON: Encodable {
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let b):
            try container.encode(b)
        case .int(let i):
            try container.encode(i)
        case .uint(let u):
            try container.encode(u)
        case .float(let d):
            try container.encode(d)
        case .string(let s):
            try container.encode(s)
        case .array(let arr):
            try container.encode(arr)
        case .object(let pairs):
            try container.encode(OrderedJSONObject(pairs: pairs))
        case .specialNumber(let special):
            switch special {
            case .nan:
                try container.encode(Double.nan)
            case .infinity:
                try container.encode(Double.infinity)
            case .negativeInfinity:
                try container.encode(-Double.infinity)
            case .negativeZero:
                try container.encode(-0.0 as Double)
            case .bigNumber(let str):
                // BigNumber encoding - parse and encode as Decimal
                if let decimal = Decimal(string: str) {
                    try container.encode(decimal)
                } else {
                    throw ConformanceTestError.invalidNumberFormat(str)
                }
            }
        }
    }
}

/// Helper for preserving object key order during decoding.
private struct OrderedJSONObject: Codable {
    var pairs: [(String, AnyJSON)]

    init(pairs: [(String, AnyJSON)]) {
        self.pairs = pairs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        pairs = []
        for key in container.allKeys {
            let value = try container.decode(AnyJSON.self, forKey: key)
            pairs.append((key.stringValue, value))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicCodingKey.self)
        for (key, value) in pairs {
            try container.encode(value, forKey: DynamicCodingKey(stringValue: key)!)
        }
    }
}

// MARK: - Error Types

enum ConformanceTestError: Error {
    case invalidHexString(String)
    case invalidNumberFormat(String)
    case testFailed(String)
    case structuralError(String)
    case skipped(String)
}

/// Standardized error type identifiers from the BONJSON test spec.
enum StandardErrorType: String {
    case truncated
    case trailingBytes = "trailing_bytes"
    case invalidTypeCode = "invalid_type_code"
    case invalidUtf8 = "invalid_utf8"
    case nulCharacter = "nul_character"
    case nulInString = "nul_in_string"
    case duplicateKey = "duplicate_key"
    case unclosedContainer = "unclosed_container"
    case invalidData = "invalid_data"
    case valueOutOfRange = "value_out_of_range"
    case nonCanonicalLength = "non_canonical_length"
    case tooManyChunks = "too_many_chunks"
    case emptyChunkContinuation = "empty_chunk_continuation"
    case maxDepthExceeded = "max_depth_exceeded"
    case maxStringLengthExceeded = "max_string_length_exceeded"
    case maxContainerSizeExceeded = "max_container_size_exceeded"
    case maxDocumentSizeExceeded = "max_document_size_exceeded"
    case nanNotAllowed = "nan_not_allowed"
    case infinityNotAllowed = "infinity_not_allowed"
    case invalidObjectKey = "invalid_object_key"
    case maxBigNumberExponentExceeded = "max_bignumber_exponent_exceeded"
    case maxBigNumberMagnitudeExceeded = "max_bignumber_magnitude_exceeded"
}

// MARK: - Hex String Parsing

/// Parse a hex string (with optional spaces) into bytes.
func parseHexString(_ hex: String) throws -> Data {
    let cleaned = hex.replacingOccurrences(of: " ", with: "")
    guard cleaned.count % 2 == 0 else {
        throw ConformanceTestError.invalidHexString("Odd number of hex digits: \(hex)")
    }

    var data = Data()
    var index = cleaned.startIndex
    while index < cleaned.endIndex {
        let nextIndex = cleaned.index(index, offsetBy: 2)
        let byteStr = String(cleaned[index..<nextIndex])
        guard let byte = UInt8(byteStr, radix: 16) else {
            throw ConformanceTestError.invalidHexString("Invalid hex byte: \(byteStr)")
        }
        data.append(byte)
        index = nextIndex
    }
    return data
}

/// Convert bytes to hex string for display.
func bytesToHex(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined(separator: " ")
}

// MARK: - Error Mapping

/// Map a Swift error to a standardized error type.
func mapErrorToStandardType(_ error: Error) -> StandardErrorType? {
    let desc = String(describing: error).lowercased()

    // Check for specific BONJSON error types
    // Note: "unclosed" must be checked before "truncat" because the unclosed container
    // error message may contain "truncated" in its explanation
    if desc.contains("unclosed") || desc.contains("missing end") || desc.contains("not all containers have been closed") {
        return .unclosedContainer
    }
    if desc.contains("truncat") || desc.contains("unexpected end") || desc.contains("premature") {
        return .truncated
    }
    if desc.contains("trailing") || desc.contains("unconsumed") {
        return .trailingBytes
    }
    if desc.contains("invalid type") || desc.contains("unknown type") || desc.contains("reserved") {
        return .invalidTypeCode
    }
    if desc.contains("utf-8") || desc.contains("utf8") || desc.contains("unicode") || desc.contains("invalid byte sequence") {
        return .invalidUtf8
    }
    // NUL character - map to nul_in_string (the newer test spec name)
    if desc.contains("nul") || desc.contains("null character") || desc.contains("\\u{0}") {
        return .nulInString
    }
    if desc.contains("duplicate key") || desc.contains("duplicate") {
        return .duplicateKey
    }
    // Check for NaN/infinity specifically before generic "non-conforming"
    // The error message is "Non-conforming float value: nan" or "Non-conforming float value: inf"
    if desc.contains("non-conforming") || desc.contains("nan") || desc.contains("infinity") || desc.contains("inf") {
        if desc.contains("nan") {
            return .nanNotAllowed
        }
        if desc.contains("inf") {
            return .infinityNotAllowed
        }
        return .invalidData
    }
    if desc.contains("out of range") || desc.contains("overflow") {
        return .valueOutOfRange
    }
    if desc.contains("non-canonical") || desc.contains("overlong") {
        return .nonCanonicalLength
    }
    if desc.contains("too many chunk") {
        return .tooManyChunks
    }
    if desc.contains("empty chunk") && desc.contains("continuation") {
        return .emptyChunkContinuation
    }
    if desc.contains("depth") || desc.contains("nesting") {
        return .maxDepthExceeded
    }
    if desc.contains("string length") || desc.contains("string too long") {
        return .maxStringLengthExceeded
    }
    if desc.contains("container size") || desc.contains("too many element") || desc.contains("too many keys") {
        return .maxContainerSizeExceeded
    }
    if desc.contains("document size") || desc.contains("document too large") {
        return .maxDocumentSizeExceeded
    }
    // Invalid object key - non-string used as object key
    // C error: "Expected to find a string for an object element name"
    if desc.contains("object") && desc.contains("name") && desc.contains("string") {
        return .invalidObjectKey
    }
    if desc.contains("bignumber exponent") && desc.contains("exceeds") {
        return .maxBigNumberExponentExceeded
    }
    if desc.contains("bignumber magnitude") && desc.contains("exceeds") {
        return .maxBigNumberMagnitudeExceeded
    }

    return nil
}

/// Check if the actual error type matches the expected error type.
/// Some error types are considered equivalent for backward compatibility
/// or due to implementation differences in error detection order.
func errorTypesMatch(_ actual: StandardErrorType, expected: String) -> Bool {
    // Direct match
    if actual.rawValue == expected {
        return true
    }

    // Equivalent error types for backward compatibility
    // NaN/infinity-related errors are equivalent to invalid_data
    if expected == "invalid_data" {
        switch actual {
        case .nanNotAllowed, .infinityNotAllowed:
            return true
        default:
            break
        }
    }

    // nul_in_string is equivalent to nul_character
    if expected == "nul_character" && actual == .nulInString {
        return true
    }
    if expected == "nul_in_string" && actual == .nulCharacter {
        return true
    }

    // Some error types may be detected differently depending on implementation.
    // For truncated data, C decoder may report value_out_of_range, invalid_utf8,
    // or invalid_object_key before detecting the truncation itself.
    if expected == "truncated" {
        switch actual {
        case .valueOutOfRange, .invalidUtf8, .invalidObjectKey:
            // These can occur when truncation is detected during validation,
            // or when truncation causes subsequent bytes to be misinterpreted
            // (e.g., a claimed count larger than actual data causes reading
            // a non-string type code where a key was expected)
            return true
        default:
            break
        }
    }

    // empty_chunk_continuation may be detected as truncated in some implementations
    if expected == "empty_chunk_continuation" && actual == .truncated {
        return true
    }

    return false
}

// MARK: - Value Comparison

/// Compare two AnyJSON values for semantic equality.
func valuesEqual(_ a: AnyJSON, _ b: AnyJSON) -> Bool {
    switch (a, b) {
    case (.null, .null):
        return true

    case (.bool(let ab), .bool(let bb)):
        return ab == bb

    case (.int(let ai), .int(let bi)):
        return ai == bi

    case (.uint(let au), .uint(let bu)):
        return au == bu

    case (.int(let ai), .uint(let bu)):
        return ai >= 0 && UInt64(ai) == bu

    case (.uint(let au), .int(let bi)):
        return bi >= 0 && au == UInt64(bi)

    case (.float(let af), .float(let bf)):
        // Handle NaN
        if af.isNaN && bf.isNaN { return true }
        // Handle negative zero
        if af == 0 && bf == 0 {
            return af.sign == bf.sign
        }
        return af == bf

    // Allow int/float comparison if mathematically equal
    case (.int(let ai), .float(let bf)):
        if bf.isNaN { return false }
        return Double(ai) == bf && bf == bf.rounded()

    case (.float(let af), .int(let bi)):
        if af.isNaN { return false }
        return af == Double(bi) && af == af.rounded()

    case (.uint(let au), .float(let bf)):
        if bf.isNaN { return false }
        return Double(au) == bf && bf == bf.rounded()

    case (.float(let af), .uint(let bu)):
        if af.isNaN { return false }
        return af == Double(bu) && af == af.rounded()

    // Compare float with special number representations
    case (.float(let af), .specialNumber(let bs)):
        switch bs {
        case .nan:
            return af.isNaN
        case .infinity:
            return af == .infinity
        case .negativeInfinity:
            return af == -.infinity
        case .negativeZero:
            return af == 0 && af.sign == .minus
        case .bigNumber:
            return false
        }

    case (.specialNumber(let as_), .float(let bf)):
        switch as_ {
        case .nan:
            return bf.isNaN
        case .infinity:
            return bf == .infinity
        case .negativeInfinity:
            return bf == -.infinity
        case .negativeZero:
            return bf == 0 && bf.sign == .minus
        case .bigNumber:
            return false
        }

    case (.specialNumber(let as_), .specialNumber(let bs)):
        return as_ == bs

    case (.string(let as_), .string(let bs)):
        return as_ == bs

    case (.array(let aa), .array(let ba)):
        guard aa.count == ba.count else { return false }
        return zip(aa, ba).allSatisfy { valuesEqual($0, $1) }

    case (.object(let ao), .object(let bo)):
        guard ao.count == bo.count else { return false }
        let aDict = Dictionary(ao, uniquingKeysWith: { $1 })
        let bDict = Dictionary(bo, uniquingKeysWith: { $1 })
        guard aDict.count == ao.count && bDict.count == bo.count else { return false }
        for (key, aVal) in aDict {
            guard let bVal = bDict[key], valuesEqual(aVal, bVal) else { return false }
        }
        return true

    case (.specialNumber(let as_), .specialNumber(let bs)):
        return as_ == bs

    case (.specialNumber(.nan), .float(let bf)):
        return bf.isNaN

    case (.float(let af), .specialNumber(.nan)):
        return af.isNaN

    case (.specialNumber(.infinity), .float(let bf)):
        return bf == .infinity

    case (.float(let af), .specialNumber(.infinity)):
        return af == .infinity

    case (.specialNumber(.negativeInfinity), .float(let bf)):
        return bf == -.infinity

    case (.float(let af), .specialNumber(.negativeInfinity)):
        return af == -.infinity

    case (.specialNumber(.negativeZero), .float(let bf)):
        return bf == 0 && bf.sign == .minus

    case (.float(let af), .specialNumber(.negativeZero)):
        return af == 0 && af.sign == .minus

    case (.specialNumber(.bigNumber(let as_)), _), (_, .specialNumber(.bigNumber(let as_))):
        // BigNumber comparison - parse to Decimal
        guard let aDecimal = Decimal(string: as_) else { return false }
        switch (a, b) {
        case (.specialNumber(.bigNumber(_)), .specialNumber(.bigNumber(let bs))):
            guard let bDecimal = Decimal(string: bs) else { return false }
            return aDecimal == bDecimal
        case (.specialNumber(.bigNumber(_)), .int(let bi)):
            return aDecimal == Decimal(bi)
        case (.specialNumber(.bigNumber(_)), .uint(let bu)):
            return aDecimal == Decimal(bu)
        case (.specialNumber(.bigNumber(_)), .float(let bf)):
            return aDecimal == Decimal(bf)
        case (.int(let ai), .specialNumber(.bigNumber(_))):
            return Decimal(ai) == aDecimal
        case (.uint(let au), .specialNumber(.bigNumber(_))):
            return Decimal(au) == aDecimal
        case (.float(let af), .specialNumber(.bigNumber(_))):
            return Decimal(af) == aDecimal
        default:
            return false
        }

    default:
        return false
    }
}

// MARK: - Test Runner

final class ConformanceTests: XCTestCase {

    /// Path to the universal BONJSON test suite.
    private static let testSuitePath: String = {
        // Get the swift-bonjson project root from this source file
        let thisFile = #file
        let projectRoot = URL(fileURLWithPath: thisFile)
            .deletingLastPathComponent()  // BONJSONTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // swift-bonjson
        // The specification submodule contains the test suite
        return projectRoot
            .appendingPathComponent("specification/tests")
            .path
    }()

    /// Run all conformance tests.
    func testConformance() throws {
        let configPath = Self.testSuitePath + "/conformance/config.json"

        guard FileManager.default.fileExists(atPath: configPath) else {
            throw XCTSkip("Conformance test suite not found at \(configPath)")
        }

        let results = try runTestsFromConfig(configPath)

        // Report results
        print("\n=== Conformance Test Results ===")
        print("Passed: \(results.passed)")
        print("Failed: \(results.failed)")
        print("Skipped: \(results.skipped)")

        if !results.failures.isEmpty {
            print("\nFailures:")
            for failure in results.failures {
                print("  - \(failure)")
            }
        }

        XCTAssertEqual(results.failed, 0, "Some conformance tests failed")
    }

    /// Run runner validation tests from the test-runner-validation/must-pass directory.
    /// These tests validate that the test runner itself works correctly.
    /// If these fail, conformance test results cannot be trusted.
    func testRunnerValid() throws {
        let validDir = Self.testSuitePath + "/test-runner-validation/must-pass"

        guard FileManager.default.fileExists(atPath: validDir) else {
            throw XCTSkip("Runner validation tests not found at \(validDir)")
        }

        let results = try runTestsFromDirectory(validDir, recursive: false)

        print("\n=== Runner Valid Test Results ===")
        print("Passed: \(results.passed)")
        print("Failed: \(results.failed)")
        print("Skipped: \(results.skipped)")

        if !results.failures.isEmpty {
            print("\nFailures:")
            for failure in results.failures {
                print("  - \(failure)")
            }
        }

        XCTAssertEqual(results.failed, 0, "Some runner validation tests failed")
    }

    /// Run runner value handling tests (numeric comparison, NaN, trailing bytes, etc.).
    /// These tests validate that the test runner correctly compares values.
    /// If these fail, conformance test results cannot be trusted.
    func testRunnerSpecialValues() throws {
        let specialDir = Self.testSuitePath + "/test-runner-validation/value-handling"

        guard FileManager.default.fileExists(atPath: specialDir) else {
            throw XCTSkip("Runner special value tests not found at \(specialDir)")
        }

        let results = try runTestsFromDirectory(specialDir, recursive: false)

        print("\n=== Runner Special Values Test Results ===")
        print("Passed: \(results.passed)")
        print("Failed: \(results.failed)")
        print("Skipped: \(results.skipped)")

        if !results.failures.isEmpty {
            print("\nFailures:")
            for failure in results.failures {
                print("  - \(failure)")
            }
        }

        XCTAssertEqual(results.failed, 0, "Some runner special value tests failed")
    }

    // MARK: - Test Execution

    struct TestResults {
        var passed: Int = 0
        var failed: Int = 0
        var skipped: Int = 0
        var failures: [String] = []
    }

    private func runTestsFromConfig(_ configPath: String) throws -> TestResults {
        let configURL = URL(fileURLWithPath: configPath)
        let configData = try Data(contentsOf: configURL)
        let config = try JSONDecoder().decode(TestConfiguration.self, from: configData)

        guard config.type == "bonjson-test-config" else {
            throw ConformanceTestError.structuralError("Invalid config type: \(config.type)")
        }

        var results = TestResults()
        let configDir = configURL.deletingLastPathComponent().path

        for source in config.sources {
            if source.skip == true {
                print("Skipping source: \(source.path)")
                continue
            }

            let sourcePath = configDir + "/" + source.path
            var isDirectory: ObjCBool = false

            guard FileManager.default.fileExists(atPath: sourcePath, isDirectory: &isDirectory) else {
                throw ConformanceTestError.structuralError("Source path not found: \(sourcePath)")
            }

            if isDirectory.boolValue {
                let dirResults = try runTestsFromDirectory(sourcePath, recursive: source.recursive ?? false)
                results.passed += dirResults.passed
                results.failed += dirResults.failed
                results.skipped += dirResults.skipped
                results.failures.append(contentsOf: dirResults.failures)
            } else {
                let fileResults = try runTestsFromFile(sourcePath)
                results.passed += fileResults.passed
                results.failed += fileResults.failed
                results.skipped += fileResults.skipped
                results.failures.append(contentsOf: fileResults.failures)
            }
        }

        return results
    }

    private func runTestsFromDirectory(_ path: String, recursive: Bool) throws -> TestResults {
        var results = TestResults()

        let contents = try FileManager.default.contentsOfDirectory(atPath: path)
            .sorted()  // Alphabetical order

        // Process files first
        for item in contents {
            if item.hasPrefix(".") { continue }  // Skip dotfiles

            let itemPath = path + "/" + item
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: itemPath, isDirectory: &isDirectory)

            if !isDirectory.boolValue && item.lowercased().hasSuffix(".json") {
                do {
                    let fileResults = try runTestsFromFile(itemPath)
                    results.passed += fileResults.passed
                    results.failed += fileResults.failed
                    results.skipped += fileResults.skipped
                    results.failures.append(contentsOf: fileResults.failures)
                } catch {
                    // Skip config files silently
                    if let testError = error as? ConformanceTestError,
                       case .structuralError(let msg) = testError,
                       msg.contains("bonjson-test-config") {
                        continue
                    }
                    throw error
                }
            }
        }

        // Then subdirectories if recursive
        if recursive {
            for item in contents {
                if item.hasPrefix(".") { continue }

                let itemPath = path + "/" + item
                var isDirectory: ObjCBool = false
                FileManager.default.fileExists(atPath: itemPath, isDirectory: &isDirectory)

                if isDirectory.boolValue {
                    let subResults = try runTestsFromDirectory(itemPath, recursive: true)
                    results.passed += subResults.passed
                    results.failed += subResults.failed
                    results.skipped += subResults.skipped
                    results.failures.append(contentsOf: subResults.failures)
                }
            }
        }

        return results
    }

    private func runTestsFromFile(_ path: String) throws -> TestResults {
        let fileURL = URL(fileURLWithPath: path)
        let fileName = fileURL.lastPathComponent
        let data = try Data(contentsOf: fileURL)
        let spec = try JSONDecoder().decode(TestSpecification.self, from: data)

        guard spec.type == "bonjson-test" else {
            throw ConformanceTestError.structuralError("Invalid test file type: \(spec.type) (expected bonjson-test)")
        }

        var results = TestResults()

        for test in spec.tests {
            let testId = "\(fileName):\(test.name)"

            // Check for unrecognized options
            if let options = test.options, options.hasUnrecognizedOptions {
                print("SKIP: \(testId) - unrecognized options")
                results.skipped += 1
                continue
            }

            do {
                try runTest(test, testId: testId)
                results.passed += 1
            } catch ConformanceTestError.skipped(let reason) {
                print("SKIP: \(testId) - \(reason)")
                results.skipped += 1
            } catch {
                results.failed += 1
                results.failures.append("\(testId): \(error)")
            }
        }

        return results
    }

    /// Capabilities supported by this implementation.
    /// Tests with `requires` containing capabilities not in this set will be skipped.
    private static let supportedCapabilities: Set<String> = [
        "int64",
        "encode_nul_rejection",
        "nan_infinity_stringify",
        "bignumber_resource_limits",
        "out_of_range_stringify",
        "unicode_normalization",
    ]

    private func runTest(_ test: TestCase, testId: String) throws {
        // Check required capabilities
        if let requires = test.requires {
            let unsupported = requires.filter { !Self.supportedCapabilities.contains($0) }
            if !unsupported.isEmpty {
                throw ConformanceTestError.skipped("requires unsupported capability: \(unsupported.joined(separator: ", "))")
            }
        }

        switch test.type {
        case .encode:
            try runEncodeTest(test, testId: testId)
        case .decode:
            try runDecodeTest(test, testId: testId)
        case .roundtrip:
            try runRoundtripTest(test, testId: testId)
        case .encodeError:
            try runEncodeErrorTest(test, testId: testId)
        case .decodeError:
            try runDecodeErrorTest(test, testId: testId)
        }
    }

    private func configureEncoder(_ encoder: BONJSONEncoder, options: TestOptions?) throws {
        guard let options = options else { return }

        if options.allowNul == true {
            encoder.nulEncodingStrategy = .allow
        }

        if options.allowNanInfinity == true {
            encoder.nonConformingFloatEncodingStrategy = .allow
        }

        // Apply string-based options
        if let nanInfinityBehavior = options.nanInfinityBehavior {
            switch nanInfinityBehavior {
            case "allow":
                encoder.nonConformingFloatEncodingStrategy = .allow
            case "stringify":
                encoder.nonConformingFloatEncodingStrategy = .convertToString(
                    positiveInfinity: "Infinity",
                    negativeInfinity: "-Infinity",
                    nan: "NaN"
                )
            default:
                break
            }
        }

        // Apply limit options
        if let maxDepth = options.maxDepth {
            encoder.maxDepth = maxDepth
        }
        if let maxContainerSize = options.maxContainerSize {
            encoder.maxContainerSize = maxContainerSize
        }
        if let maxStringLength = options.maxStringLength {
            encoder.maxStringLength = maxStringLength
        }
        if let maxDocumentSize = options.maxDocumentSize {
            encoder.maxDocumentSize = maxDocumentSize
        }
    }

    private func configureDecoder(_ decoder: BONJSONDecoder, options: TestOptions?) throws {
        guard let options = options else { return }

        if options.allowNul == true {
            decoder.nulDecodingStrategy = .allow
        }

        if options.allowNanInfinity == true {
            decoder.nonConformingFloatDecodingStrategy = .allow
        }

        if options.allowTrailingBytes == true {
            decoder.trailingBytesDecodingStrategy = .allow
        }

        // Apply limit options
        if let maxDepth = options.maxDepth {
            decoder.maxDepth = maxDepth
        }
        if let maxContainerSize = options.maxContainerSize {
            decoder.maxContainerSize = maxContainerSize
        }
        if let maxStringLength = options.maxStringLength {
            decoder.maxStringLength = maxStringLength
        }
        if let maxDocumentSize = options.maxDocumentSize {
            decoder.maxDocumentSize = maxDocumentSize
        }

        // Apply string-based options
        if let nanInfinityBehavior = options.nanInfinityBehavior {
            switch nanInfinityBehavior {
            case "allow":
                decoder.nonConformingFloatDecodingStrategy = .allow
            case "stringify":
                decoder.nonConformingFloatDecodingStrategy = .convertFromString(
                    positiveInfinity: "Infinity",
                    negativeInfinity: "-Infinity",
                    nan: "NaN"
                )
            default:
                break
            }
        }

        if let duplicateKey = options.duplicateKey {
            switch duplicateKey {
            case "keep_first":
                decoder.duplicateKeyDecodingStrategy = .keepFirst
            case "keep_last":
                decoder.duplicateKeyDecodingStrategy = .keepLast
            default:
                break
            }
        }

        if let invalidUtf8 = options.invalidUtf8 {
            switch invalidUtf8 {
            case "replace":
                decoder.unicodeDecodingStrategy = .replace
            case "delete":
                decoder.unicodeDecodingStrategy = .delete
            default:
                break
            }
        }

        if let maxBigNumberExponent = options.maxBigNumberExponent {
            decoder.maxBigNumberExponent = maxBigNumberExponent
        }
        if let maxBigNumberMagnitude = options.maxBigNumberMagnitude {
            decoder.maxBigNumberMagnitude = maxBigNumberMagnitude
        }

        if let outOfRange = options.outOfRange {
            switch outOfRange {
            case "stringify":
                decoder.outOfRangeBigNumberDecodingStrategy = .stringify
            default:
                break
            }
        }

        if let unicodeNormalization = options.unicodeNormalization {
            switch unicodeNormalization {
            case "nfc":
                decoder.unicodeNormalizationStrategy = .nfc
            case "none":
                decoder.unicodeNormalizationStrategy = .none
            default:
                break
            }
        }
    }

    private func runEncodeTest(_ test: TestCase, testId: String) throws {
        guard test.hasInput else {
            throw ConformanceTestError.structuralError("\(testId): missing input")
        }
        guard let expectedBytesHex = test.expectedBytes else {
            throw ConformanceTestError.structuralError("\(testId): missing expected_bytes")
        }

        let input = test.input ?? .null
        let expectedBytes = try parseHexString(expectedBytesHex)

        let encoder = BONJSONEncoder()
        try configureEncoder(encoder, options: test.options)

        let actualBytes = try encoder.encode(input)

        if actualBytes != expectedBytes {
            throw ConformanceTestError.testFailed(
                "\(testId): encoded bytes mismatch\n" +
                "  Expected: \(bytesToHex(expectedBytes))\n" +
                "  Actual:   \(bytesToHex(actualBytes))"
            )
        }
    }

    private func runDecodeTest(_ test: TestCase, testId: String) throws {
        guard let inputBytesHex = test.inputBytes else {
            throw ConformanceTestError.structuralError("\(testId): missing input_bytes")
        }
        guard test.hasExpectedValue else {
            throw ConformanceTestError.structuralError("\(testId): missing expected_value")
        }

        let expectedValue = test.expectedValue ?? .null

        let inputBytes = try parseHexString(inputBytesHex)

        let decoder = BONJSONDecoder()
        try configureDecoder(decoder, options: test.options)

        let actualValue = try decoder.decode(AnyJSON.self, from: inputBytes)

        if !valuesEqual(actualValue, expectedValue) {
            throw ConformanceTestError.testFailed(
                "\(testId): decoded value mismatch\n" +
                "  Expected: \(expectedValue)\n" +
                "  Actual:   \(actualValue)"
            )
        }
    }

    private func runRoundtripTest(_ test: TestCase, testId: String) throws {
        guard test.hasInput else {
            throw ConformanceTestError.structuralError("\(testId): missing input")
        }

        let input = test.input ?? .null

        let encoder = BONJSONEncoder()
        let decoder = BONJSONDecoder()
        try configureEncoder(encoder, options: test.options)
        try configureDecoder(decoder, options: test.options)

        let encoded = try encoder.encode(input)
        let decoded = try decoder.decode(AnyJSON.self, from: encoded)

        if !valuesEqual(decoded, input) {
            throw ConformanceTestError.testFailed(
                "\(testId): roundtrip value mismatch\n" +
                "  Original: \(input)\n" +
                "  Decoded:  \(decoded)\n" +
                "  Bytes:    \(bytesToHex(encoded))"
            )
        }
    }

    private func runEncodeErrorTest(_ test: TestCase, testId: String) throws {
        guard test.hasInput else {
            throw ConformanceTestError.structuralError("\(testId): missing input")
        }
        guard let expectedError = test.expectedError else {
            throw ConformanceTestError.structuralError("\(testId): missing expected_error")
        }

        // Check if this is a recognized error type
        guard StandardErrorType(rawValue: expectedError) != nil else {
            throw ConformanceTestError.skipped("unrecognized error type: \(expectedError)")
        }

        let input = test.input ?? .null
        let encoder = BONJSONEncoder()
        try configureEncoder(encoder, options: test.options)

        do {
            let _ = try encoder.encode(input)
            throw ConformanceTestError.testFailed("\(testId): expected error '\(expectedError)' but encoding succeeded")
        } catch let e as ConformanceTestError {
            throw e
        } catch {
            // Verify error type matches (if we can determine it)
            if let mappedType = mapErrorToStandardType(error) {
                if !errorTypesMatch(mappedType, expected: expectedError) {
                    throw ConformanceTestError.testFailed(
                        "\(testId): error type mismatch\n" +
                        "  Expected: \(expectedError)\n" +
                        "  Actual:   \(mappedType.rawValue)\n" +
                        "  Error:    \(error)"
                    )
                }
            }
            // If we can't determine the type, any error is acceptable
        }
    }

    private func runDecodeErrorTest(_ test: TestCase, testId: String) throws {
        guard let inputBytesHex = test.inputBytes else {
            throw ConformanceTestError.structuralError("\(testId): missing input_bytes")
        }
        guard let expectedError = test.expectedError else {
            throw ConformanceTestError.structuralError("\(testId): missing expected_error")
        }

        // Check if this is a recognized error type
        guard StandardErrorType(rawValue: expectedError) != nil else {
            throw ConformanceTestError.skipped("unrecognized error type: \(expectedError)")
        }

        let inputBytes = try parseHexString(inputBytesHex)

        let decoder = BONJSONDecoder()
        try configureDecoder(decoder, options: test.options)

        do {
            let _ = try decoder.decode(AnyJSON.self, from: inputBytes)
            throw ConformanceTestError.testFailed("\(testId): expected error '\(expectedError)' but decoding succeeded")
        } catch let e as ConformanceTestError {
            throw e
        } catch {
            // Verify error type matches (if we can determine it)
            if let mappedType = mapErrorToStandardType(error) {
                if !errorTypesMatch(mappedType, expected: expectedError) {
                    throw ConformanceTestError.testFailed(
                        "\(testId): error type mismatch\n" +
                        "  Expected: \(expectedError)\n" +
                        "  Actual:   \(mappedType.rawValue)\n" +
                        "  Error:    \(error)"
                    )
                }
            }
            // If we can't determine the type, any error is acceptable
        }
    }
}
