// ABOUTME: Comprehensive tests for BONJSONEncoder and BONJSONDecoder.
// ABOUTME: Tests round-trip encoding/decoding for all supported types.

import XCTest
@testable import BONJSON

// MARK: - BONJSON Type Codes for Testing
// These match the BONJSON specification for verifying encoded output.
private enum TestTypeCode {
    static let null: UInt8 = 0x6d
    static let `false`: UInt8 = 0x6e
    static let `true`: UInt8 = 0x6f

    static let float32: UInt8 = 0x6b
    static let float64: UInt8 = 0x6c
    static let stringLong: UInt8 = 0x68

    static let arrayStart: UInt8 = 0x99
    static let objectStart: UInt8 = 0x9a
    static let containerEnd: UInt8 = 0x9b

    /// Small positive integers 0-100 encode directly as their value.
    /// Small negative integers -1 to -100 encode as two's complement bytes.
    static func smallInt(_ value: Int8) -> UInt8 {
        return UInt8(bitPattern: value)
    }

    /// Short string type code for given length (0-15)
    static func stringShort(length: Int) -> UInt8 {
        return 0x80 + UInt8(length)
    }
}

final class BONJSONEncoderTests: XCTestCase {

    // MARK: - Primitive Types

    func testEncodeBool() throws {
        let encoder = BONJSONEncoder()

        let trueData = try encoder.encode(true)
        XCTAssertEqual(trueData, Data([TestTypeCode.true]))

        let falseData = try encoder.encode(false)
        XCTAssertEqual(falseData, Data([TestTypeCode.false]))
    }

    func testEncodeNull() throws {
        let encoder = BONJSONEncoder()
        let data = try encoder.encode(nil as Int?)
        XCTAssertEqual(data, Data([TestTypeCode.null]))
    }

    func testEncodeSmallIntegers() throws {
        let encoder = BONJSONEncoder()

        // Test small positive integers (0-100)
        for i: Int8 in 0...100 {
            let data = try encoder.encode(i)
            XCTAssertEqual(data, Data([TestTypeCode.smallInt(i)]), "Failed for \(i)")
        }

        // Test small negative integers (-1 to -100)
        for i: Int8 in -100...(-1) {
            let data = try encoder.encode(i)
            XCTAssertEqual(data, Data([TestTypeCode.smallInt(i)]), "Failed for \(i)")
        }
    }

    func testEncodeLargerIntegers() throws {
        let encoder = BONJSONEncoder()
        let decoder = BONJSONDecoder()

        // Test values outside small int range round-trip correctly
        let value101 = Int8(101)
        let data101 = try encoder.encode(value101)
        let decoded101 = try decoder.decode(Int8.self, from: data101)
        XCTAssertEqual(decoded101, value101)

        // Test 2-byte integer
        let value1000 = Int16(1000)
        let data1000 = try encoder.encode(value1000)
        let decoded1000 = try decoder.decode(Int16.self, from: data1000)
        XCTAssertEqual(decoded1000, value1000)

        // Test 4-byte integer
        let value100000 = Int32(100000)
        let data100000 = try encoder.encode(value100000)
        let decoded100000 = try decoder.decode(Int32.self, from: data100000)
        XCTAssertEqual(decoded100000, value100000)

        // Test 8-byte integer
        let valueLarge = Int64.max
        let dataLarge = try encoder.encode(valueLarge)
        let decodedLarge = try decoder.decode(Int64.self, from: dataLarge)
        XCTAssertEqual(decodedLarge, valueLarge)
    }

    func testEncodeUnsignedIntegers() throws {
        let encoder = BONJSONEncoder()
        let decoder = BONJSONDecoder()

        // Unsigned integers in small int range should use small int encoding
        let data50 = try encoder.encode(UInt8(50))
        XCTAssertEqual(data50, Data([TestTypeCode.smallInt(50)]))

        // Larger unsigned integers round-trip correctly
        let value200 = UInt8(200)
        let data200 = try encoder.encode(value200)
        let decoded200 = try decoder.decode(UInt8.self, from: data200)
        XCTAssertEqual(decoded200, value200)

        // Max UInt64
        let valueMaxU64 = UInt64.max
        let dataMaxU64 = try encoder.encode(valueMaxU64)
        let decodedMaxU64 = try decoder.decode(UInt64.self, from: dataMaxU64)
        XCTAssertEqual(decodedMaxU64, valueMaxU64)
    }

