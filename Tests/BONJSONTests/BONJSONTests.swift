// ABOUTME: Comprehensive tests for BONJSONEncoder and BONJSONDecoder.
// ABOUTME: Tests round-trip encoding/decoding for all supported types.

import XCTest
@testable import BONJSON

// MARK: - BONJSON Type Codes for Testing
// These match the BONJSON specification for verifying encoded output.
private enum TestTypeCode {
    static let null: UInt8 = 0xf5
    static let `false`: UInt8 = 0xf6
    static let `true`: UInt8 = 0xf7

    static let float16: UInt8 = 0xf2
    static let float32: UInt8 = 0xf3
    static let float64: UInt8 = 0xf4
    static let stringLong: UInt8 = 0xf0

    static let arrayStart: UInt8 = 0xf8
    static let objectStart: UInt8 = 0xf9
    // No containerEnd - containers use chunked format with length fields

    /// Small integers -100 to 100 encode as type_code = value + 100
    /// e.g., -100 -> 0x00, 0 -> 0x64, 100 -> 0xc8
    static func smallInt(_ value: Int8) -> UInt8 {
        return UInt8(Int(value) + 100)
    }

    /// Short string type code for given length (0-15)
    static func stringShort(length: Int) -> UInt8 {
        return 0xe0 + UInt8(length)
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
        // Chunked format: arrayStart + chunk header (count=0, continuation=0)
        XCTAssertEqual(data, Data([TestTypeCode.arrayStart, 0x00]))
    }

    func testEncodeIntArray() throws {
        let encoder = BONJSONEncoder()
        let data = try encoder.encode([1, 2, 3])

        // Chunked format: arrayStart + chunk header + elements
        // Length field encoding: payload = (count << 1) | cont, then shifts left for trailing bits
        // For count=3: payload = 6, then length field encoding gives 0x0c
        XCTAssertEqual(data[0], TestTypeCode.arrayStart)
        XCTAssertEqual(data[1], 0x0c) // chunk header for 3 elements
        XCTAssertEqual(data[2], TestTypeCode.smallInt(1))
        XCTAssertEqual(data[3], TestTypeCode.smallInt(2))
        XCTAssertEqual(data[4], TestTypeCode.smallInt(3))
    }

    func testEncodeNestedArray() throws {
        let encoder = BONJSONEncoder()
        let data = try encoder.encode([[1, 2], [3, 4]])

        // For count=2: payload = 4, length field encoding gives 0x08
        XCTAssertEqual(data[0], TestTypeCode.arrayStart)
        XCTAssertEqual(data[1], 0x08) // chunk header for 2 nested arrays
        XCTAssertEqual(data[2], TestTypeCode.arrayStart)
        // ... nested content
    }

    // MARK: - Objects (Dictionaries/Structs)

    func testEncodeEmptyObject() throws {
        struct Empty: Codable {}

        let encoder = BONJSONEncoder()
        let data = try encoder.encode(Empty())
        // Chunked format: objectStart + chunk header (count=0 pairs, continuation=0)
        XCTAssertEqual(data, Data([TestTypeCode.objectStart, 0x00]))
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
        // 2 pairs = 4 elements, chunk header = 0x08 (per spec example)
        XCTAssertEqual(data[1], 0x08)
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
        for byte in data {
            if byte == TestTypeCode.objectStart { objectCount += 1 }
        }
        XCTAssertEqual(objectCount, 2)
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

        // Chunked format: arrayStart + chunk header (count=3, no continuation) + elements
        // Length field encoding: payload = (count << 1) | cont = 6, then shift left = 0x0c
        let data = Data([
            TestTypeCode.arrayStart,
            0x0c,  // chunk header for 3 elements (matches spec length field encoding)
            TestTypeCode.smallInt(1),
            TestTypeCode.smallInt(2),
            TestTypeCode.smallInt(3)
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

// MARK: - Strategy Tests

final class BONJSONStrategyTests: XCTestCase {

    // MARK: - Date Strategies

    func testDateMillisecondsSince1970() throws {
        let encoder = BONJSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let decoder = BONJSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970

        let date = Date(timeIntervalSince1970: 1234567.890)
        let data = try encoder.encode(date)
        let decoded = try decoder.decode(Date.self, from: data)
        XCTAssertEqual(decoded.timeIntervalSince1970, date.timeIntervalSince1970, accuracy: 0.001)
    }

    func testDateFormatted() throws {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")

        let encoder = BONJSONEncoder()
        encoder.dateEncodingStrategy = .formatted(formatter)
        let decoder = BONJSONDecoder()
        decoder.dateDecodingStrategy = .formatted(formatter)

        let date = Date(timeIntervalSince1970: 86400) // 1970-01-02
        let data = try encoder.encode(date)
        let decoded = try decoder.decode(Date.self, from: data)

        // Dates should be equal when formatted
        let originalFormatted = formatter.string(from: date)
        let decodedFormatted = formatter.string(from: decoded)
        XCTAssertEqual(originalFormatted, decodedFormatted)
    }

    func testDateCustomStrategy() throws {
        struct DateWrapper: Codable {
            let date: Date

            init(date: Date) { self.date = date }

            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                let string = try container.decode(String.self)
                guard let seconds = Double(string) else {
                    throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date")
                }
                self.date = Date(timeIntervalSince1970: seconds)
            }

            func encode(to encoder: Encoder) throws {
                var container = encoder.singleValueContainer()
                try container.encode(String(date.timeIntervalSince1970))
            }
        }

        let encoder = BONJSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode("custom:\(Int(date.timeIntervalSince1970))")
        }

        let date = Date(timeIntervalSince1970: 1000)
        let data = try encoder.encode(date)

        // Decode as string to verify custom encoding
        let decoder = BONJSONDecoder()
        let decoded = try decoder.decode(String.self, from: data)
        XCTAssertEqual(decoded, "custom:1000")
    }

    // MARK: - Data Strategies

    func testDataCustomStrategy() throws {
        let encoder = BONJSONEncoder()
        encoder.dataEncodingStrategy = .custom { data, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(data.map { String(format: "%02x", $0) }.joined())
        }

        let originalData = Data([0x01, 0x02, 0x03])
        let encoded = try encoder.encode(originalData)

        // Decode as string to verify custom encoding
        let decoder = BONJSONDecoder()
        let decoded = try decoder.decode(String.self, from: encoded)
        XCTAssertEqual(decoded, "010203")
    }

    func testDataCustomDecodingStrategy() throws {
        // Encode as hex string
        let encoder = BONJSONEncoder()
        let hexString = "010203"
        let encoded = try encoder.encode(hexString)

        // Decode using custom strategy
        let decoder = BONJSONDecoder()
        decoder.dataDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let hex = try container.decode(String.self)
            var data = Data()
            var index = hex.startIndex
            while index < hex.endIndex {
                let nextIndex = hex.index(index, offsetBy: 2)
                let byteString = String(hex[index..<nextIndex])
                if let byte = UInt8(byteString, radix: 16) {
                    data.append(byte)
                }
                index = nextIndex
            }
            return data
        }

        let decoded = try decoder.decode(Data.self, from: encoded)
        XCTAssertEqual(decoded, Data([0x01, 0x02, 0x03]))
    }

    // MARK: - Key Strategies

    func testCustomKeyEncodingStrategy() throws {
        struct Person: Codable {
            var firstName: String
            var lastName: String
        }

        let encoder = BONJSONEncoder()
        encoder.keyEncodingStrategy = .custom { codingPath in
            let key = codingPath.last!
            // Prefix keys with "custom_"
            return _TestKey(stringValue: "custom_" + key.stringValue)
        }

        let person = Person(firstName: "John", lastName: "Doe")
        let data = try encoder.encode(person)

        // Decode with default keys should fail since keys have been customized
        // Instead, verify the encoding worked by checking data contains custom keys
        // We'll decode with a matching custom strategy
        let decoder = BONJSONDecoder()
        decoder.keyDecodingStrategy = .custom { codingPath in
            let key = codingPath.last!
            // Remove "custom_" prefix if present
            if key.stringValue.hasPrefix("custom_") {
                return _TestKey(stringValue: String(key.stringValue.dropFirst(7)))
            }
            return key
        }

        let decoded = try decoder.decode(Person.self, from: data)
        XCTAssertEqual(decoded.firstName, "John")
        XCTAssertEqual(decoded.lastName, "Doe")
    }

    func testConvertFromSnakeCase() throws {
        // Manually create BONJSON data with snake_case keys
        let encoder = BONJSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase

        struct Person: Codable, Equatable {
            var firstName: String
            var lastName: String
        }

        let person = Person(firstName: "Jane", lastName: "Smith")
        let data = try encoder.encode(person)

        let decoder = BONJSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let decoded = try decoder.decode(Person.self, from: data)
        XCTAssertEqual(decoded, person)
    }

    // MARK: - Non-Conforming Float Strategies

    func testNonConformingFloatEncoding() throws {
        // Test that non-conforming floats are encoded as strings
        let encoder = BONJSONEncoder()
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "+Inf",
            negativeInfinity: "-Inf",
            nan: "NaN"
        )

        let decoder = BONJSONDecoder()

        // Test infinity - should be encoded as "+Inf" string
        let infData = try encoder.encode(Double.infinity)
        let decodedInfString = try decoder.decode(String.self, from: infData)
        XCTAssertEqual(decodedInfString, "+Inf")

        // Test negative infinity - should be encoded as "-Inf" string
        let negInfData = try encoder.encode(-Double.infinity)
        let decodedNegInfString = try decoder.decode(String.self, from: negInfData)
        XCTAssertEqual(decodedNegInfString, "-Inf")

        // Test NaN - should be encoded as "NaN" string
        let nanData = try encoder.encode(Double.nan)
        let decodedNanString = try decoder.decode(String.self, from: nanData)
        XCTAssertEqual(decodedNanString, "NaN")
    }

    func testNonConformingFloatThrows() throws {
        // Test that default strategy throws for non-conforming floats
        let encoder = BONJSONEncoder()
        // Default is .throw

        XCTAssertThrowsError(try encoder.encode(Double.infinity)) { error in
            if let encodingError = error as? BONJSONEncodingError,
               case .invalidFloat(let value) = encodingError {
                XCTAssertEqual(value, .infinity)
            } else {
                XCTFail("Expected invalidFloat error, got \(error)")
            }
        }

        XCTAssertThrowsError(try encoder.encode(Double.nan)) { error in
            if let encodingError = error as? BONJSONEncodingError,
               case .invalidFloat = encodingError {
                // Expected
            } else {
                XCTFail("Expected invalidFloat error, got \(error)")
            }
        }
    }

    // MARK: - Non-Conforming Float Allow Strategy

    func testNonConformingFloatEncodingAllow() throws {
        // Test that non-conforming floats can be encoded as IEEE 754 values
        let encoder = BONJSONEncoder()
        encoder.nonConformingFloatEncodingStrategy = .allow

        let decoder = BONJSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .allow

        // Test infinity round-trip
        let infData = try encoder.encode(Double.infinity)
        let decodedInf = try decoder.decode(Double.self, from: infData)
        XCTAssertEqual(decodedInf, .infinity)

        // Test negative infinity round-trip
        let negInfData = try encoder.encode(-Double.infinity)
        let decodedNegInf = try decoder.decode(Double.self, from: negInfData)
        XCTAssertEqual(decodedNegInf, -.infinity)

        // Test NaN round-trip
        let nanData = try encoder.encode(Double.nan)
        let decodedNan = try decoder.decode(Double.self, from: nanData)
        XCTAssertTrue(decodedNan.isNaN)
    }

