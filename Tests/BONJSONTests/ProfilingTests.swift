// ABOUTME: Detailed profiling tests to identify performance bottlenecks.
// ABOUTME: Breaks down decode/encode time by phase and component.

import XCTest
import Foundation
@testable import BONJSON
import CKSBonjson

final class ProfilingTests: XCTestCase {

    // MARK: - Test Data

    struct SimpleObject: Codable {
        var a: Int
        var b: Int
        var c: Int
        var d: Int
        var e: Int
    }

    struct StringObject: Codable {
        var name: String
        var value: String
        var description: String
    }

    // MARK: - Timing Helpers

    @inline(never)
    func measureNs(_ block: () throws -> Void) rethrows -> UInt64 {
        let start = DispatchTime.now().uptimeNanoseconds
        try block()
        return DispatchTime.now().uptimeNanoseconds - start
    }

    func formatNs(_ ns: UInt64) -> String {
        if ns >= 1_000_000 {
            return String(format: "%.2f ms", Double(ns) / 1_000_000)
        } else if ns >= 1_000 {
            return String(format: "%.2f us", Double(ns) / 1_000)
        } else {
            return "\(ns) ns"
        }
    }

    // MARK: - Decode Phase Breakdown

    func testDecodePhaseBreakdown() throws {
        // Create test data: 1000 simple objects
        let objects = (0..<1000).map { i in
            SimpleObject(a: i, b: i*2, c: i*3, d: i*4, e: i*5)
        }
        let data = try BONJSONEncoder().encode(objects)

        let iterations = 100
        var positionMapTimes: [UInt64] = []
        var totalTimes: [UInt64] = []

        // Warm up
        _ = try BONJSONDecoder().decode([SimpleObject].self, from: data)

        for _ in 0..<iterations {
            // Measure total decode time
            let totalStart = DispatchTime.now().uptimeNanoseconds

            // Can't easily separate phases without modifying decoder,
            // so measure total time
            _ = try BONJSONDecoder().decode([SimpleObject].self, from: data)

            let totalEnd = DispatchTime.now().uptimeNanoseconds
            totalTimes.append(totalEnd - totalStart)
        }

        // Also measure just position map creation
        for _ in 0..<iterations {
            let mapStart = DispatchTime.now().uptimeNanoseconds
            _ = try _PositionMap(data: data)
            let mapEnd = DispatchTime.now().uptimeNanoseconds
            positionMapTimes.append(mapEnd - mapStart)
        }

        let avgTotal = totalTimes.reduce(0, +) / UInt64(iterations)
        let avgMap = positionMapTimes.reduce(0, +) / UInt64(iterations)
        let avgDecode = avgTotal - avgMap

        print("""

        === Decode Phase Breakdown (1000 SimpleObjects, \(data.count) bytes) ===
        Position Map Creation: \(formatNs(avgMap)) (\(String(format: "%.1f", Double(avgMap) / Double(avgTotal) * 100))%)
        Codable Decoding:      \(formatNs(avgDecode)) (\(String(format: "%.1f", Double(avgDecode) / Double(avgTotal) * 100))%)
        Total:                 \(formatNs(avgTotal))

        Per object: \(formatNs(avgTotal / 1000))
        Per field:  \(formatNs(avgTotal / 5000))
        Throughput: \(String(format: "%.2f", Double(data.count) / Double(avgTotal) * 1000)) MB/s
        """)
    }

    func testPositionMapScalingWithSize() throws {
        print("\n=== Position Map Scaling ===")
        print("Count\tBytes\tMap Time\tPer Entry\tThroughput")

        for count in [100, 500, 1000, 2000, 5000] {
            let objects = (0..<count).map { i in
                SimpleObject(a: i, b: i*2, c: i*3, d: i*4, e: i*5)
            }
            let data = try BONJSONEncoder().encode(objects)

            // Warm up
            _ = try _PositionMap(data: data)

            var times: [UInt64] = []
            for _ in 0..<50 {
                let start = DispatchTime.now().uptimeNanoseconds
                let map = try _PositionMap(data: data)
                let end = DispatchTime.now().uptimeNanoseconds
                times.append(end - start)
                _ = map.entryCount // prevent optimization
            }

            let avgTime = times.reduce(0, +) / UInt64(times.count)
            let entryCount = 1 + count * 6 // array + count*(object + 5 fields)
            let perEntry = avgTime / UInt64(entryCount)
            let throughput = Double(data.count) / Double(avgTime) * 1000 // MB/s

            print("\(count)\t\(data.count)\t\(formatNs(avgTime))\t\(formatNs(perEntry))\t\(String(format: "%.2f MB/s", throughput))")
        }
    }

