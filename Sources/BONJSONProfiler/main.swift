// ABOUTME: Profiling executable for generating flame graphs.
// ABOUTME: Run with: swift run -c release bonjson-profiler [encode|decode]

import Foundation
import BONJSON

struct SmallObject: Codable {
    var id: Int
    var name: String
    var active: Bool
}

struct MediumObject: Codable {
    var id: Int
    var firstName: String
    var lastName: String
    var email: String
    var age: Int
    var score: Double
    var isVerified: Bool
    var tags: [String]
}

func makeSmallObjects(count: Int) -> [SmallObject] {
    (0..<count).map { i in
        SmallObject(id: i, name: "Object \(i)", active: i % 2 == 0)
    }
}

func makeMediumObjects(count: Int) -> [MediumObject] {
    (0..<count).map { i in
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

// Get mode from command line
let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "both"

let iterations = 5000
let smallObjects = makeSmallObjects(count: 1000)
let mediumObjects = makeMediumObjects(count: 500)

let bonjsonEncoder = BONJSONEncoder()
let bonjsonDecoder = BONJSONDecoder()

// Pre-encode data for decoding tests
let smallData = try! bonjsonEncoder.encode(smallObjects)
let mediumData = try! bonjsonEncoder.encode(mediumObjects)

// Warm up
_ = try! bonjsonEncoder.encode(smallObjects)
_ = try! bonjsonDecoder.decode([SmallObject].self, from: smallData)

// Signal ready for profiling
print("READY")
fflush(stdout)

// Wait a moment to allow sampler to attach
Thread.sleep(forTimeInterval: 0.5)

if mode == "encode" || mode == "both" {
    print("Starting encode profiling...")
    for _ in 0..<iterations {
        _ = try! bonjsonEncoder.encode(smallObjects)
        _ = try! bonjsonEncoder.encode(mediumObjects)
    }
    print("Encode complete.")
}

if mode == "decode" || mode == "both" {
    print("Starting decode profiling...")
    for _ in 0..<iterations {
        _ = try! bonjsonDecoder.decode([SmallObject].self, from: smallData)
        _ = try! bonjsonDecoder.decode([MediumObject].self, from: mediumData)
    }
    print("Decode complete.")
}

print("DONE")