    func testEncodeFloat() throws {
        let encoder = BONJSONEncoder()

        // Whole numbers should encode as integers
        let dataWhole = try encoder.encode(42.0)
        XCTAssertEqual(dataWhole, Data([TestTypeCode.smallInt(42)]))

        // Float that fits in float32
        let dataFloat32 = try encoder.encode(3.14)
        // Could be float32 or float64 depending on precision
        XCTAssertTrue(dataFloat32[0] == TestTypeCode.float32 || dataFloat32[0] == TestTypeCode.float64)

        // Float that requires float64
        let dataFloat64 = try encoder.encode(Double.pi)
        XCTAssertEqual(dataFloat64[0], TestTypeCode.float64)
    }

    func testEncodeInvalidFloat() throws {
        let encoder = BONJSONEncoder()

        XCTAssertThrowsError(try encoder.encode(Double.nan))
        XCTAssertThrowsError(try encoder.encode(Double.infinity))
        XCTAssertThrowsError(try encoder.encode(-Double.infinity))
    }

    func testEncodeNonConformingFloatStrategy() throws {
        let encoder = BONJSONEncoder()
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "Infinity",
            negativeInfinity: "-Infinity",
            nan: "NaN"
        )

        // Should encode as strings now
        _ = try encoder.encode(Double.nan)
        _ = try encoder.encode(Double.infinity)
        _ = try encoder.encode(-Double.infinity)
    }

    // MARK: - Strings

    func testEncodeShortString() throws {
        let encoder = BONJSONEncoder()

        // Empty string
        let dataEmpty = try encoder.encode("")
        XCTAssertEqual(dataEmpty, Data([TestTypeCode.stringShort(length: 0)]))

        // Short string (1-15 bytes)
        let dataHello = try encoder.encode("hello")
        XCTAssertEqual(dataHello[0], TestTypeCode.stringShort(length: 5))
        XCTAssertEqual(String(data: dataHello.dropFirst(), encoding: .utf8), "hello")
    }

    func testEncodeLongString() throws {
        let encoder = BONJSONEncoder()

        // String longer than 15 bytes
        let longString = String(repeating: "a", count: 20)
        let data = try encoder.encode(longString)
        XCTAssertEqual(data[0], TestTypeCode.stringLong)
    }

    // MARK: - Arrays

    func testEncodeEmptyArray() throws {
        let encoder = BONJSONEncoder()
        let data = try encoder.encode([Int]())
        XCTAssertEqual(data, Data([TestTypeCode.arrayStart, TestTypeCode.containerEnd]))
    }

    func testEncodeIntArray() throws {
        let encoder = BONJSONEncoder()
        let data = try encoder.encode([1, 2, 3])

        // Should be: array start, 1, 2, 3, container end
        XCTAssertEqual(data[0], TestTypeCode.arrayStart)
        XCTAssertEqual(data[1], TestTypeCode.smallInt(1))
        XCTAssertEqual(data[2], TestTypeCode.smallInt(2))
        XCTAssertEqual(data[3], TestTypeCode.smallInt(3))
        XCTAssertEqual(data[4], TestTypeCode.containerEnd)
    }

    func testEncodeNestedArray() throws {
        let encoder = BONJSONEncoder()
        let data = try encoder.encode([[1, 2], [3, 4]])

        XCTAssertEqual(data[0], TestTypeCode.arrayStart)
        XCTAssertEqual(data[1], TestTypeCode.arrayStart)
        // ... nested content
        XCTAssertEqual(data.last, TestTypeCode.containerEnd)
    }

    // MARK: - Objects (Dictionaries/Structs)

    func testEncodeEmptyObject() throws {
        struct Empty: Codable {}

        let encoder = BONJSONEncoder()
        let data = try encoder.encode(Empty())
        XCTAssertEqual(data, Data([TestTypeCode.objectStart, TestTypeCode.containerEnd]))
    }

    func testEncodeSimpleStruct() throws {
        struct Person: Codable {
            var name: String
            var age: Int
        }

        let encoder = BONJSONEncoder()
        let person = Person(name: "Alice", age: 30)
        let data = try encoder.encode(person)

        // Should start with object start
        XCTAssertEqual(data[0], TestTypeCode.objectStart)
        // Should end with container end
        XCTAssertEqual(data.last, TestTypeCode.containerEnd)
    }

    func testEncodeNestedStruct() throws {
        struct Address: Codable {
            var city: String
        }
        struct Person: Codable {
            var name: String
            var address: Address
        }

        let encoder = BONJSONEncoder()
        let person = Person(name: "Bob", address: Address(city: "NYC"))
        let data = try encoder.encode(person)

        // Should have nested objects
        var objectCount = 0
        var endCount = 0
        for byte in data {
            if byte == TestTypeCode.objectStart { objectCount += 1 }
            if byte == TestTypeCode.containerEnd { endCount += 1 }
        }
        XCTAssertEqual(objectCount, 2)
        XCTAssertEqual(endCount, 2)
    }

    // MARK: - Special Types

    func testEncodeDateSecondsSince1970() throws {
        let encoder = BONJSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970

        let timestamp = 1000000.0
        let date = Date(timeIntervalSince1970: timestamp)
        let data = try encoder.encode(date)

        // Should encode as a number
        let decoder = BONJSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let decoded = try decoder.decode(Date.self, from: data)
        XCTAssertEqual(decoded.timeIntervalSince1970, timestamp, accuracy: 0.001)
    }

    func testEncodeDateISO8601() throws {
        let encoder = BONJSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let date = Date(timeIntervalSince1970: 0)
        let data = try encoder.encode(date)

        // Should encode as a string
        let decoder = BONJSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Date.self, from: data)
        XCTAssertEqual(decoded.timeIntervalSince1970, 0, accuracy: 1)
    }

    func testEncodeDataBase64() throws {
        let encoder = BONJSONEncoder()
        encoder.dataEncodingStrategy = .base64

        let originalData = Data([0x01, 0x02, 0x03])
        let encoded = try encoder.encode(originalData)

        let decoder = BONJSONDecoder()
        decoder.dataDecodingStrategy = .base64
        let decoded = try decoder.decode(Data.self, from: encoded)
        XCTAssertEqual(decoded, originalData)
    }

    func testEncodeURL() throws {
        let encoder = BONJSONEncoder()
        let url = URL(string: "https://example.com")!
        let data = try encoder.encode(url)

        let decoder = BONJSONDecoder()
        let decoded = try decoder.decode(URL.self, from: data)
        XCTAssertEqual(decoded, url)
    }

    // MARK: - Key Strategies

    func testKeyEncodingSnakeCase() throws {
        struct Person: Codable {
            var firstName: String
            var lastName: String
        }

        let encoder = BONJSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase

        let person = Person(firstName: "John", lastName: "Doe")
        let data = try encoder.encode(person)

        // Verify the encoded data contains snake_case keys
        let decoder = BONJSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let decoded = try decoder.decode(Person.self, from: data)
        XCTAssertEqual(decoded.firstName, "John")
        XCTAssertEqual(decoded.lastName, "Doe")
    }
}