    func testContainerCreationOverhead() throws {
        // Measure the overhead of creating containers by comparing
        // position map creation vs full decode
        let objects = (0..<1000).map { i in
            SimpleObject(a: i, b: i*2, c: i*3, d: i*4, e: i*5)
        }
        let data = try BONJSONEncoder().encode(objects)

        let iterations = 100

        // Measure position map only
        var mapTimes: [UInt64] = []
        for _ in 0..<iterations {
            let start = DispatchTime.now().uptimeNanoseconds
            _ = try _PositionMap(data: data)
            let end = DispatchTime.now().uptimeNanoseconds
            mapTimes.append(end - start)
        }

        // Measure full decode
        var decodeTimes: [UInt64] = []
        for _ in 0..<iterations {
            let start = DispatchTime.now().uptimeNanoseconds
            _ = try BONJSONDecoder().decode([SimpleObject].self, from: data)
            let end = DispatchTime.now().uptimeNanoseconds
            decodeTimes.append(end - start)
        }

        let avgMap = mapTimes.reduce(0, +) / UInt64(iterations)
        let avgDecode = decodeTimes.reduce(0, +) / UInt64(iterations)
        let containerOverhead = avgDecode - avgMap

        print("""

        === Container/Codable Overhead ===
        Position map creation: \(formatNs(avgMap))
        Full decode:           \(formatNs(avgDecode))
        Container overhead:    \(formatNs(containerOverhead)) (\(String(format: "%.1f", Double(containerOverhead) / Double(avgDecode) * 100))% of total)
        Per object overhead:   \(formatNs(containerOverhead / 1000))
        """)
    }

    func testStringDecodingOverhead() throws {
        // Measure string decoding specifically
        let objects = (0..<1000).map { i in
            StringObject(name: "Name\(i)", value: "Value\(i)", description: "This is a longer description for item \(i)")
        }
        let data = try BONJSONEncoder().encode(objects)

        let iterations = 50
        var times: [UInt64] = []

        // Warm up
        _ = try BONJSONDecoder().decode([StringObject].self, from: data)

        for _ in 0..<iterations {
            let start = DispatchTime.now().uptimeNanoseconds
            _ = try BONJSONDecoder().decode([StringObject].self, from: data)
            let end = DispatchTime.now().uptimeNanoseconds
            times.append(end - start)
        }

        let avgTime = times.reduce(0, +) / UInt64(iterations)
        print("""

        === String Decoding (1000 objects, 3 strings each) ===
        Total time: \(formatNs(avgTime))
        Per object: \(formatNs(avgTime / 1000))
        Per string: \(formatNs(avgTime / 3000))
        Data size:  \(data.count) bytes
        Throughput: \(String(format: "%.2f", Double(data.count) / Double(avgTime) * 1000)) MB/s
        """)
    }

    func testEncoderBreakdown() throws {
        let objects = (0..<1000).map { i in
            SimpleObject(a: i, b: i*2, c: i*3, d: i*4, e: i*5)
        }

        let iterations = 100
        var times: [UInt64] = []

        let encoder = BONJSONEncoder()

        // Warm up
        _ = try encoder.encode(objects)

        for _ in 0..<iterations {
            let start = DispatchTime.now().uptimeNanoseconds
            _ = try encoder.encode(objects)
            let end = DispatchTime.now().uptimeNanoseconds
            times.append(end - start)
        }

        let avgTime = times.reduce(0, +) / UInt64(iterations)
        let data = try encoder.encode(objects)

        print("""

        === Encoder Breakdown (1000 SimpleObjects) ===
        Total time: \(formatNs(avgTime))
        Per object: \(formatNs(avgTime / 1000))
        Per value:  \(formatNs(avgTime / 5000))
        Data size:  \(data.count) bytes
        Throughput: \(String(format: "%.2f", Double(data.count) / Double(avgTime) * 1000)) MB/s
        """)
    }