    func testNonConformingFloatDecodingThrowsForNaN() throws {
        // Encode with allow, decode with throw should reject
        let encoder = BONJSONEncoder()
        encoder.nonConformingFloatEncodingStrategy = .allow

        let decoder = BONJSONDecoder()
        // Default is .throw

        let nanData = try encoder.encode(Double.nan)
        XCTAssertThrowsError(try decoder.decode(Double.self, from: nanData)) { error in
            if let decodingError = error as? BONJSONDecodingError,
               case .nonConformingFloat = decodingError {
                // Expected
            } else {
                XCTFail("Expected nonConformingFloat error, got \(error)")
            }
        }

        let infData = try encoder.encode(Double.infinity)
        XCTAssertThrowsError(try decoder.decode(Double.self, from: infData)) { error in
            if let decodingError = error as? BONJSONDecodingError,
               case .nonConformingFloat = decodingError {
                // Expected
            } else {
                XCTFail("Expected nonConformingFloat error, got \(error)")
            }
        }
    }

    func testNonConformingFloatConvertFromString() throws {
        // Encode as strings, decode back to floats
        let encoder = BONJSONEncoder()
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "+Inf",
            negativeInfinity: "-Inf",
            nan: "NaN"
        )

        let decoder = BONJSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "+Inf",
            negativeInfinity: "-Inf",
            nan: "NaN"
        )

        // Test infinity round-trip via string
        let infData = try encoder.encode(Double.infinity)
        let decodedInf = try decoder.decode(Double.self, from: infData)
        XCTAssertEqual(decodedInf, .infinity)

        // Test negative infinity round-trip via string
        let negInfData = try encoder.encode(-Double.infinity)
        let decodedNegInf = try decoder.decode(Double.self, from: negInfData)
        XCTAssertEqual(decodedNegInf, -.infinity)

        // Test NaN round-trip via string
        let nanData = try encoder.encode(Double.nan)
        let decodedNan = try decoder.decode(Double.self, from: nanData)
        XCTAssertTrue(decodedNan.isNaN)
    }

    func testNonConformingFloatInKeyedContainer() throws {
        struct Container: Codable, Equatable {
            var value: Double
        }

        let encoder = BONJSONEncoder()
        encoder.nonConformingFloatEncodingStrategy = .allow

        let decoder = BONJSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .allow

        // Test infinity in keyed container
        let infContainer = Container(value: .infinity)
        let infData = try encoder.encode(infContainer)
        let decodedInf = try decoder.decode(Container.self, from: infData)
        XCTAssertEqual(decodedInf.value, .infinity)

        // Test NaN in keyed container
        let nanContainer = Container(value: .nan)
        let nanData = try encoder.encode(nanContainer)
        let decodedNan = try decoder.decode(Container.self, from: nanData)
        XCTAssertTrue(decodedNan.value.isNaN)
    }

    func testNonConformingFloatInUnkeyedContainer() throws {
        let encoder = BONJSONEncoder()
        encoder.nonConformingFloatEncodingStrategy = .allow

        let decoder = BONJSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .allow

        // Test array containing non-conforming floats
        let values: [Double] = [1.0, .infinity, -.infinity, .nan, 2.0]
        let data = try encoder.encode(values)
        let decoded = try decoder.decode([Double].self, from: data)

        XCTAssertEqual(decoded[0], 1.0)
        XCTAssertEqual(decoded[1], .infinity)
        XCTAssertEqual(decoded[2], -.infinity)
        XCTAssertTrue(decoded[3].isNaN)
        XCTAssertEqual(decoded[4], 2.0)
    }

    func testNonConformingFloatConvertFromStringInKeyedContainer() throws {
        struct Container: Codable {
            var value: Double
        }

        let encoder = BONJSONEncoder()
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "Infinity",
            negativeInfinity: "-Infinity",
            nan: "NaN"
        )

        let decoder = BONJSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "Infinity",
            negativeInfinity: "-Infinity",
            nan: "NaN"
        )

        // Test round-trip in keyed container
        let container = Container(value: .infinity)
        let data = try encoder.encode(container)
        let decoded = try decoder.decode(Container.self, from: data)
        XCTAssertEqual(decoded.value, .infinity)
    }
}

// Helper key for custom key strategy tests
private struct _TestKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

// MARK: - Batch Array Tests

final class BONJSONBatchArrayTests: XCTestCase {

    func testBatchDecodeInt64Array() throws {
        let encoder = BONJSONEncoder()
        let decoder = BONJSONDecoder()

        let values: [Int64] = [1, 2, 3, 100, 1000, Int64.max, Int64.min]
        let data = try encoder.encode(values)
        let decoded = try decoder.decode([Int64].self, from: data)
        XCTAssertEqual(decoded, values)
    }

    func testBatchDecodeInt32Array() throws {
        let encoder = BONJSONEncoder()
        let decoder = BONJSONDecoder()

        let values: [Int32] = [1, 2, 3, 100, 1000, Int32.max, Int32.min]
        let data = try encoder.encode(values)
        let decoded = try decoder.decode([Int32].self, from: data)
        XCTAssertEqual(decoded, values)
    }

    func testBatchDecodeInt16Array() throws {
        let encoder = BONJSONEncoder()
        let decoder = BONJSONDecoder()

        let values: [Int16] = [1, 2, 3, 100, 1000, Int16.max, Int16.min]
        let data = try encoder.encode(values)
        let decoded = try decoder.decode([Int16].self, from: data)
        XCTAssertEqual(decoded, values)
    }

    func testBatchDecodeInt8Array() throws {
        let encoder = BONJSONEncoder()
        let decoder = BONJSONDecoder()

        let values: [Int8] = [1, 2, 3, 100, Int8.max, Int8.min]
        let data = try encoder.encode(values)
        let decoded = try decoder.decode([Int8].self, from: data)
        XCTAssertEqual(decoded, values)
    }

    func testBatchDecodeUInt64Array() throws {
        let encoder = BONJSONEncoder()
        let decoder = BONJSONDecoder()

        let values: [UInt64] = [0, 1, 100, 1000, UInt64.max]
        let data = try encoder.encode(values)
        let decoded = try decoder.decode([UInt64].self, from: data)
        XCTAssertEqual(decoded, values)
    }

    func testBatchDecodeUInt32Array() throws {
        let encoder = BONJSONEncoder()
        let decoder = BONJSONDecoder()

        let values: [UInt32] = [0, 1, 100, 1000, UInt32.max]
        let data = try encoder.encode(values)
        let decoded = try decoder.decode([UInt32].self, from: data)
        XCTAssertEqual(decoded, values)
    }

    func testBatchDecodeUInt16Array() throws {
        let encoder = BONJSONEncoder()
        let decoder = BONJSONDecoder()

        let values: [UInt16] = [0, 1, 100, 1000, UInt16.max]
        let data = try encoder.encode(values)
        let decoded = try decoder.decode([UInt16].self, from: data)
        XCTAssertEqual(decoded, values)
    }

    func testBatchDecodeUInt8Array() throws {
        let encoder = BONJSONEncoder()
        let decoder = BONJSONDecoder()

        let values: [UInt8] = [0, 1, 100, UInt8.max]
        let data = try encoder.encode(values)
        let decoded = try decoder.decode([UInt8].self, from: data)
        XCTAssertEqual(decoded, values)
    }

    func testBatchDecodeUIntArray() throws {
        let encoder = BONJSONEncoder()
        let decoder = BONJSONDecoder()

        let values: [UInt] = [0, 1, 100, 1000, 1000000]
        let data = try encoder.encode(values)
        let decoded = try decoder.decode([UInt].self, from: data)
        XCTAssertEqual(decoded, values)
    }

    func testBatchDecodeFloatArray() throws {
        let encoder = BONJSONEncoder()
        let decoder = BONJSONDecoder()

        let values: [Float] = [0.0, 1.5, -1.5, 3.14159, Float.pi]
        let data = try encoder.encode(values)
        let decoded = try decoder.decode([Float].self, from: data)
        for (d, v) in zip(decoded, values) {
            XCTAssertEqual(d, v, accuracy: 0.0001)
        }
    }

    func testBatchDecodeDoubleArray() throws {
        let encoder = BONJSONEncoder()
        let decoder = BONJSONDecoder()

        let values: [Double] = [0.0, 1.5, -1.5, Double.pi, Double.leastNormalMagnitude]
        let data = try encoder.encode(values)
        let decoded = try decoder.decode([Double].self, from: data)
        XCTAssertEqual(decoded, values)
    }

    func testBatchDecodeBoolArray() throws {
        let encoder = BONJSONEncoder()
        let decoder = BONJSONDecoder()

        let values = [true, false, true, true, false]
        let data = try encoder.encode(values)
        let decoded = try decoder.decode([Bool].self, from: data)
        XCTAssertEqual(decoded, values)
    }

    func testBatchDecodeStringArray() throws {
        let encoder = BONJSONEncoder()
        let decoder = BONJSONDecoder()

        let values = ["hello", "world", "test", "", "unicode: 日本語"]
        let data = try encoder.encode(values)
        let decoded = try decoder.decode([String].self, from: data)
        XCTAssertEqual(decoded, values)
    }

    func testBatchDecodeEmptyArrays() throws {
        let encoder = BONJSONEncoder()
        let decoder = BONJSONDecoder()

        // Empty int array
        let emptyInts: [Int] = []
        let intData = try encoder.encode(emptyInts)
        let decodedInts = try decoder.decode([Int].self, from: intData)
        XCTAssertEqual(decodedInts, emptyInts)

        // Empty string array
        let emptyStrings: [String] = []
        let stringData = try encoder.encode(emptyStrings)
        let decodedStrings = try decoder.decode([String].self, from: stringData)
        XCTAssertEqual(decodedStrings, emptyStrings)
    }
}

// MARK: - Nested Container Tests

final class BONJSONNestedContainerTests: XCTestCase {

    func testNestedKeyedContainer() throws {
        struct Outer: Codable, Equatable {
            var inner: Inner

            struct Inner: Codable, Equatable {
                var value: Int
            }
        }

        let encoder = BONJSONEncoder()
        let decoder = BONJSONDecoder()

        let value = Outer(inner: Outer.Inner(value: 42))
        let data = try encoder.encode(value)
        let decoded = try decoder.decode(Outer.self, from: data)
        XCTAssertEqual(decoded, value)
    }

    func testNestedUnkeyedContainer() throws {
        let encoder = BONJSONEncoder()
        let decoder = BONJSONDecoder()

        let value = [[1, 2], [3, 4], [5, 6]]
        let data = try encoder.encode(value)
        let decoded = try decoder.decode([[Int]].self, from: data)
        XCTAssertEqual(decoded, value)
    }

    func testDeeplyNestedStructure() throws {
        struct Level3: Codable, Equatable {
            var value: String
        }
        struct Level2: Codable, Equatable {
            var level3: Level3
        }
        struct Level1: Codable, Equatable {
            var level2: Level2
        }

        let encoder = BONJSONEncoder()
        let decoder = BONJSONDecoder()

        let value = Level1(level2: Level2(level3: Level3(value: "deep")))
        let data = try encoder.encode(value)
        let decoded = try decoder.decode(Level1.self, from: data)
        XCTAssertEqual(decoded, value)
    }

    func testMixedNestedContainers() throws {
        struct Mixed: Codable, Equatable {
            var name: String
            var values: [Int]
            var nested: [String: Int]
        }

        let encoder = BONJSONEncoder()
        let decoder = BONJSONDecoder()

        let value = Mixed(name: "test", values: [1, 2, 3], nested: ["a": 1, "b": 2])
        let data = try encoder.encode(value)
        let decoded = try decoder.decode(Mixed.self, from: data)
        XCTAssertEqual(decoded, value)
    }
}

// MARK: - Error Handling Tests

final class BONJSONErrorTests: XCTestCase {

    func testInvalidURL() throws {
        let encoder = BONJSONEncoder()
        let decoder = BONJSONDecoder()

        // Encode an empty string - URL(string: "") returns nil
        let invalidURLString = ""
        let data = try encoder.encode(invalidURLString)

        XCTAssertThrowsError(try decoder.decode(URL.self, from: data)) { error in
            if let bonError = error as? BONJSONDecodingError,
               case .invalidURL = bonError {
                // Expected error
            } else {
                XCTFail("Expected invalidURL error, got \(error)")
            }
        }
    }