final class BONJSONDecoderTests: XCTestCase {

    // MARK: - Primitive Types

    func testDecodeBool() throws {
        let decoder = BONJSONDecoder()

        let trueValue = try decoder.decode(Bool.self, from: Data([TestTypeCode.true]))
        XCTAssertTrue(trueValue)

        let falseValue = try decoder.decode(Bool.self, from: Data([TestTypeCode.false]))
        XCTAssertFalse(falseValue)
    }

    func testDecodeSmallIntegers() throws {
        let decoder = BONJSONDecoder()

        for i: Int8 in -100...100 {
            let data = Data([TestTypeCode.smallInt(i)])
            let decoded = try decoder.decode(Int8.self, from: data)
            XCTAssertEqual(decoded, i, "Failed for \(i)")
        }
    }

    func testDecodeString() throws {
        let decoder = BONJSONDecoder()

        // Short string
        var data = Data([TestTypeCode.stringShort(length: 5)])
        data.append(contentsOf: "hello".utf8)
        let decoded = try decoder.decode(String.self, from: data)
        XCTAssertEqual(decoded, "hello")
    }

    func testDecodeArray() throws {
        let decoder = BONJSONDecoder()

        let data = Data([
            TestTypeCode.arrayStart,
            TestTypeCode.smallInt(1),
            TestTypeCode.smallInt(2),
            TestTypeCode.smallInt(3),
            TestTypeCode.containerEnd
        ])

        let decoded = try decoder.decode([Int].self, from: data)
        XCTAssertEqual(decoded, [1, 2, 3])
    }

    // MARK: - Error Cases

