// swift-tools-version: 5.9
// ABOUTME: Swift package manifest for BONJSON codec library.
// ABOUTME: Provides BONJSONEncoder/BONJSONDecoder as drop-in replacements for JSON codecs.

import PackageDescription

let package = Package(
    name: "BONJSON",
    products: [
        .library(
            name: "BONJSON",
            targets: ["BONJSON"]),
        .executable(
            name: "bonjson-benchmark",
            targets: ["BONJSONBenchmark"]),
    ],
    targets: [
        .target(
            name: "BONJSON"),
        .executableTarget(
            name: "BONJSONBenchmark",
            dependencies: ["BONJSON"]),
        .testTarget(
            name: "BONJSONTests",
            dependencies: ["BONJSON"]),
    ]
)