    func testContainerTypeMismatch() throws {
        let encoder = BONJSONEncoder()
        let decoder = BONJSONDecoder()

        // Encode an array, try to decode as object
        let array = [1, 2, 3]
        let data = try encoder.encode(array)

        struct SomeObject: Codable {
            var value: Int
        }

        XCTAssertThrowsError(try decoder.decode(SomeObject.self, from: data))
    }

    func testKeyNotFound() throws {
        let encoder = BONJSONEncoder()
        let decoder = BONJSONDecoder()

        struct Incomplete: Codable {
            var existingField: String
        }

        struct Complete: Codable {
            var existingField: String
            var missingField: String
        }

        let incomplete = Incomplete(existingField: "test")
        let data = try encoder.encode(incomplete)

        XCTAssertThrowsError(try decoder.decode(Complete.self, from: data)) { error in
            guard case DecodingError.keyNotFound = error else {
                XCTFail("Expected keyNotFound error, got \(error)")
                return
            }
        }
    }

    func testDecodeNilInUnkeyedContainer() throws {
        let encoder = BONJSONEncoder()
        let decoder = BONJSONDecoder()

        let optionalArray: [Int?] = [1, nil, 3, nil, 5]
        let data = try encoder.encode(optionalArray)
        let decoded = try decoder.decode([Int?].self, from: data)
        XCTAssertEqual(decoded, optionalArray)
    }
}

// MARK: - Single Value Container Tests

final class BONJSONSingleValueTests: XCTestCase {

    func testEncodeSingleInt() throws {
        let encoder = BONJSONEncoder()
        let decoder = BONJSONDecoder()

        let value = 42
        let data = try encoder.encode(value)
        let decoded = try decoder.decode(Int.self, from: data)
        XCTAssertEqual(decoded, value)
    }

    func testEncodeSingleDouble() throws {
        let encoder = BONJSONEncoder()
        let decoder = BONJSONDecoder()

        let value = 3.14159
        let data = try encoder.encode(value)
        let decoded = try decoder.decode(Double.self, from: data)
        XCTAssertEqual(decoded, value, accuracy: 0.00001)
    }

    func testEncodeSingleString() throws {
        let encoder = BONJSONEncoder()
        let decoder = BONJSONDecoder()

        let value = "Hello, World!"
        let data = try encoder.encode(value)
        let decoded = try decoder.decode(String.self, from: data)
        XCTAssertEqual(decoded, value)
    }

    func testEncodeSingleBool() throws {
        let encoder = BONJSONEncoder()
        let decoder = BONJSONDecoder()

        let trueData = try encoder.encode(true)
        let falseData = try encoder.encode(false)

        XCTAssertTrue(try decoder.decode(Bool.self, from: trueData))
        XCTAssertFalse(try decoder.decode(Bool.self, from: falseData))
    }

    func testDecodeAllIntTypes() throws {
        let encoder = BONJSONEncoder()
        let decoder = BONJSONDecoder()

        // Test all signed integer types
        XCTAssertEqual(try decoder.decode(Int.self, from: try encoder.encode(Int(42))), 42)
        XCTAssertEqual(try decoder.decode(Int8.self, from: try encoder.encode(Int8(42))), 42)
        XCTAssertEqual(try decoder.decode(Int16.self, from: try encoder.encode(Int16(42))), 42)
        XCTAssertEqual(try decoder.decode(Int32.self, from: try encoder.encode(Int32(42))), 42)
        XCTAssertEqual(try decoder.decode(Int64.self, from: try encoder.encode(Int64(42))), 42)

        // Test all unsigned integer types
        XCTAssertEqual(try decoder.decode(UInt.self, from: try encoder.encode(UInt(42))), 42)
        XCTAssertEqual(try decoder.decode(UInt8.self, from: try encoder.encode(UInt8(42))), 42)
        XCTAssertEqual(try decoder.decode(UInt16.self, from: try encoder.encode(UInt16(42))), 42)
        XCTAssertEqual(try decoder.decode(UInt32.self, from: try encoder.encode(UInt32(42))), 42)
        XCTAssertEqual(try decoder.decode(UInt64.self, from: try encoder.encode(UInt64(42))), 42)
    }

    func testDecodeFloatFromInt() throws {
        let encoder = BONJSONEncoder()
        let decoder = BONJSONDecoder()

        // Integers can be decoded as floats
        let intData = try encoder.encode(42)
        let asDouble = try decoder.decode(Double.self, from: intData)
        XCTAssertEqual(asDouble, 42.0)
    }
}

// MARK: - Large Object Tests (to trigger dictionary lookup)

final class BONJSONLargeObjectTests: XCTestCase {

    struct LargeStruct: Codable, Equatable {
        var field1: String
        var field2: String
        var field3: String
        var field4: String
        var field5: String
        var field6: String
        var field7: String
        var field8: String
        var field9: String
        var field10: String
        var field11: String
        var field12: String
        var field13: String
        var field14: String
        var field15: String
    }

    func testLargeStructRoundTrip() throws {
        let encoder = BONJSONEncoder()
        let decoder = BONJSONDecoder()

        let value = LargeStruct(
            field1: "a", field2: "b", field3: "c", field4: "d", field5: "e",
            field6: "f", field7: "g", field8: "h", field9: "i", field10: "j",
            field11: "k", field12: "l", field13: "m", field14: "n", field15: "o"
        )

        let data = try encoder.encode(value)
        let decoded = try decoder.decode(LargeStruct.self, from: data)
        XCTAssertEqual(decoded, value)
    }

    func testLargeStructContainsKey() throws {
        let encoder = BONJSONEncoder()
        let decoder = BONJSONDecoder()

        struct PartialLargeStruct: Codable {
            var field1: String
            var field15: String
            // Deliberately skip middle fields to test dictionary lookup
        }

        let value = LargeStruct(
            field1: "first", field2: "b", field3: "c", field4: "d", field5: "e",
            field6: "f", field7: "g", field8: "h", field9: "i", field10: "j",
            field11: "k", field12: "l", field13: "m", field14: "n", field15: "last"
        )

        let data = try encoder.encode(value)
        let decoded = try decoder.decode(PartialLargeStruct.self, from: data)
        XCTAssertEqual(decoded.field1, "first")
        XCTAssertEqual(decoded.field15, "last")
    }
}

// MARK: - Integer Type Coverage Tests

final class BONJSONIntegerTypeTests: XCTestCase {

    func testAllIntegerTypesInKeyedContainer() throws {
        struct AllInts: Codable, Equatable {
            var int8: Int8
            var int16: Int16
            var int32: Int32
            var int64: Int64
            var uint8: UInt8
            var uint16: UInt16
            var uint32: UInt32
            var uint64: UInt64
        }

        let encoder = BONJSONEncoder()
        let decoder = BONJSONDecoder()

        let value = AllInts(
            int8: -100, int16: -1000, int32: -100000, int64: -10000000000,
            uint8: 200, uint16: 50000, uint32: 4000000000, uint64: 10000000000000
        )
        let data = try encoder.encode(value)
        let decoded = try decoder.decode(AllInts.self, from: data)
        XCTAssertEqual(decoded, value)
    }

    func testAllIntegerTypesInUnkeyedContainer() throws {
        let encoder = BONJSONEncoder()
        let decoder = BONJSONDecoder()

        // Test each integer type in arrays via Codable
        struct IntArrays: Codable, Equatable {
            var int8s: [Int8]
            var int16s: [Int16]
            var int32s: [Int32]
            var uint8s: [UInt8]
            var uint16s: [UInt16]
            var uint32s: [UInt32]
        }

        let value = IntArrays(
            int8s: [1, -1, Int8.max, Int8.min],
            int16s: [1, -1, Int16.max, Int16.min],
            int32s: [1, -1, Int32.max, Int32.min],
            uint8s: [0, 1, UInt8.max],
            uint16s: [0, 1, UInt16.max],
            uint32s: [0, 1, UInt32.max]
        )
        let data = try encoder.encode(value)
        let decoded = try decoder.decode(IntArrays.self, from: data)
        XCTAssertEqual(decoded, value)
    }

    func testFloatTypesInUnkeyedContainer() throws {
        let encoder = BONJSONEncoder()
        let decoder = BONJSONDecoder()

        // Test float array via Codable
        struct FloatArrays: Codable {
            var floats: [Float]
            var doubles: [Double]
        }

        let value = FloatArrays(
            floats: [0.0, 1.5, -1.5, Float.pi],
            doubles: [0.0, 1.5, -1.5, Double.pi]
        )
        let data = try encoder.encode(value)
        let decoded = try decoder.decode(FloatArrays.self, from: data)
        for (d, v) in zip(decoded.floats, value.floats) {
            XCTAssertEqual(d, v, accuracy: 0.0001)
        }
        XCTAssertEqual(decoded.doubles, value.doubles)
    }
}

// MARK: - Nil Encoding Tests

final class BONJSONNilTests: XCTestCase {

    func testEncodeNilInKeyedContainer() throws {
        struct WithOptional: Codable, Equatable {
            var name: String
            var value: Int?
        }

        let encoder = BONJSONEncoder()
        let decoder = BONJSONDecoder()

        // Test with nil value
        let withNil = WithOptional(name: "test", value: nil)
        let nilData = try encoder.encode(withNil)
        let decodedNil = try decoder.decode(WithOptional.self, from: nilData)
        XCTAssertEqual(decodedNil, withNil)

        // Test with non-nil value
        let withValue = WithOptional(name: "test", value: 42)
        let valueData = try encoder.encode(withValue)
        let decodedValue = try decoder.decode(WithOptional.self, from: valueData)
        XCTAssertEqual(decodedValue, withValue)
    }

    func testEncodeNilInUnkeyedContainer() throws {
        let encoder = BONJSONEncoder()
        let decoder = BONJSONDecoder()

        let array: [String?] = ["a", nil, "c", nil]
        let data = try encoder.encode(array)
        let decoded = try decoder.decode([String?].self, from: data)
        XCTAssertEqual(decoded, array)
    }

    func testSingleNilValue() throws {
        let encoder = BONJSONEncoder()
        let decoder = BONJSONDecoder()

        let nilValue: Int? = nil
        let data = try encoder.encode(nilValue)
        let decoded = try decoder.decode(Int?.self, from: data)
        XCTAssertNil(decoded)
    }

    func testExplicitEncodeNilForKey() throws {
        // This struct explicitly encodes nil values using encodeNil(forKey:)
        struct ExplicitNil: Codable, Equatable {
            var name: String
            var value: Int?

            enum CodingKeys: String, CodingKey {
                case name, value
            }

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(name, forKey: .name)
                if let value = value {
                    try container.encode(value, forKey: .value)
                } else {
                    // Explicitly encode nil instead of skipping
                    try container.encodeNil(forKey: .value)
                }
            }

            init(name: String, value: Int?) {
                self.name = name
                self.value = value
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                name = try container.decode(String.self, forKey: .name)
                // Check if value is nil or missing
                if try container.decodeNil(forKey: .value) {
                    value = nil
                } else {
                    value = try container.decode(Int.self, forKey: .value)
                }
            }
        }

        let encoder = BONJSONEncoder()
        let decoder = BONJSONDecoder()

        // Test with explicit nil
        let withNil = ExplicitNil(name: "test", value: nil)
        let nilData = try encoder.encode(withNil)
        let decodedNil = try decoder.decode(ExplicitNil.self, from: nilData)
        XCTAssertEqual(decodedNil, withNil)

        // Test with value
        let withValue = ExplicitNil(name: "test", value: 42)
        let valueData = try encoder.encode(withValue)
        let decodedValue = try decoder.decode(ExplicitNil.self, from: valueData)
        XCTAssertEqual(decodedValue, withValue)
    }
}

// MARK: - Manual Container Tests

final class BONJSONManualContainerTests: XCTestCase {

