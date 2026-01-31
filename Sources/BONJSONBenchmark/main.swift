// ABOUTME: Benchmark executable comparing BONJSON with Apple's JSON codecs.
// ABOUTME: Run with: swift run -c release bonjson-benchmark

import Foundation
import BONJSON

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

struct StringHeavyObject: Codable, Equatable {
    var id: Int
    var biography: String
    var notes: String
    var address: String
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

func makeLongStrings(count: Int, length: Int) -> [String] {
    let base = "The quick brown fox jumps over the lazy dog. "
    let repeated = String(repeating: base, count: (length / base.count) + 1)
    let template = String(repeated.prefix(length))
    return (0..<count).map { i in
        var s = template
        let suffix = " [\(i)]"
        s.replaceSubrange(s.index(s.endIndex, offsetBy: -suffix.count)..<s.endIndex, with: suffix)
        return s
    }
}

func makeStringHeavyObjects(count: Int) -> [StringHeavyObject] {
    return (0..<count).map { i in
        StringHeavyObject(
            id: i,
            biography: String(repeating: "Lorem ipsum dolor sit amet, consectetur adipiscing elit. ", count: 5) + "Person \(i).",
            notes: String(repeating: "Note entry with various details and observations. ", count: 4) + "Item \(i).",
            address: "\(i) Example Street, Suite \(i * 10), Springfield, IL 62704, United States of America"
        )
    }
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

func printComparison(_ bonjson: BenchmarkResult, _ json: BenchmarkResult) {
    let speedup = json.averageTime / bonjson.averageTime
    let sizeRatio = Double(json.dataSize) / Double(bonjson.dataSize)

    print("")
    print("=== \(bonjson.name) ===")
    print(String(format: "BONJSON: %8.3f ms avg, %8.2f MB/s, %6d bytes",
                 bonjson.averageTime * 1000, bonjson.throughputMBps, bonjson.dataSize))
    print(String(format: "JSON:    %8.3f ms avg, %8.2f MB/s, %6d bytes",
                 json.averageTime * 1000, json.throughputMBps, json.dataSize))
    print(String(format: "Speed:   %5.2fx %@",
                 speedup, speedup >= 1 ? "(BONJSON faster)" : "(JSON faster)"))
    print(String(format: "Size:    %5.2fx %@",
                 sizeRatio, sizeRatio >= 1 ? "(BONJSON smaller)" : "(JSON smaller)"))
}

// MARK: - Main

print("╔══════════════════════════════════════════════════════════════════╗")
print("║              BONJSON vs JSON Benchmark Results                   ║")
print("╚══════════════════════════════════════════════════════════════════╝")

let iterations = 100

// MARK: - Encoding Benchmarks

print("\n▶ ENCODING BENCHMARKS")
print(String(repeating: "─", count: 70))

do {
    let objects = makeSmallObjects(count: 1000)
    let bonjsonEncoder = BONJSONEncoder()
    let jsonEncoder = JSONEncoder()

    // Warm up
    _ = try bonjsonEncoder.encode(objects)
    _ = try jsonEncoder.encode(objects)

    let bonjsonData = try bonjsonEncoder.encode(objects)
    let jsonData = try jsonEncoder.encode(objects)

    let bonjsonResult = try benchmark(name: "Encode 1000 Small Objects", iterations: iterations, dataSize: bonjsonData.count) {
        _ = try bonjsonEncoder.encode(objects)
    }

    let jsonResult = try benchmark(name: "Encode 1000 Small Objects", iterations: iterations, dataSize: jsonData.count) {
        _ = try jsonEncoder.encode(objects)
    }

    printComparison(bonjsonResult, jsonResult)
}

do {
    let objects = makeMediumObjects(count: 500)
    let bonjsonEncoder = BONJSONEncoder()
    let jsonEncoder = JSONEncoder()

    _ = try bonjsonEncoder.encode(objects)
    _ = try jsonEncoder.encode(objects)

    let bonjsonData = try bonjsonEncoder.encode(objects)
    let jsonData = try jsonEncoder.encode(objects)

    let bonjsonResult = try benchmark(name: "Encode 500 Medium Objects", iterations: iterations, dataSize: bonjsonData.count) {
        _ = try bonjsonEncoder.encode(objects)
    }

    let jsonResult = try benchmark(name: "Encode 500 Medium Objects", iterations: iterations, dataSize: jsonData.count) {
        _ = try jsonEncoder.encode(objects)
    }

    printComparison(bonjsonResult, jsonResult)
}

do {
    let object = makeLargeObject()
    let bonjsonEncoder = BONJSONEncoder()
    let jsonEncoder = JSONEncoder()

    _ = try bonjsonEncoder.encode(object)
    _ = try jsonEncoder.encode(object)

    let bonjsonData = try bonjsonEncoder.encode(object)
    let jsonData = try jsonEncoder.encode(object)

    let bonjsonResult = try benchmark(name: "Encode Large Object", iterations: iterations, dataSize: bonjsonData.count) {
        _ = try bonjsonEncoder.encode(object)
    }

    let jsonResult = try benchmark(name: "Encode Large Object", iterations: iterations, dataSize: jsonData.count) {
        _ = try jsonEncoder.encode(object)
    }

    printComparison(bonjsonResult, jsonResult)
}

do {
    let integers = Array(0..<1000)
    let bonjsonEncoder = BONJSONEncoder()
    let jsonEncoder = JSONEncoder()

    _ = try bonjsonEncoder.encode(integers)
    _ = try jsonEncoder.encode(integers)

    let bonjsonData = try bonjsonEncoder.encode(integers)
    let jsonData = try jsonEncoder.encode(integers)

    let bonjsonResult = try benchmark(name: "Encode 1000 Integers", iterations: iterations, dataSize: bonjsonData.count) {
        _ = try bonjsonEncoder.encode(integers)
    }

    let jsonResult = try benchmark(name: "Encode 1000 Integers", iterations: iterations, dataSize: jsonData.count) {
        _ = try jsonEncoder.encode(integers)
    }

    printComparison(bonjsonResult, jsonResult)
}

do {
    let doubles = (0..<1000).map { Double($0) * 0.123456789 }
    let bonjsonEncoder = BONJSONEncoder()
    let jsonEncoder = JSONEncoder()

    _ = try bonjsonEncoder.encode(doubles)
    _ = try jsonEncoder.encode(doubles)

    let bonjsonData = try bonjsonEncoder.encode(doubles)
    let jsonData = try jsonEncoder.encode(doubles)

    let bonjsonResult = try benchmark(name: "Encode 1000 Doubles", iterations: iterations, dataSize: bonjsonData.count) {
        _ = try bonjsonEncoder.encode(doubles)
    }

    let jsonResult = try benchmark(name: "Encode 1000 Doubles", iterations: iterations, dataSize: jsonData.count) {
        _ = try jsonEncoder.encode(doubles)
    }

    printComparison(bonjsonResult, jsonResult)
}

do {
    let strings = makeLongStrings(count: 1000, length: 200)
    let bonjsonEncoder = BONJSONEncoder()
    let jsonEncoder = JSONEncoder()

    _ = try bonjsonEncoder.encode(strings)
    _ = try jsonEncoder.encode(strings)

    let bonjsonData = try bonjsonEncoder.encode(strings)
    let jsonData = try jsonEncoder.encode(strings)

    let bonjsonResult = try benchmark(name: "Encode 1000 Long Strings (200B)", iterations: iterations, dataSize: bonjsonData.count) {
        _ = try bonjsonEncoder.encode(strings)
    }

    let jsonResult = try benchmark(name: "Encode 1000 Long Strings (200B)", iterations: iterations, dataSize: jsonData.count) {
        _ = try jsonEncoder.encode(strings)
    }

    printComparison(bonjsonResult, jsonResult)
}

do {
    let objects = makeStringHeavyObjects(count: 500)
    let bonjsonEncoder = BONJSONEncoder()
    let jsonEncoder = JSONEncoder()

    _ = try bonjsonEncoder.encode(objects)
    _ = try jsonEncoder.encode(objects)

    let bonjsonData = try bonjsonEncoder.encode(objects)
    let jsonData = try jsonEncoder.encode(objects)

    let bonjsonResult = try benchmark(name: "Encode 500 String-Heavy Objects", iterations: iterations, dataSize: bonjsonData.count) {
        _ = try bonjsonEncoder.encode(objects)
    }

    let jsonResult = try benchmark(name: "Encode 500 String-Heavy Objects", iterations: iterations, dataSize: jsonData.count) {
        _ = try jsonEncoder.encode(objects)
    }

    printComparison(bonjsonResult, jsonResult)
}

// MARK: - Decoding Benchmarks

print("\n▶ DECODING BENCHMARKS")
print(String(repeating: "─", count: 70))

do {
    let objects = makeSmallObjects(count: 1000)
    let bonjsonData = try BONJSONEncoder().encode(objects)
    let jsonData = try JSONEncoder().encode(objects)

    let bonjsonDecoder = BONJSONDecoder()
    let jsonDecoder = JSONDecoder()

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

do {
    let objects = makeMediumObjects(count: 500)
    let bonjsonData = try BONJSONEncoder().encode(objects)
    let jsonData = try JSONEncoder().encode(objects)

    let bonjsonDecoder = BONJSONDecoder()
    let jsonDecoder = JSONDecoder()

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

do {
    let object = makeLargeObject()
    let bonjsonData = try BONJSONEncoder().encode(object)
    let jsonData = try JSONEncoder().encode(object)

    let bonjsonDecoder = BONJSONDecoder()
    let jsonDecoder = JSONDecoder()

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

do {
    let strings = makeLongStrings(count: 1000, length: 200)
    let bonjsonData = try BONJSONEncoder().encode(strings)
    let jsonData = try JSONEncoder().encode(strings)

    let bonjsonDecoder = BONJSONDecoder()
    let jsonDecoder = JSONDecoder()

    _ = try bonjsonDecoder.decode([String].self, from: bonjsonData)
    _ = try jsonDecoder.decode([String].self, from: jsonData)

    let bonjsonResult = try benchmark(name: "Decode 1000 Long Strings (200B)", iterations: iterations, dataSize: bonjsonData.count) {
        _ = try bonjsonDecoder.decode([String].self, from: bonjsonData)
    }

    let jsonResult = try benchmark(name: "Decode 1000 Long Strings (200B)", iterations: iterations, dataSize: jsonData.count) {
        _ = try jsonDecoder.decode([String].self, from: jsonData)
    }

    printComparison(bonjsonResult, jsonResult)
}

do {
    let objects = makeStringHeavyObjects(count: 500)
    let bonjsonData = try BONJSONEncoder().encode(objects)
    let jsonData = try JSONEncoder().encode(objects)

    let bonjsonDecoder = BONJSONDecoder()
    let jsonDecoder = JSONDecoder()

    _ = try bonjsonDecoder.decode([StringHeavyObject].self, from: bonjsonData)
    _ = try jsonDecoder.decode([StringHeavyObject].self, from: jsonData)

    let bonjsonResult = try benchmark(name: "Decode 500 String-Heavy Objects", iterations: iterations, dataSize: bonjsonData.count) {
        _ = try bonjsonDecoder.decode([StringHeavyObject].self, from: bonjsonData)
    }

    let jsonResult = try benchmark(name: "Decode 500 String-Heavy Objects", iterations: iterations, dataSize: jsonData.count) {
        _ = try jsonDecoder.decode([StringHeavyObject].self, from: jsonData)
    }

    printComparison(bonjsonResult, jsonResult)
}

// MARK: - Size Comparison

print("\n▶ SIZE COMPARISON")
print(String(repeating: "─", count: 70))

struct SizeTest {
    let name: String
    let bonjsonSize: Int
    let jsonSize: Int

    var ratio: Double { Double(jsonSize) / Double(bonjsonSize) }
    var savings: Double { (1.0 - Double(bonjsonSize) / Double(jsonSize)) * 100 }
}

do {
    let bonjsonEncoder = BONJSONEncoder()
    let jsonEncoder = JSONEncoder()

    var tests: [SizeTest] = []

    let smallInts = Array(0..<100)
    tests.append(SizeTest(
        name: "100 small integers (0-99)",
        bonjsonSize: try bonjsonEncoder.encode(smallInts).count,
        jsonSize: try jsonEncoder.encode(smallInts).count
    ))

    let largeInts = (0..<100).map { Int64($0) * 1_000_000_000 }
    tests.append(SizeTest(
        name: "100 large integers",
        bonjsonSize: try bonjsonEncoder.encode(largeInts).count,
        jsonSize: try jsonEncoder.encode(largeInts).count
    ))

    let doubles = (0..<100).map { Double($0) * 3.14159 }
    tests.append(SizeTest(
        name: "100 doubles",
        bonjsonSize: try bonjsonEncoder.encode(doubles).count,
        jsonSize: try jsonEncoder.encode(doubles).count
    ))

    let shortStrings = (0..<100).map { "str\($0)" }
    tests.append(SizeTest(
        name: "100 short strings",
        bonjsonSize: try bonjsonEncoder.encode(shortStrings).count,
        jsonSize: try jsonEncoder.encode(shortStrings).count
    ))

    let bools = (0..<100).map { $0 % 2 == 0 }
    tests.append(SizeTest(
        name: "100 booleans",
        bonjsonSize: try bonjsonEncoder.encode(bools).count,
        jsonSize: try jsonEncoder.encode(bools).count
    ))

    let objects = makeMediumObjects(count: 100)
    tests.append(SizeTest(
        name: "100 medium objects",
        bonjsonSize: try bonjsonEncoder.encode(objects).count,
        jsonSize: try jsonEncoder.encode(objects).count
    ))

    print("")
    let header = "Test".padding(toLength: 30, withPad: " ", startingAt: 0)
        + "BONJSON".padding(toLength: 10, withPad: " ", startingAt: 0)
        + "JSON".padding(toLength: 10, withPad: " ", startingAt: 0)
        + "Ratio".padding(toLength: 10, withPad: " ", startingAt: 0)
        + "Savings"
    print(header)
    print(String(repeating: "─", count: 70))

    for test in tests {
        let row = test.name.padding(toLength: 30, withPad: " ", startingAt: 0)
            + String(test.bonjsonSize).padding(toLength: 10, withPad: " ", startingAt: 0)
            + String(test.jsonSize).padding(toLength: 10, withPad: " ", startingAt: 0)
            + String(format: "%.2fx", test.ratio).padding(toLength: 10, withPad: " ", startingAt: 0)
            + String(format: "%.1f%%", test.savings)
        print(row)
    }
}

print("\n" + String(repeating: "═", count: 70))
print("Benchmark complete.")
