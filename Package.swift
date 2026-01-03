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
    ],
    targets: [
        .target(
            name: "BONJSON"),
        .testTarget(
            name: "BONJSONTests",
            dependencies: ["BONJSON"]),
    ]
)