    // Test encoding UInt in keyed container (line 673)
    func testEncodeUIntInKeyedContainer() throws {
        struct WithUInt: Codable, Equatable {
            var value: UInt

            enum CodingKeys: String, CodingKey {
                case value
            }

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(value, forKey: .value)  // Calls encode(_ value: UInt, forKey:)
            }
        }

        let encoder = BONJSONEncoder()
        let decoder = BONJSONDecoder()

        let value = WithUInt(value: 12345)
        let data = try encoder.encode(value)
        let decoded = try decoder.decode(WithUInt.self, from: data)
        XCTAssertEqual(decoded, value)
    }

    // Test nestedContainer(keyedBy:forKey:) (line 740)
    func testNestedKeyedContainerInKeyedContainer() throws {
        struct Outer: Codable, Equatable {
            var name: String
            var inner: Inner

            struct Inner: Codable, Equatable {
                var x: Int
                var y: Int

                enum CodingKeys: String, CodingKey {
                    case x, y
                }
            }

            enum CodingKeys: String, CodingKey {
                case name, inner
            }

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(name, forKey: .name)

                // Manually create nested keyed container
                var nestedContainer = container.nestedContainer(keyedBy: Inner.CodingKeys.self, forKey: .inner)
                try nestedContainer.encode(inner.x, forKey: .x)
                try nestedContainer.encode(inner.y, forKey: .y)
            }

            init(name: String, inner: Inner) {
                self.name = name
                self.inner = inner
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                name = try container.decode(String.self, forKey: .name)
                inner = try container.decode(Inner.self, forKey: .inner)
            }
        }

        let encoder = BONJSONEncoder()
        let decoder = BONJSONDecoder()

        let value = Outer(name: "test", inner: Outer.Inner(x: 10, y: 20))
        let data = try encoder.encode(value)
        let decoded = try decoder.decode(Outer.self, from: data)
        XCTAssertEqual(decoded, value)
    }

    // Test nestedUnkeyedContainer(forKey:) (line 758)
    func testNestedUnkeyedContainerInKeyedContainer() throws {
        struct WithArray: Codable, Equatable {
            var name: String
            var values: [Int]

            enum CodingKeys: String, CodingKey {
                case name, values
            }

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(name, forKey: .name)

                // Manually create nested unkeyed container
                var nestedContainer = container.nestedUnkeyedContainer(forKey: .values)
                for value in values {
                    try nestedContainer.encode(value)
                }
            }

            init(name: String, values: [Int]) {
                self.name = name
                self.values = values
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                name = try container.decode(String.self, forKey: .name)
                values = try container.decode([Int].self, forKey: .values)
            }
        }

        let encoder = BONJSONEncoder()
        let decoder = BONJSONDecoder()

        let value = WithArray(name: "test", values: [1, 2, 3])
        let data = try encoder.encode(value)
        let decoded = try decoder.decode(WithArray.self, from: data)
        XCTAssertEqual(decoded, value)
    }

    // Test encodeNil() in unkeyed container (line 817)
    func testEncodeNilInUnkeyedContainer() throws {
        struct ArrayWithNils: Codable, Equatable {
            var values: [Int?]

            func encode(to encoder: Encoder) throws {
                var container = encoder.unkeyedContainer()
                for value in values {
                    if let v = value {
                        try container.encode(v)
                    } else {
                        try container.encodeNil()  // Explicitly encode nil
                    }
                }
            }

            init(values: [Int?]) {
                self.values = values
            }

            init(from decoder: Decoder) throws {
                var container = try decoder.unkeyedContainer()
                var values: [Int?] = []
                while !container.isAtEnd {
                    if try container.decodeNil() {
                        values.append(nil)
                    } else {
                        values.append(try container.decode(Int.self))
                    }
                }
                self.values = values
            }
        }

        let encoder = BONJSONEncoder()
        let decoder = BONJSONDecoder()

        let value = ArrayWithNils(values: [1, nil, 3, nil, 5])
        let data = try encoder.encode(value)
        let decoded = try decoder.decode(ArrayWithNils.self, from: data)
        XCTAssertEqual(decoded, value)
    }

    // Test superEncoder(forKey:) (line 776) with a custom key that works
    func testSuperEncoderForKey() throws {
        struct CustomCodingKey: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }

            init(stringValue: String) {
                self.stringValue = stringValue
            }

            init?(intValue: Int) { nil }
        }

        struct Parent: Codable {
            var parentValue: Int

            init(parentValue: Int) {
                self.parentValue = parentValue
            }

            enum CodingKeys: String, CodingKey {
                case parentValue
            }
        }

        struct Child: Codable, Equatable {
            var childValue: String
            var parentValue: Int

            enum CodingKeys: String, CodingKey {
                case childValue
                case parentData  // Key for the super encoder
            }

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(childValue, forKey: .childValue)

                // Use superEncoder with a specific key
                let superEnc = container.superEncoder(forKey: .parentData)
                var superContainer = superEnc.container(keyedBy: Parent.CodingKeys.self)
                try superContainer.encode(parentValue, forKey: .parentValue)
            }

            init(childValue: String, parentValue: Int) {
                self.childValue = childValue
                self.parentValue = parentValue
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                childValue = try container.decode(String.self, forKey: .childValue)
                let superDec = try container.superDecoder(forKey: .parentData)
                let superContainer = try superDec.container(keyedBy: Parent.CodingKeys.self)
                parentValue = try superContainer.decode(Int.self, forKey: .parentValue)
            }
        }

        let encoder = BONJSONEncoder()
        let decoder = BONJSONDecoder()

        let value = Child(childValue: "test", parentValue: 42)
        let data = try encoder.encode(value)
        let decoded = try decoder.decode(Child.self, from: data)
        XCTAssertEqual(decoded, value)
    }

    // Test nested containers in unkeyed container
    func testNestedKeyedContainerInUnkeyedContainer() throws {
        struct Item: Codable, Equatable {
            var x: Int
            var y: Int

            enum CodingKeys: String, CodingKey {
                case x, y
            }
        }

        struct ItemList: Codable, Equatable {
            var items: [Item]

            func encode(to encoder: Encoder) throws {
                var container = encoder.unkeyedContainer()
                for item in items {
                    // Create nested keyed container in unkeyed container
                    var nestedContainer = container.nestedContainer(keyedBy: Item.CodingKeys.self)
                    try nestedContainer.encode(item.x, forKey: .x)
                    try nestedContainer.encode(item.y, forKey: .y)
                }
            }

            init(items: [Item]) {
                self.items = items
            }

            init(from decoder: Decoder) throws {
                var container = try decoder.unkeyedContainer()
                var items: [Item] = []
                while !container.isAtEnd {
                    items.append(try container.decode(Item.self))
                }
                self.items = items
            }
        }

        let encoder = BONJSONEncoder()
        let decoder = BONJSONDecoder()

        let value = ItemList(items: [Item(x: 1, y: 2), Item(x: 3, y: 4)])
        let data = try encoder.encode(value)
        let decoded = try decoder.decode(ItemList.self, from: data)
        XCTAssertEqual(decoded, value)
    }

    // Test nested unkeyed container in unkeyed container
    func testNestedUnkeyedContainerInUnkeyedContainer() throws {
        struct Matrix: Codable, Equatable {
            var rows: [[Int]]

            func encode(to encoder: Encoder) throws {
                var container = encoder.unkeyedContainer()
                for row in rows {
                    var nestedContainer = container.nestedUnkeyedContainer()
                    for value in row {
                        try nestedContainer.encode(value)
                    }
                }
            }

            init(rows: [[Int]]) {
                self.rows = rows
            }

            init(from decoder: Decoder) throws {
                var container = try decoder.unkeyedContainer()
                var rows: [[Int]] = []
                while !container.isAtEnd {
                    var row: [Int] = []
                    var nestedContainer = try container.nestedUnkeyedContainer()
                    while !nestedContainer.isAtEnd {
                        row.append(try nestedContainer.decode(Int.self))
                    }
                    rows.append(row)
                }
                self.rows = rows
            }
        }

        let encoder = BONJSONEncoder()
        let decoder = BONJSONDecoder()

        let value = Matrix(rows: [[1, 2], [3, 4, 5], [6]])
        let data = try encoder.encode(value)
        let decoded = try decoder.decode(Matrix.self, from: data)
        XCTAssertEqual(decoded, value)
    }

    // Test superEncoder() no-argument version (line 772)
    func testSuperEncoderNoArgument() throws {
        class Parent: Codable {
            var parentValue: Int

            init(parentValue: Int) {
                self.parentValue = parentValue
            }

            enum CodingKeys: String, CodingKey {
                case parentValue
            }
        }

        class Child: Parent {
            var childValue: String

            init(childValue: String, parentValue: Int) {
                self.childValue = childValue
                super.init(parentValue: parentValue)
            }

            enum ChildCodingKeys: String, CodingKey {
                case childValue
            }

            required init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: ChildCodingKeys.self)
                childValue = try container.decode(String.self, forKey: .childValue)
                // Use superDecoder() no-argument to decode parent
                try super.init(from: try container.superDecoder())
            }

            override func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: ChildCodingKeys.self)
                try container.encode(childValue, forKey: .childValue)
                // Use superEncoder() no-argument (encodes to "super" key)
                try super.encode(to: container.superEncoder())
            }
        }

        let encoder = BONJSONEncoder()
        let decoder = BONJSONDecoder()

        let value = Child(childValue: "test", parentValue: 42)
        let data = try encoder.encode(value)
        let decoded = try decoder.decode(Child.self, from: data)
        XCTAssertEqual(decoded.childValue, value.childValue)
        XCTAssertEqual(decoded.parentValue, value.parentValue)
    }
}

// MARK: - Unkeyed Container Nested Tests

final class BONJSONUnkeyedNestedTests: XCTestCase {

    func testNestedKeyedInUnkeyed() throws {
        struct Item: Codable, Equatable {
            var x: Int
            var y: Int
        }

        let encoder = BONJSONEncoder()
        let decoder = BONJSONDecoder()

        let items = [Item(x: 1, y: 2), Item(x: 3, y: 4)]
        let data = try encoder.encode(items)
        let decoded = try decoder.decode([Item].self, from: data)
        XCTAssertEqual(decoded, items)
    }

