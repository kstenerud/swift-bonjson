// ABOUTME: Benchmark tests comparing BONJSON with Apple's JSON codecs.
// ABOUTME: Measures encoding/decoding performance and output size.

import XCTest
import Foundation
@testable import BONJSON

final class BONJSONBenchmarkTests: XCTestCase {

    // MARK: - Test Data Structures

    struct SmallObject: Codable, Equatable {
        var id: Int
        var name: String
        var active: Bool
    }

    struct MediumObject: Codable, Equatable {
        var id: Int
        var firstName: String
        var lastName: String
        var email: String
        var age: Int
        var score: Double
        var isVerified: Bool
        var tags: [String]
    }

    struct LargeObject: Codable, Equatable {
        var id: Int
        var title: String
        var description: String
        var metadata: [String: String]
        var items: [MediumObject]
        var counts: [Int]
        var values: [Double]
    }

    // MARK: - Test Data Generation

    func makeSmallObjects(count: Int) -> [SmallObject] {
        return (0..<count).map { i in
            SmallObject(id: i, name: "Object \(i)", active: i % 2 == 0)
        }
    }

    func makeMediumObjects(count: Int) -> [MediumObject] {
        return (0..<count).map { i in
            MediumObject(
                id: i,
                firstName: "First\(i)",
                lastName: "Last\(i)",
                email: "user\(i)@example.com",
                age: 20 + (i % 50),
                score: Double(i) * 1.5,
                isVerified: i % 3 == 0,
                tags: ["tag\(i % 5)", "category\(i % 3)", "type\(i % 7)"]
            )
        }
    }

    func makeLargeObject() -> LargeObject {
        return LargeObject(
            id: 1,
            title: "Large Dataset",
            description: String(repeating: "This is a longer description. ", count: 10),
            metadata: Dictionary(uniqueKeysWithValues: (0..<20).map { ("key\($0)", "value\($0)") }),
            items: makeMediumObjects(count: 50),
            counts: Array(0..<100),
            values: (0..<100).map { Double($0) * 0.1 }
        )
    }

    // MARK: - Benchmark Helpers

    struct BenchmarkResult {
        let name: String
        let iterations: Int
        let totalTime: TimeInterval
        let dataSize: Int

        var averageTime: TimeInterval { totalTime / Double(iterations) }
        var throughputMBps: Double {
            let megabytes = Double(dataSize * iterations) / (1024 * 1024)
            return megabytes / totalTime
        }
    }

