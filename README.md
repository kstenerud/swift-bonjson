# BONJSON for Swift

A Swift implementation of [BONJSON](https://github.com/kstenerud/bonjson), a binary drop-in replacement for JSON.

BONJSON offers 1:1 compatibility with JSON while providing smaller size, faster decoding, and enhanced security. It maintains identical type support: strings, numbers, arrays, objects, booleans, and null.

## Migration from JSON

Migration is as simple as a find-replace. Change `JSON` to `BinaryJSON`:

```diff
- import Foundation
+ import BONJSON

- let encoder = JSONEncoder()
+ let encoder = BinaryJSONEncoder()

- let decoder = JSONDecoder()
+ let decoder = BinaryJSONDecoder()
```

All encoding strategies (`dateEncodingStrategy`, `keyEncodingStrategy`, etc.) work the same way.

## Why BONJSON?

### Smaller Size

| Data Type              | Size Reduction |
|------------------------|----------------|
| Booleans               | 82% smaller    |
| Small integers (0-99)  | 65% smaller    |
| Large integers         | 50% smaller    |
| Doubles                | 24% smaller    |
| Strings                | 25% smaller    |
| Objects                | 24% smaller    |

### Faster Decoding

| Metric                | BONJSON | JSON    | Improvement    |
|-----------------------|---------|---------|----------------|
| Decode 1000 objects   | 490 µs  | 1.26 ms | **2.6x faster**|
| Throughput            | 53 MB/s | 35 MB/s | **1.5x faster**|

### Better Type Fidelity

- **Integer preservation**: Integers remain integers (JSON converts all numbers to floats)
- **Arbitrary precision**: Big numbers preserve full precision via the BigNumber type

### Enhanced Security

Built-in protections against common vulnerabilities:
- UTF-8 validation (reject malformed sequences)
- NUL character rejection
- Duplicate key detection
- Configurable resource limits (depth, size, etc.)

## Installation

### Swift Package Manager

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/kstenerud/swift-bonjson.git", from: "1.0.0")
]
```

Or in Xcode: File → Add Package Dependencies → Enter the repository URL.

## Usage

### Basic Encoding and Decoding

```swift
import BONJSON

struct Person: Codable {
    var name: String
    var age: Int
    var email: String?
}

// Encoding
let encoder = BONJSONEncoder()
let person = Person(name: "Alice", age: 30, email: "alice@example.com")
let data = try encoder.encode(person)

// Decoding
let decoder = BONJSONDecoder()
let decoded = try decoder.decode(Person.self, from: data)
```

### Date Encoding Strategies

```swift
let encoder = BONJSONEncoder()

// Unix timestamp (default)
encoder.dateEncodingStrategy = .secondsSince1970

// Milliseconds
encoder.dateEncodingStrategy = .millisecondsSince1970

// ISO 8601 string
encoder.dateEncodingStrategy = .iso8601

// Custom formatter
let formatter = DateFormatter()
formatter.dateFormat = "yyyy-MM-dd"
encoder.dateEncodingStrategy = .formatted(formatter)
```

### Key Encoding Strategies

```swift
struct UserProfile: Codable {
    var firstName: String
    var lastName: String
    var emailAddress: String
}

let encoder = BONJSONEncoder()
encoder.keyEncodingStrategy = .convertToSnakeCase
// Keys become: first_name, last_name, email_address

let decoder = BONJSONDecoder()
decoder.keyDecodingStrategy = .convertFromSnakeCase
```

### Handling Non-Conforming Floats

```swift
// Encoding
let encoder = BONJSONEncoder()
encoder.nonConformingFloatEncodingStrategy = .convertToString(
    positiveInfinity: "Infinity",
    negativeInfinity: "-Infinity",
    nan: "NaN"
)

// Decoding
let decoder = BONJSONDecoder()
decoder.nonConformingFloatDecodingStrategy = .convertFromString(
    positiveInfinity: "Infinity",
    negativeInfinity: "-Infinity",
    nan: "NaN"
)
```

### Security Configuration

```swift
let decoder = BONJSONDecoder()

// UTF-8 validation (default: .reject)
decoder.unicodeDecodingStrategy = .reject  // Throw on invalid UTF-8
decoder.unicodeDecodingStrategy = .replace // Replace with U+FFFD