    func testNestedUnkeyedInUnkeyed() throws {
        let encoder = BONJSONEncoder()
        let decoder = BONJSONDecoder()

        let matrix = [[1, 2, 3], [4, 5, 6], [7, 8, 9]]
        let data = try encoder.encode(matrix)
        let decoded = try decoder.decode([[Int]].self, from: data)
        XCTAssertEqual(decoded, matrix)
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

    func testLongStringLengthFieldEncoding() throws {
        let encoder = BONJSONEncoder()

        // Test 20-character string: length=20, continuation=0
        // payload = 20 << 1 = 40
        // 1-byte encoding: 40 << 1 = 80 = 0x50
        let str20 = String(repeating: "a", count: 20)
        let data20 = try encoder.encode(str20)
        XCTAssertEqual(data20[0], 0xf0, "First byte should be long string type")
        XCTAssertEqual(data20[1], 0x50, "Length field for 20 chars should be 0x50")

        // Test 64-character string: length=64, continuation=0
        // payload = 64 << 1 = 128
        // 128 > 127, so 2-byte encoding needed
        // extraBytes = 1, count = 2
        // encoded = (128 << 2) | ((1 << 1) - 1) = 512 | 1 = 513 = 0x0201
        // In little-endian: 0x01, 0x02
        let str64 = String(repeating: "b", count: 64)
        let data64 = try encoder.encode(str64)
        XCTAssertEqual(data64[0], 0xf0, "First byte should be long string type")
        XCTAssertEqual(data64[1], 0x01, "First byte of length field for 64 chars should be 0x01")
        XCTAssertEqual(data64[2], 0x02, "Second byte of length field for 64 chars should be 0x02")

        // Test empty long string encoding (if encoder uses long string for empty)
        // Actually, empty string uses short string encoding (0xe0), so skip this

        // Verify the string content follows the length field
        XCTAssertEqual(data20[2], UInt8(ascii: "a"), "String content should follow length field")
        XCTAssertEqual(data64[3], UInt8(ascii: "b"), "String content should follow 2-byte length field")
    }

    func testLongStringDecodeSpecificBytes() throws {
        let decoder = BONJSONDecoder()

        // Decode a long string with specific byte encoding
        // 0xf0 = long string type
        // 0x50 = length field (20 chars, no continuation): payload=40, 40<<1=80=0x50
        var data = Data([0xf0, 0x50])
        data.append(contentsOf: [UInt8](repeating: UInt8(ascii: "x"), count: 20))

        let decoded = try decoder.decode(String.self, from: data)
        XCTAssertEqual(decoded, String(repeating: "x", count: 20))

        // Test decoding empty long string (length=0, continuation=0 = 0x00)
        let emptyData = Data([0xf0, 0x00])
        let emptyDecoded = try decoder.decode(String.self, from: emptyData)
        XCTAssertEqual(emptyDecoded, "")
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

// MARK: - Unkeyed Container Primitive Tests

final class BONJSONUnkeyedPrimitiveTests: XCTestCase {

    // Test all primitive types encoded directly in unkeyed container
    func testUnkeyedContainerAllPrimitives() throws {
        struct AllPrimitives: Codable, Equatable {
            var boolVal: Bool
            var stringVal: String
            var doubleVal: Double
            var floatVal: Float
            var int8Val: Int8
            var int16Val: Int16
            var int32Val: Int32
            var int64Val: Int64
            var uintVal: UInt
            var uint8Val: UInt8
            var uint16Val: UInt16
            var uint32Val: UInt32
            var uint64Val: UInt64

            func encode(to encoder: Encoder) throws {
                var container = encoder.unkeyedContainer()
                try container.encode(boolVal)
                try container.encode(stringVal)
                try container.encode(doubleVal)
                try container.encode(floatVal)
                try container.encode(int8Val)
                try container.encode(int16Val)
                try container.encode(int32Val)
                try container.encode(int64Val)
                try container.encode(uintVal)
                try container.encode(uint8Val)
                try container.encode(uint16Val)
                try container.encode(uint32Val)
                try container.encode(uint64Val)
            }

            init(from decoder: Decoder) throws {
                var container = try decoder.unkeyedContainer()
                boolVal = try container.decode(Bool.self)
                stringVal = try container.decode(String.self)
                doubleVal = try container.decode(Double.self)
                floatVal = try container.decode(Float.self)
                int8Val = try container.decode(Int8.self)
                int16Val = try container.decode(Int16.self)
                int32Val = try container.decode(Int32.self)
                int64Val = try container.decode(Int64.self)
                uintVal = try container.decode(UInt.self)
                uint8Val = try container.decode(UInt8.self)
                uint16Val = try container.decode(UInt16.self)
                uint32Val = try container.decode(UInt32.self)
                uint64Val = try container.decode(UInt64.self)
            }

            init() {
                boolVal = true
                stringVal = "test"
                doubleVal = 3.14159
                floatVal = 2.5
                int8Val = -42
                int16Val = -1000
                int32Val = -100000
                int64Val = -10000000000
                uintVal = 12345
                uint8Val = 200
                uint16Val = 50000
                uint32Val = 3000000000
                uint64Val = 10000000000000000000
            }
        }

        let encoder = BONJSONEncoder()
        let decoder = BONJSONDecoder()

        let value = AllPrimitives()
        let data = try encoder.encode(value)
        let decoded = try decoder.decode(AllPrimitives.self, from: data)
        XCTAssertEqual(decoded, value)
    }

    // Test superEncoder in unkeyed container
    func testSuperEncoderInUnkeyedContainer() throws {
        struct Parent: Codable, Equatable {
            var parentValue: Int

            enum CodingKeys: String, CodingKey {
                case parentValue
            }
        }

        struct ArrayWithSuper: Codable, Equatable {
            var count: Int
            var parentData: Parent

            func encode(to encoder: Encoder) throws {
                var container = encoder.unkeyedContainer()
                // First encode count so we know how many items follow
                try container.encode(count)
                // Use superEncoder in unkeyed container
                let superEnc = container.superEncoder()
                try parentData.encode(to: superEnc)
            }

            init(count: Int, parentData: Parent) {
                self.count = count
                self.parentData = parentData
            }

            init(from decoder: Decoder) throws {
                var container = try decoder.unkeyedContainer()
                self.count = try container.decode(Int.self)
                // Decode parent using superDecoder
                let superDec = try container.superDecoder()
                self.parentData = try Parent(from: superDec)
            }
        }

        let encoder = BONJSONEncoder()
        let decoder = BONJSONDecoder()

        let value = ArrayWithSuper(count: 42, parentData: Parent(parentValue: 99))
        let data = try encoder.encode(value)
        let decoded = try decoder.decode(ArrayWithSuper.self, from: data)
        XCTAssertEqual(decoded.count, value.count)
        XCTAssertEqual(decoded.parentData, value.parentData)
    }

    // Test Float in keyed container
    func testFloatInKeyedContainer() throws {
        struct WithFloat: Codable, Equatable {
            var value: Float

            enum CodingKeys: String, CodingKey {
                case value
            }

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(value, forKey: .value)
            }

            init(value: Float) {
                self.value = value
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                value = try container.decode(Float.self, forKey: .value)
            }
        }

        let encoder = BONJSONEncoder()
        let decoder = BONJSONDecoder()

        let value = WithFloat(value: 3.14)
        let data = try encoder.encode(value)
        let decoded = try decoder.decode(WithFloat.self, from: data)
        XCTAssertEqual(decoded.value, value.value, accuracy: 0.001)
    }
}

// MARK: - Single Value Container Tests

final class BONJSONSingleValueContainerTests: XCTestCase {

    // Test single value encoding/decoding for primitives
    func testSingleValueInt64() throws {
        let encoder = BONJSONEncoder()
        let decoder = BONJSONDecoder()

        let value: Int64 = -9223372036854775807
        let data = try encoder.encode(value)
        let decoded = try decoder.decode(Int64.self, from: data)
        XCTAssertEqual(decoded, value)
    }

    func testSingleValueUInt64() throws {
        let encoder = BONJSONEncoder()
        let decoder = BONJSONDecoder()

        let value: UInt64 = 18446744073709551615
        let data = try encoder.encode(value)
        let decoded = try decoder.decode(UInt64.self, from: data)
        XCTAssertEqual(decoded, value)
    }

    func testSingleValueBool() throws {
        let encoder = BONJSONEncoder()
        let decoder = BONJSONDecoder()

        let data = try encoder.encode(true)
        let decoded = try decoder.decode(Bool.self, from: data)
        XCTAssertEqual(decoded, true)
    }

    func testSingleValueNil() throws {
        let encoder = BONJSONEncoder()
        let decoder = BONJSONDecoder()

        let value: Int? = nil
        let data = try encoder.encode(value)
        let decoded = try decoder.decode(Int?.self, from: data)
        XCTAssertNil(decoded)
    }

    func testSingleValueURL() throws {
        let encoder = BONJSONEncoder()
        let decoder = BONJSONDecoder()

        let value = URL(string: "https://example.com/path")!
        let data = try encoder.encode(value)
        let decoded = try decoder.decode(URL.self, from: data)
        XCTAssertEqual(decoded, value)
    }

    func testSingleValueDate() throws {
        let encoder = BONJSONEncoder()
        let decoder = BONJSONDecoder()

        let value = Date(timeIntervalSince1970: 1234567890)
        let data = try encoder.encode(value)
        let decoded = try decoder.decode(Date.self, from: data)
        XCTAssertEqual(decoded.timeIntervalSince1970, value.timeIntervalSince1970, accuracy: 0.001)
    }

    func testSingleValueData() throws {
        let encoder = BONJSONEncoder()
        let decoder = BONJSONDecoder()

        let value = Data([0x01, 0x02, 0x03, 0x04])
        let data = try encoder.encode(value)
        let decoded = try decoder.decode(Data.self, from: data)
        XCTAssertEqual(decoded, value)
    }
}

// MARK: - Large Object Tests (Dictionary Cache Path)

final class BONJSONLargeObjectKeyLookupTests: XCTestCase {

    // Test object with > 12 fields to trigger dictionary cache path
    func testLargeObjectDictionaryCache() throws {
        struct LargeObject: Codable, Equatable {
            var a: Int, b: Int, c: Int, d: Int, e: Int
            var f: Int, g: Int, h: Int, i: Int, j: Int
            var k: Int, l: Int, m: Int, n: Int, o: Int
        }

        let encoder = BONJSONEncoder()
        let decoder = BONJSONDecoder()

        let value = LargeObject(a: 1, b: 2, c: 3, d: 4, e: 5,
                                f: 6, g: 7, h: 8, i: 9, j: 10,
                                k: 11, l: 12, m: 13, n: 14, o: 15)
        let data = try encoder.encode(value)
        let decoded = try decoder.decode(LargeObject.self, from: data)
        XCTAssertEqual(decoded, value)
    }
}

// MARK: - Nested Container Decoder Tests

final class BONJSONNestedContainerDecoderTests: XCTestCase {

    // Test nestedContainer in keyed decoder
    func testNestedKeyedContainerInKeyedDecoder() throws {
        struct Outer: Codable, Equatable {
            var name: String
            var inner: Inner

            struct Inner: Codable, Equatable {
                var x: Int
                var y: Int

                enum CodingKeys: String, CodingKey {
                    case x, y
                }
            }

            enum CodingKeys: String, CodingKey {
                case name, inner
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                name = try container.decode(String.self, forKey: .name)
                // Use nestedContainer to decode inner
                let nestedContainer = try container.nestedContainer(keyedBy: Inner.CodingKeys.self, forKey: .inner)
                let x = try nestedContainer.decode(Int.self, forKey: .x)
                let y = try nestedContainer.decode(Int.self, forKey: .y)
                inner = Inner(x: x, y: y)
            }

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(name, forKey: .name)
                try container.encode(inner, forKey: .inner)
            }

            init(name: String, inner: Inner) {
                self.name = name
                self.inner = inner
            }
        }

        let encoder = BONJSONEncoder()
        let decoder = BONJSONDecoder()

        let value = Outer(name: "test", inner: Outer.Inner(x: 10, y: 20))
        let data = try encoder.encode(value)
        let decoded = try decoder.decode(Outer.self, from: data)
        XCTAssertEqual(decoded, value)
    }

    // Test nestedUnkeyedContainer in keyed decoder
    func testNestedUnkeyedContainerInKeyedDecoder() throws {
        struct WithArray: Codable, Equatable {
            var name: String
            var values: [Int]

            enum CodingKeys: String, CodingKey {
                case name, values
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                name = try container.decode(String.self, forKey: .name)
                // Use nestedUnkeyedContainer to decode values
                var nestedContainer = try container.nestedUnkeyedContainer(forKey: .values)
                var values: [Int] = []
                while !nestedContainer.isAtEnd {
                    values.append(try nestedContainer.decode(Int.self))
                }
                self.values = values
            }

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(name, forKey: .name)
                try container.encode(values, forKey: .values)
            }

            init(name: String, values: [Int]) {
                self.name = name
                self.values = values
            }
        }

        let encoder = BONJSONEncoder()
        let decoder = BONJSONDecoder()

        let value = WithArray(name: "test", values: [1, 2, 3, 4, 5])
        let data = try encoder.encode(value)
        let decoded = try decoder.decode(WithArray.self, from: data)
        XCTAssertEqual(decoded, value)
    }