    func testPrimitiveArrayPerformance() throws {
        // Test encoding/decoding of primitive arrays
        let intArray = Array(0..<10000)
        let doubleArray = (0..<10000).map { Double($0) * 0.123 }
        let stringArray = (0..<1000).map { "String number \($0)" }

        print("\n=== Primitive Array Performance ===")

        // Integers
        let intData = try BONJSONEncoder().encode(intArray)
        var intTimes: [UInt64] = []
        _ = try BONJSONDecoder().decode([Int].self, from: intData)
        for _ in 0..<50 {
            let start = DispatchTime.now().uptimeNanoseconds
            _ = try BONJSONDecoder().decode([Int].self, from: intData)
            let end = DispatchTime.now().uptimeNanoseconds
            intTimes.append(end - start)
        }
        let avgIntTime = intTimes.reduce(0, +) / UInt64(intTimes.count)
        print("Decode 10000 ints: \(formatNs(avgIntTime)) (\(formatNs(avgIntTime / 10000)) per int)")

        // Doubles
        let doubleData = try BONJSONEncoder().encode(doubleArray)
        var doubleTimes: [UInt64] = []
        _ = try BONJSONDecoder().decode([Double].self, from: doubleData)
        for _ in 0..<50 {
            let start = DispatchTime.now().uptimeNanoseconds
            _ = try BONJSONDecoder().decode([Double].self, from: doubleData)
            let end = DispatchTime.now().uptimeNanoseconds
            doubleTimes.append(end - start)
        }
        let avgDoubleTime = doubleTimes.reduce(0, +) / UInt64(doubleTimes.count)
        print("Decode 10000 doubles: \(formatNs(avgDoubleTime)) (\(formatNs(avgDoubleTime / 10000)) per double)")

        // Strings
        let stringData = try BONJSONEncoder().encode(stringArray)
        var stringTimes: [UInt64] = []
        _ = try BONJSONDecoder().decode([String].self, from: stringData)
        for _ in 0..<50 {
            let start = DispatchTime.now().uptimeNanoseconds
            _ = try BONJSONDecoder().decode([String].self, from: stringData)
            let end = DispatchTime.now().uptimeNanoseconds
            stringTimes.append(end - start)
        }
        let avgStringTime = stringTimes.reduce(0, +) / UInt64(stringTimes.count)
        print("Decode 1000 strings: \(formatNs(avgStringTime)) (\(formatNs(avgStringTime / 1000)) per string)")
    }

    func testDictionaryKeyLookupOverhead() throws {
        // Measure the overhead of dictionary lookups by comparing
        // decoding with few vs many fields
        struct SmallStruct: Codable {
            var x: Int
        }

        struct LargeStruct: Codable {
            var a: Int, b: Int, c: Int, d: Int, e: Int
            var f: Int, g: Int, h: Int, i: Int, j: Int
        }

        let smallObjects = (0..<1000).map { SmallStruct(x: $0) }
        let largeObjects = (0..<1000).map { i in
            LargeStruct(a: i, b: i, c: i, d: i, e: i, f: i, g: i, h: i, i: i, j: i)
        }

        let smallData = try BONJSONEncoder().encode(smallObjects)
        let largeData = try BONJSONEncoder().encode(largeObjects)

        let iterations = 100

        // Small objects
        var smallTimes: [UInt64] = []
        _ = try BONJSONDecoder().decode([SmallStruct].self, from: smallData)
        for _ in 0..<iterations {
            let start = DispatchTime.now().uptimeNanoseconds
            _ = try BONJSONDecoder().decode([SmallStruct].self, from: smallData)
            let end = DispatchTime.now().uptimeNanoseconds
            smallTimes.append(end - start)
        }

        // Large objects
        var largeTimes: [UInt64] = []
        _ = try BONJSONDecoder().decode([LargeStruct].self, from: largeData)
        for _ in 0..<iterations {
            let start = DispatchTime.now().uptimeNanoseconds
            _ = try BONJSONDecoder().decode([LargeStruct].self, from: largeData)
            let end = DispatchTime.now().uptimeNanoseconds
            largeTimes.append(end - start)
        }

        let avgSmall = smallTimes.reduce(0, +) / UInt64(iterations)
        let avgLarge = largeTimes.reduce(0, +) / UInt64(iterations)

        print("""

        === Field Count Impact ===
        1000 objects x 1 field:  \(formatNs(avgSmall)) (\(formatNs(avgSmall / 1000)) per obj, \(formatNs(avgSmall / 1000)) per field)
        1000 objects x 10 fields: \(formatNs(avgLarge)) (\(formatNs(avgLarge / 1000)) per obj, \(formatNs(avgLarge / 10000)) per field)
        Overhead per object: \(formatNs((avgLarge - avgSmall) / 1000))
        Overhead per field:  \(formatNs((avgLarge - avgSmall) / 9000))
        """)
    }