    func testDecodeTypeMismatch() throws {
        let decoder = BONJSONDecoder()
        let data = Data([TestTypeCode.true])

        XCTAssertThrowsError(try decoder.decode(String.self, from: data)) { error in
            guard case DecodingError.typeMismatch = error else {
                // Also accept BONJSONDecodingError.typeMismatch
                if let bonError = error as? BONJSONDecodingError,
                   case .typeMismatch = bonError {
                    return
                }
                XCTFail("Expected typeMismatch error, got \(error)")
                return
            }
        }
    }
}

final class BONJSONRoundTripTests: XCTestCase {

    // MARK: - Round-trip Tests

    func testRoundTripBool() throws {
        try assertRoundTrip(true)
        try assertRoundTrip(false)
    }

    func testRoundTripIntegers() throws {
        try assertRoundTrip(Int8.min)
        try assertRoundTrip(Int8.max)
        try assertRoundTrip(Int16.min)
        try assertRoundTrip(Int16.max)
        try assertRoundTrip(Int32.min)
        try assertRoundTrip(Int32.max)
        try assertRoundTrip(Int64.min)
        try assertRoundTrip(Int64.max)
        try assertRoundTrip(UInt8.min)
        try assertRoundTrip(UInt8.max)
        try assertRoundTrip(UInt16.min)
        try assertRoundTrip(UInt16.max)
        try assertRoundTrip(UInt32.min)
        try assertRoundTrip(UInt32.max)
        try assertRoundTrip(UInt64.min)
        try assertRoundTrip(UInt64.max)
    }

    func testRoundTripFloats() throws {
        try assertRoundTrip(0.0)
        try assertRoundTrip(1.5)
        try assertRoundTrip(-1.5)
        try assertRoundTrip(Double.pi)
        try assertRoundTrip(Double.leastNormalMagnitude)
        try assertRoundTrip(Double.greatestFiniteMagnitude)
    }

    func testRoundTripStrings() throws {
        try assertRoundTrip("")
        try assertRoundTrip("hello")
        try assertRoundTrip("hello world, this is a longer string that exceeds 15 bytes")
        try assertRoundTrip("emoji: 🎉🚀✨")
        try assertRoundTrip("unicode: 日本語 العربية עברית")
    }

    func testRoundTripArrays() throws {
        try assertRoundTrip([Int]())
        try assertRoundTrip([1, 2, 3])
        try assertRoundTrip(["a", "b", "c"])
        try assertRoundTrip([[1, 2], [3, 4], [5, 6]])
    }

    func testRoundTripOptionals() throws {
        try assertRoundTrip(nil as Int?)
        try assertRoundTrip(42 as Int?)
        try assertRoundTrip([nil, 1, nil, 2] as [Int?])
    }

    func testRoundTripComplexStruct() throws {
        struct Address: Codable, Equatable {
            var street: String
            var city: String
            var zipCode: String
        }

        struct Person: Codable, Equatable {
            var name: String
            var age: Int
            var height: Double
            var isActive: Bool
            var nickname: String?
            var addresses: [Address]
        }

        let person = Person(
            name: "Alice",
            age: 30,
            height: 5.6,
            isActive: true,
            nickname: "Ali",
            addresses: [
                Address(street: "123 Main St", city: "NYC", zipCode: "10001"),
                Address(street: "456 Oak Ave", city: "LA", zipCode: "90001")
            ]
        )

        try assertRoundTrip(person)
    }

    func testRoundTripEnum() throws {
        enum Status: String, Codable {
            case active
            case inactive
            case pending
        }

        try assertRoundTrip(Status.active)
        try assertRoundTrip(Status.inactive)
        try assertRoundTrip(Status.pending)
    }

    func testRoundTripDictionary() throws {
        try assertRoundTrip(["a": 1, "b": 2, "c": 3])
        try assertRoundTrip(["nested": ["inner": 42]])
    }

    // MARK: - Long String Tests

    func testRoundTripLongString() throws {
        // Test string that exceeds the short string encoding limit
        let longString = String(repeating: "a", count: 100)
        try assertRoundTrip(longString)

        // Test very long string
        let veryLongString = String(repeating: "x", count: 10000)
        try assertRoundTrip(veryLongString)
    }

    // MARK: - Helper

    private func assertRoundTrip<T: Codable & Equatable>(_ value: T, file: StaticString = #file, line: UInt = #line) throws {
        let encoder = BONJSONEncoder()
        let decoder = BONJSONDecoder()

        let data = try encoder.encode(value)
        let decoded = try decoder.decode(T.self, from: data)

        XCTAssertEqual(decoded, value, "Round-trip failed for \(value)", file: file, line: line)
    }
}