    // Test nestedContainer in unkeyed decoder
    func testNestedKeyedContainerInUnkeyedDecoder() throws {
        struct Item: Codable, Equatable {
            var x: Int
            var y: Int

            enum CodingKeys: String, CodingKey {
                case x, y
            }
        }

        struct ItemList: Codable, Equatable {
            var items: [Item]

            init(from decoder: Decoder) throws {
                var container = try decoder.unkeyedContainer()
                var items: [Item] = []
                while !container.isAtEnd {
                    // Use nestedContainer in unkeyed decoder
                    let nestedContainer = try container.nestedContainer(keyedBy: Item.CodingKeys.self)
                    let x = try nestedContainer.decode(Int.self, forKey: .x)
                    let y = try nestedContainer.decode(Int.self, forKey: .y)
                    items.append(Item(x: x, y: y))
                }
                self.items = items
            }

            func encode(to encoder: Encoder) throws {
                var container = encoder.unkeyedContainer()
                for item in items {
                    try container.encode(item)
                }
            }

            init(items: [Item]) {
                self.items = items
            }
        }

        let encoder = BONJSONEncoder()
        let decoder = BONJSONDecoder()

        let value = ItemList(items: [Item(x: 1, y: 2), Item(x: 3, y: 4)])
        let data = try encoder.encode(value)
        let decoded = try decoder.decode(ItemList.self, from: data)
        XCTAssertEqual(decoded, value)
    }
}

// MARK: - URL/Date/Data in Containers Tests

final class BONJSONSpecialTypesInContainersTests: XCTestCase {

    // Test URL in keyed container
    func testURLInKeyedContainer() throws {
        struct WithURL: Codable, Equatable {
            var url: URL
        }

        let encoder = BONJSONEncoder()
        let decoder = BONJSONDecoder()

        let value = WithURL(url: URL(string: "https://example.com")!)
        let data = try encoder.encode(value)
        let decoded = try decoder.decode(WithURL.self, from: data)
        XCTAssertEqual(decoded, value)
    }

    // Test URL in unkeyed container
    func testURLInUnkeyedContainer() throws {
        let encoder = BONJSONEncoder()
        let decoder = BONJSONDecoder()

        let value = [URL(string: "https://a.com")!, URL(string: "https://b.com")!]
        let data = try encoder.encode(value)
        let decoded = try decoder.decode([URL].self, from: data)
        XCTAssertEqual(decoded, value)
    }

    // Test Date in unkeyed container
    func testDateInUnkeyedContainer() throws {
        let encoder = BONJSONEncoder()
        let decoder = BONJSONDecoder()

        let value = [Date(timeIntervalSince1970: 1000), Date(timeIntervalSince1970: 2000)]
        let data = try encoder.encode(value)
        let decoded = try decoder.decode([Date].self, from: data)
        XCTAssertEqual(decoded[0].timeIntervalSince1970, value[0].timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(decoded[1].timeIntervalSince1970, value[1].timeIntervalSince1970, accuracy: 0.001)
    }

    // Test Data in unkeyed container
    func testDataInUnkeyedContainer() throws {
        let encoder = BONJSONEncoder()
        let decoder = BONJSONDecoder()

        let value = [Data([1, 2, 3]), Data([4, 5, 6])]
        let data = try encoder.encode(value)
        let decoded = try decoder.decode([Data].self, from: data)
        XCTAssertEqual(decoded, value)
    }
}

// MARK: - AllKeys and CodingPath Tests

final class BONJSONAllKeysTests: XCTestCase {

    // Test allKeys property in keyed container (covers toArray() path)
    func testAllKeysInKeyedContainer() throws {
        // Use a flexible key type that can handle both known and dynamic fields
        struct FlexibleKey: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { nil }

            static let knownField = FlexibleKey(stringValue: "knownField")
        }

        struct DynamicObject: Codable, Equatable {
            var knownField: String
            var dynamicFields: [String: Int]

            init(knownField: String, dynamicFields: [String: Int]) {
                self.knownField = knownField
                self.dynamicFields = dynamicFields
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: FlexibleKey.self)
                knownField = try container.decode(String.self, forKey: .knownField)

                // Use allKeys to discover dynamic fields
                var fields: [String: Int] = [:]
                for key in container.allKeys {
                    if key.stringValue != "knownField" {
                        if let value = try? container.decode(Int.self, forKey: key) {
                            fields[key.stringValue] = value
                        }
                    }
                }
                dynamicFields = fields
            }

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: FlexibleKey.self)
                try container.encode(knownField, forKey: .knownField)
                for (key, value) in dynamicFields.sorted(by: { $0.key < $1.key }) {
                    try container.encode(value, forKey: FlexibleKey(stringValue: key))
                }
            }
        }

        let encoder = BONJSONEncoder()
        let decoder = BONJSONDecoder()

        let value = DynamicObject(knownField: "test", dynamicFields: ["a": 1, "b": 2, "c": 3])
        let data = try encoder.encode(value)
        let decoded = try decoder.decode(DynamicObject.self, from: data)
        XCTAssertEqual(decoded.knownField, value.knownField)
        XCTAssertEqual(decoded.dynamicFields.count, 3)
        XCTAssertEqual(decoded.dynamicFields["a"], 1)
        XCTAssertEqual(decoded.dynamicFields["b"], 2)
        XCTAssertEqual(decoded.dynamicFields["c"], 3)
    }
}

// MARK: - UInt as Int64 Decoding Tests

final class BONJSONUIntAsIntTests: XCTestCase {

    // Test decoding unsigned int that fits in Int64 (covers UINT case in decodeInt64)
    func testDecodeUIntAsInt64() throws {
        // Encode a UInt64 value that fits in Int64
        let encoder = BONJSONEncoder()
        let decoder = BONJSONDecoder()

        // Use a struct that encodes as UInt but decodes as Int
        struct UIntHolder: Encodable {
            var value: UInt64
        }

        struct IntHolder: Decodable {
            var value: Int64
        }

        // Value 200 (0xC8) has MSB set in 1 byte, so it will be encoded as UINT
        let original = UIntHolder(value: 200)
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(IntHolder.self, from: data)
        XCTAssertEqual(decoded.value, 200)
    }

    // Test in unkeyed container
    func testDecodeUIntAsInt64InUnkeyedContainer() throws {
        let encoder = BONJSONEncoder()
        let decoder = BONJSONDecoder()

        // Encode array of UInt64
        let original: [UInt64] = [100, 200, 300]
        let data = try encoder.encode(original)

        // Decode as Int64 array
        let decoded = try decoder.decode([Int64].self, from: data)
        XCTAssertEqual(decoded, [100, 200, 300])
    }

    // Test in single value container - needs MSB set to use UINT encoding
    func testDecodeUIntAsInt64SingleValue() throws {
        let encoder = BONJSONEncoder()
        let decoder = BONJSONDecoder()

        // 200 has MSB set in 1 byte, so it's encoded as UINT
        let original: UInt64 = 200
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(Int64.self, from: data)
        XCTAssertEqual(decoded, 200)
    }

    // Test decoding Int as UInt (for the reverse conversion path)
    func testDecodeIntAsUInt64() throws {
        let encoder = BONJSONEncoder()
        let decoder = BONJSONDecoder()

        struct IntHolder: Encodable {
            var value: Int64
        }

        struct UIntHolder: Decodable {
            var value: UInt64
        }

        // Small positive int (encoded as small int or signed int)
        let original = IntHolder(value: 50)
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(UIntHolder.self, from: data)
        XCTAssertEqual(decoded.value, 50)
    }

    // Test decoding Int as UInt in single value container
    func testDecodeIntAsUInt64SingleValue() throws {
        let encoder = BONJSONEncoder()
        let decoder = BONJSONDecoder()

        let original: Int64 = 50
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(UInt64.self, from: data)
        XCTAssertEqual(decoded, 50)
    }

    // Test decoding UInt as Double (covers UINT case in decodeDouble)
    func testDecodeUIntAsDouble() throws {
        let encoder = BONJSONEncoder()
        let decoder = BONJSONDecoder()

        struct UIntHolder: Encodable {
            var value: UInt64
        }

        struct DoubleHolder: Decodable {
            var value: Double
        }

        // 200 is encoded as UINT
        let original = UIntHolder(value: 200)
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(DoubleHolder.self, from: data)
        XCTAssertEqual(decoded.value, 200.0)
    }

    // Test decoding UInt as Double in single value container
    func testDecodeUIntAsDoubleSingleValue() throws {
        let encoder = BONJSONEncoder()
        let decoder = BONJSONDecoder()

        let original: UInt64 = 200
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(Double.self, from: data)
        XCTAssertEqual(decoded, 200.0)
    }
}

// MARK: - Large Object SuperDecoder Tests

final class BONJSONLargeObjectSuperDecoderTests: XCTestCase {

    // Test superDecoder with large object (> 12 fields) to trigger dictionary cache
    func testSuperDecoderWithLargeObject() throws {
        struct Parent: Codable, Equatable {
            var parentA: Int, parentB: Int, parentC: Int, parentD: Int, parentE: Int
            var parentF: Int, parentG: Int, parentH: Int, parentI: Int, parentJ: Int
            var parentK: Int, parentL: Int, parentM: Int
        }

        struct Child: Codable, Equatable {
            var childValue: String
            var parent: Parent

            enum CodingKeys: String, CodingKey {
                case childValue
                case `super`
            }

            init(childValue: String, parent: Parent) {
                self.childValue = childValue
                self.parent = parent
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                childValue = try container.decode(String.self, forKey: .childValue)
                let superDecoder = try container.superDecoder()
                parent = try Parent(from: superDecoder)
            }

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(childValue, forKey: .childValue)
                let superEncoder = container.superEncoder()
                try parent.encode(to: superEncoder)
            }
        }

        let encoder = BONJSONEncoder()
        let decoder = BONJSONDecoder()

        let parent = Parent(parentA: 1, parentB: 2, parentC: 3, parentD: 4, parentE: 5,
                           parentF: 6, parentG: 7, parentH: 8, parentI: 9, parentJ: 10,
                           parentK: 11, parentL: 12, parentM: 13)
        let value = Child(childValue: "test", parent: parent)
        let data = try encoder.encode(value)
        let decoded = try decoder.decode(Child.self, from: data)
        XCTAssertEqual(decoded, value)
    }

    // Test superDecoder where the CHILD object has >12 fields (triggers dictionary cache in valueIndexForString)
    func testSuperDecoderWithLargeChildObject() throws {
        struct Parent: Codable, Equatable {
            var parentValue: Int
        }

        struct LargeChild: Codable, Equatable {
            // 13+ fields in the child to trigger dictionary cache
            var a: Int, b: Int, c: Int, d: Int, e: Int
            var f: Int, g: Int, h: Int, i: Int, j: Int
            var k: Int, l: Int, m: Int
            var parent: Parent

            enum CodingKeys: String, CodingKey {
                case a, b, c, d, e, f, g, h, i, j, k, l, m
                case `super`
            }

            init(a: Int, b: Int, c: Int, d: Int, e: Int, f: Int, g: Int, h: Int, i: Int, j: Int, k: Int, l: Int, m: Int, parent: Parent) {
                self.a = a; self.b = b; self.c = c; self.d = d; self.e = e
                self.f = f; self.g = g; self.h = h; self.i = i; self.j = j
                self.k = k; self.l = l; self.m = m; self.parent = parent
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                a = try container.decode(Int.self, forKey: .a)
                b = try container.decode(Int.self, forKey: .b)
                c = try container.decode(Int.self, forKey: .c)
                d = try container.decode(Int.self, forKey: .d)
                e = try container.decode(Int.self, forKey: .e)
                f = try container.decode(Int.self, forKey: .f)
                g = try container.decode(Int.self, forKey: .g)
                h = try container.decode(Int.self, forKey: .h)
                i = try container.decode(Int.self, forKey: .i)
                j = try container.decode(Int.self, forKey: .j)
                k = try container.decode(Int.self, forKey: .k)
                l = try container.decode(Int.self, forKey: .l)
                m = try container.decode(Int.self, forKey: .m)
                // superDecoder on an object with >12 fields triggers dictionary cache path
                let superDecoder = try container.superDecoder()
                parent = try Parent(from: superDecoder)
            }

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(a, forKey: .a)
                try container.encode(b, forKey: .b)
                try container.encode(c, forKey: .c)
                try container.encode(d, forKey: .d)
                try container.encode(e, forKey: .e)
                try container.encode(f, forKey: .f)
                try container.encode(g, forKey: .g)
                try container.encode(h, forKey: .h)
                try container.encode(i, forKey: .i)
                try container.encode(j, forKey: .j)
                try container.encode(k, forKey: .k)
                try container.encode(l, forKey: .l)
                try container.encode(m, forKey: .m)
                let superEncoder = container.superEncoder()
                try parent.encode(to: superEncoder)
            }
        }

        let encoder = BONJSONEncoder()
        let decoder = BONJSONDecoder()

        let parent = Parent(parentValue: 999)
        let value = LargeChild(a: 1, b: 2, c: 3, d: 4, e: 5, f: 6, g: 7, h: 8, i: 9, j: 10, k: 11, l: 12, m: 13, parent: parent)
        let data = try encoder.encode(value)
        let decoded = try decoder.decode(LargeChild.self, from: data)
        XCTAssertEqual(decoded, value)
    }
}

