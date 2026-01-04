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
}