    func testCompareWithJSON() throws {
        let objects = (0..<1000).map { i in
            SimpleObject(a: i, b: i*2, c: i*3, d: i*4, e: i*5)
        }

        let bonjsonData = try BONJSONEncoder().encode(objects)
        let jsonData = try JSONEncoder().encode(objects)

        let iterations = 100

        // BONJSON decode
        var bonjsonTimes: [UInt64] = []
        _ = try BONJSONDecoder().decode([SimpleObject].self, from: bonjsonData)
        for _ in 0..<iterations {
            let start = DispatchTime.now().uptimeNanoseconds
            _ = try BONJSONDecoder().decode([SimpleObject].self, from: bonjsonData)
            let end = DispatchTime.now().uptimeNanoseconds
            bonjsonTimes.append(end - start)
        }

        // JSON decode
        var jsonTimes: [UInt64] = []
        _ = try JSONDecoder().decode([SimpleObject].self, from: jsonData)
        for _ in 0..<iterations {
            let start = DispatchTime.now().uptimeNanoseconds
            _ = try JSONDecoder().decode([SimpleObject].self, from: jsonData)
            let end = DispatchTime.now().uptimeNanoseconds
            jsonTimes.append(end - start)
        }

        let avgBonjson = bonjsonTimes.reduce(0, +) / UInt64(iterations)
        let avgJson = jsonTimes.reduce(0, +) / UInt64(iterations)

        print("""

        === BONJSON vs JSON Comparison (1000 SimpleObjects) ===
        BONJSON: \(formatNs(avgBonjson)) (\(bonjsonData.count) bytes, \(String(format: "%.2f", Double(bonjsonData.count) / Double(avgBonjson) * 1000)) MB/s)
        JSON:    \(formatNs(avgJson)) (\(jsonData.count) bytes, \(String(format: "%.2f", Double(jsonData.count) / Double(avgJson) * 1000)) MB/s)
        Ratio:   \(String(format: "%.2f", Double(avgBonjson) / Double(avgJson)))x (BONJSON/JSON)
        """)
    }

    func testSummary() throws {
        print("""

        ================================================================================
                                    PROFILING SUMMARY
        ================================================================================
        """)

        // Run all the individual tests and collect results
        try testDecodePhaseBreakdown()
        try testPositionMapScalingWithSize()
        try testContainerCreationOverhead()
        try testStringDecodingOverhead()
        try testEncoderBreakdown()
        try testPrimitiveArrayPerformance()
        try testDictionaryKeyLookupOverhead()
        try testCompareWithJSON()
    }

    // MARK: - Detailed Analysis Tests