// MARK: - Large Object Dictionary Cache Tests

final class BONJSONLargeObjectDictionaryCacheTests: XCTestCase {

    // Test dictionary cache lookup for large objects (>12 fields) with non-sequential access
    func testDictionaryCacheWithNonSequentialAccess() throws {
        // A struct with >12 fields where we access a late field first to trigger dictionary cache
        struct LargeObject: Codable, Equatable {
            var a: Int, b: Int, c: Int, d: Int, e: Int
            var f: Int, g: Int, h: Int, i: Int, j: Int
            var k: Int, l: Int, m: Int, n: Int, o: Int
        }

        struct LargeObjectKey: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { nil }
        }

        // Custom decoder that accesses fields in reverse order (triggers dictionary cache)
        struct LargeObjectDecoder: Decodable {
            var value: LargeObject

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: LargeObjectKey.self)
                // Access fields in reverse order to trigger dictionary cache
                let o = try container.decode(Int.self, forKey: LargeObjectKey(stringValue: "o"))
                let n = try container.decode(Int.self, forKey: LargeObjectKey(stringValue: "n"))
                let m = try container.decode(Int.self, forKey: LargeObjectKey(stringValue: "m"))
                let l = try container.decode(Int.self, forKey: LargeObjectKey(stringValue: "l"))
                let k = try container.decode(Int.self, forKey: LargeObjectKey(stringValue: "k"))
                let j = try container.decode(Int.self, forKey: LargeObjectKey(stringValue: "j"))
                let i = try container.decode(Int.self, forKey: LargeObjectKey(stringValue: "i"))
                let h = try container.decode(Int.self, forKey: LargeObjectKey(stringValue: "h"))
                let g = try container.decode(Int.self, forKey: LargeObjectKey(stringValue: "g"))
                let f = try container.decode(Int.self, forKey: LargeObjectKey(stringValue: "f"))
                let e = try container.decode(Int.self, forKey: LargeObjectKey(stringValue: "e"))
                let d = try container.decode(Int.self, forKey: LargeObjectKey(stringValue: "d"))
                let c = try container.decode(Int.self, forKey: LargeObjectKey(stringValue: "c"))
                let b = try container.decode(Int.self, forKey: LargeObjectKey(stringValue: "b"))
                let a = try container.decode(Int.self, forKey: LargeObjectKey(stringValue: "a"))
                value = LargeObject(a: a, b: b, c: c, d: d, e: e, f: f, g: g, h: h, i: i, j: j, k: k, l: l, m: m, n: n, o: o)
            }
        }

        let encoder = BONJSONEncoder()
        let decoder = BONJSONDecoder()

        let original = LargeObject(a: 1, b: 2, c: 3, d: 4, e: 5, f: 6, g: 7, h: 8, i: 9, j: 10, k: 11, l: 12, m: 13, n: 14, o: 15)
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(LargeObjectDecoder.self, from: data)
        XCTAssertEqual(decoded.value, original)
    }
}

// MARK: - Unkeyed Container Manual Iteration Tests

final class BONJSONUnkeyedManualIterationTests: XCTestCase {

    // Test UINT to Int64 conversion in unkeyed container via manual iteration (not batch)
    func testUIntToInt64ManualIteration() throws {
        // Custom decoder that manually iterates through array elements
        struct ManualArrayDecoder: Decodable {
            var values: [Int64]

            init(from decoder: Decoder) throws {
                var container = try decoder.unkeyedContainer()
                var result: [Int64] = []
                while !container.isAtEnd {
                    // This uses decodeInt64Value() which handles UINT to Int64 conversion
                    let value = try container.decode(Int64.self)
                    result.append(value)
                }
                values = result
            }
        }

        let encoder = BONJSONEncoder()
        let decoder = BONJSONDecoder()

        // Encode UInt64 values (200 has MSB set, so it's encoded as UINT)
        let original: [UInt64] = [200, 250, 255]
        let data = try encoder.encode(original)

        // Decode using manual iteration
        let decoded = try decoder.decode(ManualArrayDecoder.self, from: data)
        XCTAssertEqual(decoded.values, [200, 250, 255])
    }

    // Test Double decoding in unkeyed container with UINT value
    func testUIntToDoubleManualIteration() throws {
        struct ManualDoubleArrayDecoder: Decodable {
            var values: [Double]

            init(from decoder: Decoder) throws {
                var container = try decoder.unkeyedContainer()
                var result: [Double] = []
                while !container.isAtEnd {
                    let value = try container.decode(Double.self)
                    result.append(value)
                }
                values = result
            }
        }

        let encoder = BONJSONEncoder()
        let decoder = BONJSONDecoder()

        // Encode UInt64 values
        let original: [UInt64] = [200, 250]
        let data = try encoder.encode(original)

        let decoded = try decoder.decode(ManualDoubleArrayDecoder.self, from: data)
        XCTAssertEqual(decoded.values, [200.0, 250.0])
    }
}

// MARK: - URL Single Value Container Tests

final class BONJSONURLSingleValueTests: XCTestCase {

    // Test URL decoding in single value container
    func testURLInSingleValueContainer() throws {
        // Wrapper that decodes URL via single value container
        struct URLWrapper: Decodable {
            var url: URL

            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                // This triggers the URL path in single value container's decode<T>
                url = try container.decode(URL.self)
            }
        }

        let encoder = BONJSONEncoder()
        let decoder = BONJSONDecoder()

        // Encode a URL
        let original = URL(string: "https://example.com/path")!
        let data = try encoder.encode(original)

        // Decode via wrapper to hit single value container path
        let decoded = try decoder.decode(URLWrapper.self, from: data)
        XCTAssertEqual(decoded.url, original)
    }
}

// MARK: - Type Mismatch Error Tests (covers describeType)

final class BONJSONTypeMismatchTests: XCTestCase {

    // Test type mismatch error in keyed container (covers describeType at line 1156)
    func testTypeMismatchInKeyedContainer() throws {
        struct StringHolder: Encodable {
            var value: String
        }

        struct IntHolder: Decodable {
            var value: Int
        }

        let encoder = BONJSONEncoder()
        let decoder = BONJSONDecoder()

        let original = StringHolder(value: "not an int")
        let data = try encoder.encode(original)

        XCTAssertThrowsError(try decoder.decode(IntHolder.self, from: data))
    }

    // Test type mismatch error in unkeyed container (covers describeType at line 1410)
    func testTypeMismatchInUnkeyedContainer() throws {
        struct ManualDecoder: Decodable {
            init(from decoder: Decoder) throws {
                var container = try decoder.unkeyedContainer()
                // Try to decode string as int
                _ = try container.decode(Int.self)
            }
        }

        let encoder = BONJSONEncoder()
        let decoder = BONJSONDecoder()

        let original = ["not", "ints"]
        let data = try encoder.encode(original)

        XCTAssertThrowsError(try decoder.decode(ManualDecoder.self, from: data))
    }
}

// MARK: - Big Number Decoding Tests

final class BONJSONBigNumberTests: XCTestCase {

    // Test big number decoding as Double in keyed container
    func testBigNumberAsDoubleInKeyedContainer() throws {
        // Create raw BONJSON: { "value": <big number 12345> }
        // Object start (0xf9) + chunk header (1 pair = 0x04) + key "value" + big number
        //
        // Big number format: TYPE_BIG_NUMBER (0xf1) + header + significand
        // Header: SSSSS EE N where SSSSS=significand length, EE=exponent length, N=sign
        // For 12345: significand=12345 (2 bytes), exponent=0 (0 bytes), sign=positive
        // Header = (2 << 3) | (0 << 1) | 0 = 0x10
        // Significand: 12345 = 0x3039 in little-endian = [0x39, 0x30]

        let bonjsonData = Data([
            0xf9,                           // Object start
            0x04,                           // Chunk header: 1 pair, length field encoded
            0xe5, 0x76, 0x61, 0x6c, 0x75, 0x65, // Key "value" (short string, 5 bytes: 0xe0 + 5)
            0xf1,                           // Big number type
            0x10,                           // Header: 2 bytes significand, 0 bytes exponent, positive
            0x39, 0x30                      // Significand: 12345 little-endian
        ])

        struct DoubleHolder: Decodable {
            var value: Double
        }

        let decoder = BONJSONDecoder()
        let decoded = try decoder.decode(DoubleHolder.self, from: bonjsonData)
        XCTAssertEqual(decoded.value, 12345.0)
    }

    // Test big number decoding as Double in unkeyed container
    func testBigNumberAsDoubleInUnkeyedContainer() throws {
        // Create raw BONJSON: [<big number 12345>]
        // Array start (0xf8) + chunk header (1 element = 0x04) + big number
        let bonjsonData = Data([
            0xf8,                           // Array start
            0x04,                           // Chunk header: 1 element, length field encoded
            0xf1,                           // Big number type
            0x10,                           // Header: 2 bytes significand, 0 bytes exponent, positive
            0x39, 0x30                      // Significand: 12345 little-endian
        ])

        struct ManualDecoder: Decodable {
            var value: Double

            init(from decoder: Decoder) throws {
                var container = try decoder.unkeyedContainer()
                value = try container.decode(Double.self)
            }
        }

        let decoder = BONJSONDecoder()
        let decoded = try decoder.decode(ManualDecoder.self, from: bonjsonData)
        XCTAssertEqual(decoded.value, 12345.0)
    }

    // Test big number decoding as Double in single value container
    func testBigNumberAsDoubleInSingleValueContainer() throws {
        // Create raw BONJSON: <big number 12345>
        let bonjsonData = Data([
            0xf1,                           // Big number type
            0x10,                           // Header: 2 bytes significand, 0 bytes exponent, positive
            0x39, 0x30                      // Significand: 12345 little-endian
        ])

        let decoder = BONJSONDecoder()
        let decoded = try decoder.decode(Double.self, from: bonjsonData)
        XCTAssertEqual(decoded, 12345.0)
    }

    // Test big number with negative sign
    func testNegativeBigNumber() throws {
        // Big number -12345: same as above but with sign bit set
        // Header = (2 << 3) | (0 << 1) | 1 = 0x11
        let bonjsonData = Data([
            0xf1,                           // Big number type
            0x11,                           // Header: 2 bytes significand, 0 bytes exponent, negative
            0x39, 0x30                      // Significand: 12345 little-endian
        ])

        let decoder = BONJSONDecoder()
        let decoded = try decoder.decode(Double.self, from: bonjsonData)
        XCTAssertEqual(decoded, -12345.0)
    }