    func benchmark(name: String, iterations: Int, dataSize: Int, block: () throws -> Void) rethrows -> BenchmarkResult {
        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<iterations {
            try block()
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        return BenchmarkResult(name: name, iterations: iterations, totalTime: elapsed, dataSize: dataSize)
    }

    func printComparison(_ bonjson: BenchmarkResult, _ json: BenchmarkResult, file: StaticString = #file, line: UInt = #line) {
        let speedup = json.averageTime / bonjson.averageTime
        let sizeRatio = Double(json.dataSize) / Double(bonjson.dataSize)

        let message = """

        === \(bonjson.name) ===
        BONJSON: \(String(format: "%.3f", bonjson.averageTime * 1000)) ms avg, \(String(format: "%.2f", bonjson.throughputMBps)) MB/s, \(bonjson.dataSize) bytes
        JSON:    \(String(format: "%.3f", json.averageTime * 1000)) ms avg, \(String(format: "%.2f", json.throughputMBps)) MB/s, \(json.dataSize) bytes
        Speedup: \(String(format: "%.2f", speedup))x \(speedup > 1 ? "(BONJSON faster)" : "(JSON faster)")
        Size:    \(String(format: "%.2f", sizeRatio))x \(sizeRatio > 1 ? "(BONJSON smaller)" : "(JSON smaller)")
        """

        // Use XCTContext to ensure output is visible
        XCTContext.runActivity(named: bonjson.name) { _ in
            print(message)
        }

        // Record as test attachment for visibility
        let attachment = XCTAttachment(string: message)
        attachment.name = bonjson.name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - Encoding Benchmarks

    func testBenchmarkEncodeSmallObjects() throws {
        let objects = makeSmallObjects(count: 1000)
        let iterations = 100

        let bonjsonEncoder = BONJSONEncoder()
        let jsonEncoder = JSONEncoder()

        // Warm up
        _ = try bonjsonEncoder.encode(objects)
        _ = try jsonEncoder.encode(objects)

        // Get data sizes
        let bonjsonData = try bonjsonEncoder.encode(objects)
        let jsonData = try jsonEncoder.encode(objects)

        let bonjsonResult = try benchmark(name: "Encode 1000 Small Objects", iterations: iterations, dataSize: bonjsonData.count) {
            _ = try bonjsonEncoder.encode(objects)
        }

        let jsonResult = try benchmark(name: "Encode 1000 Small Objects", iterations: iterations, dataSize: jsonData.count) {
            _ = try jsonEncoder.encode(objects)
        }

        printComparison(bonjsonResult, jsonResult)

        // Verify correctness
        let decoded = try BONJSONDecoder().decode([SmallObject].self, from: bonjsonData)
        XCTAssertEqual(decoded, objects)
    }

    func testBenchmarkEncodeMediumObjects() throws {
        let objects = makeMediumObjects(count: 500)
        let iterations = 100

        let bonjsonEncoder = BONJSONEncoder()
        let jsonEncoder = JSONEncoder()

        // Warm up
        _ = try bonjsonEncoder.encode(objects)
        _ = try jsonEncoder.encode(objects)

        // Get data sizes
        let bonjsonData = try bonjsonEncoder.encode(objects)
        let jsonData = try jsonEncoder.encode(objects)

        let bonjsonResult = try benchmark(name: "Encode 500 Medium Objects", iterations: iterations, dataSize: bonjsonData.count) {
            _ = try bonjsonEncoder.encode(objects)
        }

        let jsonResult = try benchmark(name: "Encode 500 Medium Objects", iterations: iterations, dataSize: jsonData.count) {
            _ = try jsonEncoder.encode(objects)
        }

        printComparison(bonjsonResult, jsonResult)

        // Verify correctness
        let decoded = try BONJSONDecoder().decode([MediumObject].self, from: bonjsonData)
        XCTAssertEqual(decoded, objects)
    }

    func testBenchmarkEncodeLargeObject() throws {
        let object = makeLargeObject()
        let iterations = 100

        let bonjsonEncoder = BONJSONEncoder()
        let jsonEncoder = JSONEncoder()

        // Warm up
        _ = try bonjsonEncoder.encode(object)
        _ = try jsonEncoder.encode(object)

        // Get data sizes
        let bonjsonData = try bonjsonEncoder.encode(object)
        let jsonData = try jsonEncoder.encode(object)

        let bonjsonResult = try benchmark(name: "Encode Large Object", iterations: iterations, dataSize: bonjsonData.count) {
            _ = try bonjsonEncoder.encode(object)
        }

        let jsonResult = try benchmark(name: "Encode Large Object", iterations: iterations, dataSize: jsonData.count) {
            _ = try jsonEncoder.encode(object)
        }

        printComparison(bonjsonResult, jsonResult)

        // Verify correctness
        let decoded = try BONJSONDecoder().decode(LargeObject.self, from: bonjsonData)
        XCTAssertEqual(decoded, object)
    }

    // MARK: - Decoding Benchmarks

    func testBenchmarkDecodeSmallObjects() throws {
        let objects = makeSmallObjects(count: 1000)
        let iterations = 100

        let bonjsonData = try BONJSONEncoder().encode(objects)
        let jsonData = try JSONEncoder().encode(objects)

        let bonjsonDecoder = BONJSONDecoder()
        let jsonDecoder = JSONDecoder()

        // Warm up
        _ = try bonjsonDecoder.decode([SmallObject].self, from: bonjsonData)
        _ = try jsonDecoder.decode([SmallObject].self, from: jsonData)

        let bonjsonResult = try benchmark(name: "Decode 1000 Small Objects", iterations: iterations, dataSize: bonjsonData.count) {
            _ = try bonjsonDecoder.decode([SmallObject].self, from: bonjsonData)
        }

        let jsonResult = try benchmark(name: "Decode 1000 Small Objects", iterations: iterations, dataSize: jsonData.count) {
            _ = try jsonDecoder.decode([SmallObject].self, from: jsonData)
        }

        printComparison(bonjsonResult, jsonResult)
    }

    func testBenchmarkDecodeMediumObjects() throws {
        let objects = makeMediumObjects(count: 500)
        let iterations = 100

        let bonjsonData = try BONJSONEncoder().encode(objects)
        let jsonData = try JSONEncoder().encode(objects)

        let bonjsonDecoder = BONJSONDecoder()
        let jsonDecoder = JSONDecoder()

        // Warm up
        _ = try bonjsonDecoder.decode([MediumObject].self, from: bonjsonData)
        _ = try jsonDecoder.decode([MediumObject].self, from: jsonData)

        let bonjsonResult = try benchmark(name: "Decode 500 Medium Objects", iterations: iterations, dataSize: bonjsonData.count) {
            _ = try bonjsonDecoder.decode([MediumObject].self, from: bonjsonData)
        }

        let jsonResult = try benchmark(name: "Decode 500 Medium Objects", iterations: iterations, dataSize: jsonData.count) {
            _ = try jsonDecoder.decode([MediumObject].self, from: jsonData)
        }

        printComparison(bonjsonResult, jsonResult)
    }

    func testBenchmarkDecodeLargeObject() throws {
        let object = makeLargeObject()
        let iterations = 100

        let bonjsonData = try BONJSONEncoder().encode(object)
        let jsonData = try JSONEncoder().encode(object)

        let bonjsonDecoder = BONJSONDecoder()
        let jsonDecoder = JSONDecoder()

        // Warm up
        _ = try bonjsonDecoder.decode(LargeObject.self, from: bonjsonData)
        _ = try jsonDecoder.decode(LargeObject.self, from: jsonData)

        let bonjsonResult = try benchmark(name: "Decode Large Object", iterations: iterations, dataSize: bonjsonData.count) {
            _ = try bonjsonDecoder.decode(LargeObject.self, from: bonjsonData)
        }

        let jsonResult = try benchmark(name: "Decode Large Object", iterations: iterations, dataSize: jsonData.count) {
            _ = try jsonDecoder.decode(LargeObject.self, from: jsonData)
        }

        printComparison(bonjsonResult, jsonResult)
    }

    // MARK: - Specific Type Benchmarks

    func testBenchmarkEncodeIntegers() throws {
        let integers = Array(0..<1000)
        let iterations = 50

        let bonjsonEncoder = BONJSONEncoder()
        let jsonEncoder = JSONEncoder()

        let bonjsonData = try bonjsonEncoder.encode(integers)
        let jsonData = try jsonEncoder.encode(integers)

        // Warm up
        _ = try bonjsonEncoder.encode(integers)
        _ = try jsonEncoder.encode(integers)

        let bonjsonResult = try benchmark(name: "Encode 1000 Integers", iterations: iterations, dataSize: bonjsonData.count) {
            _ = try bonjsonEncoder.encode(integers)
        }

        let jsonResult = try benchmark(name: "Encode 1000 Integers", iterations: iterations, dataSize: jsonData.count) {
            _ = try jsonEncoder.encode(integers)
        }

        printComparison(bonjsonResult, jsonResult)
    }

    func testBenchmarkEncodeDoubles() throws {
        let doubles = (0..<1000).map { Double($0) * 0.123456789 }
        let iterations = 50

        let bonjsonEncoder = BONJSONEncoder()
        let jsonEncoder = JSONEncoder()

        let bonjsonData = try bonjsonEncoder.encode(doubles)
        let jsonData = try jsonEncoder.encode(doubles)

        // Warm up
        _ = try bonjsonEncoder.encode(doubles)
        _ = try jsonEncoder.encode(doubles)

        let bonjsonResult = try benchmark(name: "Encode 1000 Doubles", iterations: iterations, dataSize: bonjsonData.count) {
            _ = try bonjsonEncoder.encode(doubles)
        }

        let jsonResult = try benchmark(name: "Encode 1000 Doubles", iterations: iterations, dataSize: jsonData.count) {
            _ = try jsonEncoder.encode(doubles)
        }

        printComparison(bonjsonResult, jsonResult)
    }

    func testBenchmarkEncodeStrings() throws {
        let strings = (0..<500).map { "This is string number \($0) with some additional text to make it longer" }
        let iterations = 50

        let bonjsonEncoder = BONJSONEncoder()
        let jsonEncoder = JSONEncoder()

        let bonjsonData = try bonjsonEncoder.encode(strings)
        let jsonData = try jsonEncoder.encode(strings)

        // Warm up
        _ = try bonjsonEncoder.encode(strings)
        _ = try jsonEncoder.encode(strings)

        let bonjsonResult = try benchmark(name: "Encode 500 Strings", iterations: iterations, dataSize: bonjsonData.count) {
            _ = try bonjsonEncoder.encode(strings)
        }

        let jsonResult = try benchmark(name: "Encode 500 Strings", iterations: iterations, dataSize: jsonData.count) {
            _ = try jsonEncoder.encode(strings)
        }

        printComparison(bonjsonResult, jsonResult)
    }

    // MARK: - Size Comparison Summary

    func testSizeComparison() throws {
        let bonjsonEncoder = BONJSONEncoder()
        let jsonEncoder = JSONEncoder()

        struct SizeTest {
            let name: String
            let bonjsonSize: Int
            let jsonSize: Int

            var ratio: Double { Double(jsonSize) / Double(bonjsonSize) }
            var savings: Double { (1.0 - Double(bonjsonSize) / Double(jsonSize)) * 100 }
        }

        var tests: [SizeTest] = []

        // Small integers
        let smallInts = Array(0..<100)
        tests.append(SizeTest(
            name: "100 small integers (0-99)",
            bonjsonSize: try bonjsonEncoder.encode(smallInts).count,
            jsonSize: try jsonEncoder.encode(smallInts).count
        ))

        // Large integers
        let largeInts = (0..<100).map { Int64($0) * 1_000_000_000 }
        tests.append(SizeTest(
            name: "100 large integers",
            bonjsonSize: try bonjsonEncoder.encode(largeInts).count,
            jsonSize: try jsonEncoder.encode(largeInts).count
        ))

        // Doubles
        let doubles = (0..<100).map { Double($0) * 3.14159 }
        tests.append(SizeTest(
            name: "100 doubles",
            bonjsonSize: try bonjsonEncoder.encode(doubles).count,
            jsonSize: try jsonEncoder.encode(doubles).count
        ))

        // Short strings
        let shortStrings = (0..<100).map { "str\($0)" }
        tests.append(SizeTest(
            name: "100 short strings",
            bonjsonSize: try bonjsonEncoder.encode(shortStrings).count,
            jsonSize: try jsonEncoder.encode(shortStrings).count
        ))

        // Booleans
        let bools = (0..<100).map { $0 % 2 == 0 }
        tests.append(SizeTest(
            name: "100 booleans",
            bonjsonSize: try bonjsonEncoder.encode(bools).count,
            jsonSize: try jsonEncoder.encode(bools).count
        ))

        // Mixed object
        let objects = makeMediumObjects(count: 100)
        tests.append(SizeTest(
            name: "100 medium objects",
            bonjsonSize: try bonjsonEncoder.encode(objects).count,
            jsonSize: try jsonEncoder.encode(objects).count
        ))

        // Build results string
        var results = "\n=== Size Comparison Summary ===\n\n"
        results += "Test".padding(toLength: 30, withPad: " ", startingAt: 0)
            + "BONJSON".padding(toLength: 10, withPad: " ", startingAt: 0)
            + "JSON".padding(toLength: 10, withPad: " ", startingAt: 0)
            + "Ratio".padding(toLength: 10, withPad: " ", startingAt: 0)
            + "Savings\n"
        results += String(repeating: "-", count: 70) + "\n"

        for test in tests {
            results += test.name.padding(toLength: 30, withPad: " ", startingAt: 0)
                + String(test.bonjsonSize).padding(toLength: 10, withPad: " ", startingAt: 0)
                + String(test.jsonSize).padding(toLength: 10, withPad: " ", startingAt: 0)
                + String(format: "%.2fx", test.ratio).padding(toLength: 10, withPad: " ", startingAt: 0)
                + String(format: "%.1f%%\n", test.savings)
        }

        XCTContext.runActivity(named: "Size Comparison") { _ in
            print(results)
        }

        let attachment = XCTAttachment(string: results)
        attachment.name = "Size Comparison"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