    func testObjectSizeVsCount() throws {
        // Compare: 1 object with 100 fields vs 100 objects with 1 field
        struct OneField: Codable { var x: Int }
        struct TenFields: Codable {
            var a: Int, b: Int, c: Int, d: Int, e: Int
            var f: Int, g: Int, h: Int, i: Int, j: Int
        }

        let many1Field = (0..<1000).map { OneField(x: $0) }
        let few10Fields = (0..<100).map { i in
            TenFields(a: i, b: i, c: i, d: i, e: i, f: i, g: i, h: i, i: i, j: i)
        }

        let many1FieldData = try BONJSONEncoder().encode(many1Field)
        let few10FieldsData = try BONJSONEncoder().encode(few10Fields)

        let iterations = 100

        // 1000 objects × 1 field
        var many1FieldTimes: [UInt64] = []
        _ = try BONJSONDecoder().decode([OneField].self, from: many1FieldData)
        for _ in 0..<iterations {
            let start = DispatchTime.now().uptimeNanoseconds
            _ = try BONJSONDecoder().decode([OneField].self, from: many1FieldData)
            let end = DispatchTime.now().uptimeNanoseconds
            many1FieldTimes.append(end - start)
        }

        // 100 objects × 10 fields
        var few10FieldsTimes: [UInt64] = []
        _ = try BONJSONDecoder().decode([TenFields].self, from: few10FieldsData)
        for _ in 0..<iterations {
            let start = DispatchTime.now().uptimeNanoseconds
            _ = try BONJSONDecoder().decode([TenFields].self, from: few10FieldsData)
            let end = DispatchTime.now().uptimeNanoseconds
            few10FieldsTimes.append(end - start)
        }

        let avgMany1 = many1FieldTimes.reduce(0, +) / UInt64(iterations)
        let avgFew10 = few10FieldsTimes.reduce(0, +) / UInt64(iterations)

        // Use signed arithmetic to handle case where few10 is slower
        let containerCost = (Int64(avgMany1) - Int64(avgFew10)) / 900

        print("""

        === Object Count vs Field Count (1000 total fields) ===
        1000 objects × 1 field:  \(formatNs(avgMany1)) (\(formatNs(avgMany1 / 1000)) per container)
        100 objects × 10 fields: \(formatNs(avgFew10)) (\(formatNs(avgFew10 / 100)) per container)
        Container creation cost: \(containerCost > 0 ? formatNs(UInt64(containerCost)) : "-\(formatNs(UInt64(-containerCost)))") per container (derived)
        """)
    }

    func testNestedObjectOverhead() throws {
        struct Inner: Codable { var x: Int }
        struct Middle: Codable { var inner: Inner }
        struct Outer: Codable { var middle: Middle }

        let flat = (0..<1000).map { Inner(x: $0) }
        let nested = (0..<1000).map { Outer(middle: Middle(inner: Inner(x: $0))) }

        let flatData = try BONJSONEncoder().encode(flat)
        let nestedData = try BONJSONEncoder().encode(nested)

        let iterations = 100

        // Flat
        var flatTimes: [UInt64] = []
        _ = try BONJSONDecoder().decode([Inner].self, from: flatData)
        for _ in 0..<iterations {
            let start = DispatchTime.now().uptimeNanoseconds
            _ = try BONJSONDecoder().decode([Inner].self, from: flatData)
            let end = DispatchTime.now().uptimeNanoseconds
            flatTimes.append(end - start)
        }

        // Nested (3 levels)
        var nestedTimes: [UInt64] = []
        _ = try BONJSONDecoder().decode([Outer].self, from: nestedData)
        for _ in 0..<iterations {
            let start = DispatchTime.now().uptimeNanoseconds
            _ = try BONJSONDecoder().decode([Outer].self, from: nestedData)
            let end = DispatchTime.now().uptimeNanoseconds
            nestedTimes.append(end - start)
        }

        let avgFlat = flatTimes.reduce(0, +) / UInt64(iterations)
        let avgNested = nestedTimes.reduce(0, +) / UInt64(iterations)

        print("""

        === Nesting Depth Overhead ===
        1000 flat objects (1 level):   \(formatNs(avgFlat)) (\(formatNs(avgFlat / 1000)) per object)
        1000 nested objects (3 levels): \(formatNs(avgNested)) (\(formatNs(avgNested / 1000)) per object)
        Extra cost for 2 nesting levels: \(formatNs((avgNested - avgFlat) / 1000)) per object
        """)
    }