    // Test big number with exponent (e.g., 123.45 = 12345 * 10^-2)
    func testBigNumberWithExponent() throws {
        // Big number 123.45 = 12345 * 10^-2
        // Header: significand=2 bytes, exponent=1 byte, positive
        // Header = (2 << 3) | (1 << 1) | 0 = 0x12
        // Exponent: -2 as signed byte = 0xFE
        let bonjsonData = Data([
            0xf1,                           // Big number type
            0x12,                           // Header: 2 bytes significand, 1 byte exponent, positive
            0xFE,                           // Exponent: -2 (signed)
            0x39, 0x30                      // Significand: 12345 little-endian
        ])

        let decoder = BONJSONDecoder()
        let decoded = try decoder.decode(Double.self, from: bonjsonData)
        XCTAssertEqual(decoded, 123.45, accuracy: 0.001)
    }

    // Test big number as Date (goes through _MapDecoder.decodeDouble via decodeDate)
    func testBigNumberAsDate() throws {
        // Big number representing timestamp 1000000 seconds since 1970
        // Header: significand needs 3 bytes for 1000000 = 0x0F4240
        // Header = (3 << 3) | (0 << 1) | 0 = 0x18
        let bonjsonData = Data([
            0xf1,                           // Big number type
            0x18,                           // Header: 3 bytes significand, 0 bytes exponent, positive
            0x40, 0x42, 0x0F                // Significand: 1000000 little-endian
        ])

        let decoder = BONJSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let decoded = try decoder.decode(Date.self, from: bonjsonData)
        XCTAssertEqual(decoded.timeIntervalSince1970, 1000000.0)
    }
}

// MARK: - Security Tests

final class BONJSONSecurityTests: XCTestCase {

    // MARK: - NUL Character Tests (Decoder)

    func testDecoderRejectsNULByDefault() throws {
        // String "a\0b" with NUL character
        let bonjsonData = Data([
            0xe3,                           // Short string, length 3
            0x61, 0x00, 0x62                // "a\0b"
        ])

        let decoder = BONJSONDecoder()
        XCTAssertThrowsError(try decoder.decode(String.self, from: bonjsonData)) { error in
            XCTAssertTrue(error is BONJSONDecodingError)
            if case BONJSONDecodingError.nulCharacterInString = error {
                // Expected
            } else {
                XCTFail("Expected nulCharacterInString error, got \(error)")
            }
        }
    }

    func testDecoderAllowsNULWhenConfigured() throws {
        // String "a\0b" with NUL character
        let bonjsonData = Data([
            0xe3,                           // Short string, length 3
            0x61, 0x00, 0x62                // "a\0b"
        ])

        let decoder = BONJSONDecoder()
        decoder.nulDecodingStrategy = .allow
        let decoded = try decoder.decode(String.self, from: bonjsonData)
        XCTAssertEqual(decoded, "a\0b")
    }

    // MARK: - NUL Character Tests (Encoder)

    func testEncoderRejectsNULByDefault() throws {
        let encoder = BONJSONEncoder()
        let stringWithNUL = "a\0b"
        XCTAssertThrowsError(try encoder.encode(stringWithNUL)) { error in
            XCTAssertTrue(error is BONJSONEncodingError)
            if case BONJSONEncodingError.nulCharacterInString = error {
                // Expected
            } else {
                XCTFail("Expected nulCharacterInString error, got \(error)")
            }
        }
    }

    func testEncoderAllowsNULWhenConfigured() throws {
        let encoder = BONJSONEncoder()
        encoder.nulEncodingStrategy = .allow
        let stringWithNUL = "a\0b"
        let data = try encoder.encode(stringWithNUL)
        XCTAssertNotNil(data)

        // Verify round-trip
        let decoder = BONJSONDecoder()
        decoder.nulDecodingStrategy = .allow
        let decoded = try decoder.decode(String.self, from: data)
        XCTAssertEqual(decoded, stringWithNUL)
    }

    // MARK: - Invalid UTF-8 Tests

    func testDecoderRejectsInvalidUTF8ByDefault() throws {
        // String with invalid UTF-8: 0x80 is a continuation byte without a leading byte
        let bonjsonData = Data([
            0xe3,                           // Short string, length 3
            0x61, 0x80, 0x62                // "a" + invalid + "b"
        ])

        let decoder = BONJSONDecoder()
        XCTAssertThrowsError(try decoder.decode(String.self, from: bonjsonData)) { error in
            XCTAssertTrue(error is BONJSONDecodingError)
            if case BONJSONDecodingError.invalidUTF8Sequence = error {
                // Expected
            } else {
                XCTFail("Expected invalidUTF8Sequence error, got \(error)")
            }
        }
    }

    func testDecoderRejectsSurrogates() throws {
        // Surrogate encoded as UTF-8: U+D800 = 0xED 0xA0 0x80
        let bonjsonData = Data([
            0xe3,                           // Short string, length 3
            0xED, 0xA0, 0x80                // Invalid: surrogate U+D800
        ])

        let decoder = BONJSONDecoder()
        XCTAssertThrowsError(try decoder.decode(String.self, from: bonjsonData)) { error in
            if case BONJSONDecodingError.invalidUTF8Sequence = error {
                // Expected
            } else {
                XCTFail("Expected invalidUTF8Sequence error, got \(error)")
            }
        }
    }

    func testDecoderRejectsOverlongEncoding() throws {
        // Overlong encoding of 'a' (0x61): 0xC1 0xA1 instead of just 0x61
        let bonjsonData = Data([
            0xe2,                           // Short string, length 2 (0xe0 + 2)
            0xC1, 0xA1                      // Invalid: overlong encoding
        ])

        let decoder = BONJSONDecoder()
        XCTAssertThrowsError(try decoder.decode(String.self, from: bonjsonData)) { error in
            if case BONJSONDecodingError.invalidUTF8Sequence = error {
                // Expected
            } else {
                XCTFail("Expected invalidUTF8Sequence error, got \(error)")
            }
        }
    }

    func testDecoderReplacesInvalidUTF8WhenConfigured() throws {
        // String with invalid UTF-8: 0x80 is a continuation byte without a leading byte
        let bonjsonData = Data([
            0xe3,                           // Short string, length 3
            0x61, 0x80, 0x62                // "a" + invalid + "b"
        ])

        let decoder = BONJSONDecoder()
        decoder.unicodeDecodingStrategy = .replace
        let decoded = try decoder.decode(String.self, from: bonjsonData)
        // Invalid byte 0x80 should be replaced with U+FFFD
        XCTAssertEqual(decoded, "a\u{FFFD}b")
    }

    func testDecoderDeletesInvalidUTF8WhenConfigured() throws {
        // String with invalid UTF-8: 0x80 is a continuation byte without a leading byte
        let bonjsonData = Data([
            0xe3,                           // Short string, length 3
            0x61, 0x80, 0x62                // "a" + invalid + "b"
        ])

        let decoder = BONJSONDecoder()
        decoder.unicodeDecodingStrategy = .delete
        let decoded = try decoder.decode(String.self, from: bonjsonData)
        // Invalid byte 0x80 should be deleted
        XCTAssertEqual(decoded, "ab")
    }

    // MARK: - Duplicate Key Tests

    func testDecoderRejectsDuplicateKeysByDefault() throws {
        // Object with duplicate "a" key: {"a": 1, "a": 2}
        // Chunked format: object start + chunk header (2 pairs) + key-value pairs
        let bonjsonData = Data([
            0xf9,                           // Object start
            0x08,                           // Chunk header: 2 pairs, length field encoded
            0xe1, 0x61,                     // Key "a" (short string length 1: 0xe0 + 1)
            0x65,                           // Value 1 (small int: 1 + 100 = 101)
            0xe1, 0x61,                     // Key "a" again
            0x66                            // Value 2 (small int: 2 + 100 = 102)
        ])

        let decoder = BONJSONDecoder()
        XCTAssertThrowsError(try decoder.decode([String: Int].self, from: bonjsonData)) { error in
            if case BONJSONDecodingError.duplicateObjectKey = error {
                // Expected
            } else {
                XCTFail("Expected duplicateObjectKey error, got \(error)")
            }
        }
    }

    func testDecoderKeepsFirstDuplicateKeyWhenConfigured() throws {
        // Object with duplicate "a" key: {"a": 1, "a": 2}
        // Chunked format: object start + chunk header (2 pairs) + key-value pairs
        let bonjsonData = Data([
            0xf9,                           // Object start
            0x08,                           // Chunk header: 2 pairs, length field encoded
            0xe1, 0x61,                     // Key "a" (short string length 1: 0xe0 + 1)
            0x65,                           // Value 1 (small int: 1 + 100 = 101)
            0xe1, 0x61,                     // Key "a" again
            0x66                            // Value 2 (small int: 2 + 100 = 102)
        ])

        let decoder = BONJSONDecoder()
        decoder.duplicateKeyDecodingStrategy = .keepFirst
        let decoded = try decoder.decode([String: Int].self, from: bonjsonData)
        XCTAssertEqual(decoded["a"], 1) // First value kept
    }

    func testDecoderKeepsLastDuplicateKeyWhenConfigured() throws {
        // Object with duplicate "a" key: {"a": 1, "a": 2}
        // Chunked format: object start + chunk header (2 pairs) + key-value pairs
        let bonjsonData = Data([
            0xf9,                           // Object start
            0x08,                           // Chunk header: 2 pairs, length field encoded
            0xe1, 0x61,                     // Key "a" (short string length 1: 0xe0 + 1)
            0x65,                           // Value 1 (small int: 1 + 100 = 101)
            0xe1, 0x61,                     // Key "a" again
            0x66                            // Value 2 (small int: 2 + 100 = 102)
        ])

        let decoder = BONJSONDecoder()
        decoder.duplicateKeyDecodingStrategy = .keepLast
        let decoded = try decoder.decode([String: Int].self, from: bonjsonData)
        XCTAssertEqual(decoded["a"], 2) // Last value kept
    }

    // MARK: - Valid UTF-8 Tests (ensure normal strings still work)

    func testValidUTF8WorksWithAllStrategies() throws {
        let validString = "Hello, 世界! 🌍"
        let encoder = BONJSONEncoder()
        let data = try encoder.encode(validString)

        // Test with reject (default)
        let decoder1 = BONJSONDecoder()
        let decoded1 = try decoder1.decode(String.self, from: data)
        XCTAssertEqual(decoded1, validString)

        // Test with replace
        let decoder2 = BONJSONDecoder()
        decoder2.unicodeDecodingStrategy = .replace
        let decoded2 = try decoder2.decode(String.self, from: data)
        XCTAssertEqual(decoded2, validString)

        // Test with delete
        let decoder3 = BONJSONDecoder()
        decoder3.unicodeDecodingStrategy = .delete
        let decoded3 = try decoder3.decode(String.self, from: data)
        XCTAssertEqual(decoded3, validString)
    }

    // MARK: - Too Many Keys Tests

    func testDecoderRejectsTooManyKeysWhenDuplicateCheckEnabled() throws {
        // Build an object with more than 256 keys using encoder, then test decoding
        var dict: [String: Int] = [:]
        for i in 0..<257 {
            dict["key\(i)"] = i
        }

        let encoder = BONJSONEncoder()
        let bonjsonData = try encoder.encode(dict)

        // Default duplicate detection should fail with too many keys
        let decoder = BONJSONDecoder()
        XCTAssertThrowsError(try decoder.decode([String: Int].self, from: bonjsonData)) { error in
            guard case BONJSONDecodingError.tooManyKeys = error else {
                XCTFail("Expected tooManyKeys error, got \(error)")
                return
            }
        }
    }

    func testDecoderAllowsManyKeysWhenDuplicateCheckDisabled() throws {
        // Build an object with more than 256 keys using encoder, then test decoding
        var dict: [String: Int] = [:]
        for i in 0..<300 {
            dict["key\(i)"] = i
        }

        let encoder = BONJSONEncoder()
        let bonjsonData = try encoder.encode(dict)

        // With keepFirst, duplicate checking is disabled so many keys should work
        let decoder = BONJSONDecoder()
        decoder.duplicateKeyDecodingStrategy = .keepFirst
        let decoded = try decoder.decode([String: Int].self, from: bonjsonData)
        XCTAssertEqual(decoded.count, 300)
    }
}