// NUL character handling (default: .reject)
decoder.nulDecodingStrategy = .reject  // Throw on NUL characters
decoder.nulDecodingStrategy = .allow   // Allow NUL characters

// Duplicate key handling (default: .reject)
decoder.duplicateKeyDecodingStrategy = .reject    // Throw on duplicates
decoder.duplicateKeyDecodingStrategy = .keepFirst // Keep first occurrence
decoder.duplicateKeyDecodingStrategy = .keepLast  // Keep last occurrence

// Resource limits
decoder.maxDepth = 512            // Maximum nesting depth
decoder.maxStringLength = 10_000_000  // Maximum string length
decoder.maxContainerSize = 1_000_000  // Maximum array/object size
decoder.maxDocumentSize = 2_000_000_000  // Maximum document size
```

### Complex Types

```swift
// Arrays
let numbers = try encoder.encode([1, 2, 3, 4, 5])

// Dictionaries
let scores = try encoder.encode(["alice": 100, "bob": 95])

// Nested structures
struct Company: Codable {
    var name: String
    var employees: [Person]
    var metadata: [String: String]
}

// Enums
enum Status: String, Codable {
    case active, inactive, pending
}
```

## API Reference

### BONJSONEncoder

| Property                             | Type                                 | Description                        |
|--------------------------------------|--------------------------------------|------------------------------------|
| `dateEncodingStrategy`               | `DateEncodingStrategy`               | How to encode `Date` values        |
| `dataEncodingStrategy`               | `DataEncodingStrategy`               | How to encode `Data` values        |
| `keyEncodingStrategy`                | `KeyEncodingStrategy`                | How to encode coding keys          |
| `nonConformingFloatEncodingStrategy` | `NonConformingFloatEncodingStrategy` | How to handle NaN/Infinity         |
| `nulEncodingStrategy`                | `NulEncodingStrategy`                | How to handle NUL characters       |
| `maxDepth`                           | `Int`                                | Maximum container nesting depth    |
| `maxStringLength`                    | `Int`                                | Maximum string length in bytes     |
| `maxContainerSize`                   | `Int`                                | Maximum elements in a container    |
| `maxDocumentSize`                    | `Int`                                | Maximum document size in bytes     |
| `userInfo`                           | `[CodingUserInfoKey: Any]`           | Contextual information for encoding|

### BONJSONDecoder

| Property                             | Type                                 | Description                        |
|--------------------------------------|--------------------------------------|------------------------------------|
| `dateDecodingStrategy`               | `DateDecodingStrategy`               | How to decode `Date` values        |
| `dataDecodingStrategy`               | `DataDecodingStrategy`               | How to decode `Data` values        |
| `keyDecodingStrategy`                | `KeyDecodingStrategy`                | How to decode coding keys          |
| `nonConformingFloatDecodingStrategy` | `NonConformingFloatDecodingStrategy` | How to handle NaN/Infinity         |
| `unicodeDecodingStrategy`            | `UnicodeDecodingStrategy`            | How to handle invalid UTF-8        |
| `nulDecodingStrategy`                | `NulDecodingStrategy`                | How to handle NUL characters       |
| `duplicateKeyDecodingStrategy`       | `DuplicateKeyDecodingStrategy`       | How to handle duplicate keys       |
| `maxDepth`                           | `Int`                                | Maximum container nesting depth    |
| `maxStringLength`                    | `Int`                                | Maximum string length in bytes     |
| `maxContainerSize`                   | `Int`                                | Maximum elements in a container    |
| `maxDocumentSize`                    | `Int`                                | Maximum document size in bytes     |
| `maxChunks`                          | `Int`                                | Maximum string chunks              |
| `userInfo`                           | `[CodingUserInfoKey: Any]`           | Contextual information for decoding|

## Requirements

- Swift 5.9+
- macOS, iOS, tvOS, watchOS, or Linux

## License

MIT License. See [LICENSE](LICENSE) for details.

## See Also

- [BONJSON Specification](https://github.com/kstenerud/bonjson)
- [C Reference Implementation](https://github.com/kstenerud/ksbonjson)