    func testLargeObjectDecoding() throws {
        // Test decoding objects with many fields (triggers dictionary instead of linear search)
        struct SmallObject: Codable {
            var a: Int, b: Int, c: Int, d: Int, e: Int
        }
        struct LargeObject: Codable {
            var a: Int, b: Int, c: Int, d: Int, e: Int
            var f: Int, g: Int, h: Int, i: Int, j: Int
            var k: Int, l: Int, m: Int, n: Int, o: Int
        }

        let smallObjs = (0..<1000).map { i in
            SmallObject(a: i, b: i, c: i, d: i, e: i)
        }
        let largeObjs = (0..<1000).map { i in
            LargeObject(a: i, b: i, c: i, d: i, e: i, f: i, g: i, h: i, i: i, j: i, k: i, l: i, m: i, n: i, o: i)
        }

        let smallData = try BONJSONEncoder().encode(smallObjs)
        let largeData = try BONJSONEncoder().encode(largeObjs)

        let iterations = 100

        // Small (5 fields, uses linear search)
        var smallTimes: [UInt64] = []
        _ = try BONJSONDecoder().decode([SmallObject].self, from: smallData)
        for _ in 0..<iterations {
            let start = DispatchTime.now().uptimeNanoseconds
            _ = try BONJSONDecoder().decode([SmallObject].self, from: smallData)
            let end = DispatchTime.now().uptimeNanoseconds
            smallTimes.append(end - start)
        }

        // Large (15 fields, uses dictionary)
        var largeTimes: [UInt64] = []
        _ = try BONJSONDecoder().decode([LargeObject].self, from: largeData)
        for _ in 0..<iterations {
            let start = DispatchTime.now().uptimeNanoseconds
            _ = try BONJSONDecoder().decode([LargeObject].self, from: largeData)
            let end = DispatchTime.now().uptimeNanoseconds
            largeTimes.append(end - start)
        }

        let avgSmall = smallTimes.reduce(0, +) / UInt64(iterations)
        let avgLarge = largeTimes.reduce(0, +) / UInt64(iterations)

        print("""

        === Small vs Large Objects (linear search vs dictionary) ===
        1000 objects × 5 fields (linear):   \(formatNs(avgSmall)) (\(formatNs(avgSmall / 5000)) per field)
        1000 objects × 15 fields (dict):    \(formatNs(avgLarge)) (\(formatNs(avgLarge / 15000)) per field)
        Dictionary mode per-field cost: \(formatNs(avgLarge / 15000))
        Linear mode per-field cost:     \(formatNs(avgSmall / 5000))
        """)
    }

    func testStringArrayVsIntArray() throws {
        // Compare string array performance (not batched) vs int array (batched)
        let intArray = Array(0..<10000)
        let stringArray = (0..<10000).map { "Item\($0)" }

        let intData = try BONJSONEncoder().encode(intArray)
        let stringData = try BONJSONEncoder().encode(stringArray)

        let iterations = 50

        // Int array (batched)
        var intTimes: [UInt64] = []
        _ = try BONJSONDecoder().decode([Int].self, from: intData)
        for _ in 0..<iterations {
            let start = DispatchTime.now().uptimeNanoseconds
            _ = try BONJSONDecoder().decode([Int].self, from: intData)
            let end = DispatchTime.now().uptimeNanoseconds
            intTimes.append(end - start)
        }

        // String array (not batched)
        var stringTimes: [UInt64] = []
        _ = try BONJSONDecoder().decode([String].self, from: stringData)
        for _ in 0..<iterations {
            let start = DispatchTime.now().uptimeNanoseconds
            _ = try BONJSONDecoder().decode([String].self, from: stringData)
            let end = DispatchTime.now().uptimeNanoseconds
            stringTimes.append(end - start)
        }

        let avgInt = intTimes.reduce(0, +) / UInt64(iterations)
        let avgString = stringTimes.reduce(0, +) / UInt64(iterations)

        print("""

        === String Array vs Int Array (10000 elements) ===
        Int array (batched):      \(formatNs(avgInt)) (\(formatNs(avgInt / 10000)) per element)
        String array (unbatched): \(formatNs(avgString)) (\(formatNs(avgString / 10000)) per element)
        String/Int ratio: \(String(format: "%.1f", Double(avgString) / Double(avgInt)))x
        Potential savings from string batch: \(formatNs(avgString - avgInt))
        """)
    }

    func testDetailedAnalysis() throws {
        print("""

        ================================================================================
                                DETAILED BOTTLENECK ANALYSIS
        ================================================================================
        """)

        try testObjectSizeVsCount()
        try testNestedObjectOverhead()
        try testLargeObjectDecoding()
        try testStringArrayVsIntArray()
    }
}
