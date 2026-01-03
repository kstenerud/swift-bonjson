# BONJSON for Swift

A Swift implementation of [BONJSON](https://github.com/kstenerud/bonjson), a binary drop-in replacement for JSON.

BONJSON offers 1:1 compatibility with JSON while providing faster processing and enhanced security. It maintains identical type support: strings, numbers, arrays, objects, booleans, and null.

## Features

- **Drop-in replacement** for `JSONEncoder` and `JSONDecoder`
- **Full Swift Codable support** with all container types
- **Encoding strategies** matching Apple's JSON codecs:
  - Date encoding/decoding (timestamps, ISO 8601, custom formatters)
  - Data encoding/decoding (Base64, custom)
  - Key strategies (snake_case conversion, custom)
  - Non-conforming float handling
- **Efficient binary encoding** using compiler intrinsics
- **Security features**: UTF-8 validation, duplicate key detection, depth limits

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

## BONJSON Format Benefits

Compared to JSON:

- **Smaller size**: Binary encoding is more compact, especially for numbers
- **Faster parsing**: No text parsing overhead; type codes enable direct decoding
- **Integer preservation**: Integers remain integers (JSON converts all numbers to floats)
- **Security**: Built-in protections against common vulnerabilities

## API Reference

### BONJSONEncoder

| Property | Type | Description |
|----------|------|-------------|
| `dateEncodingStrategy` | `DateEncodingStrategy` | How to encode `Date` values |
| `dataEncodingStrategy` | `DataEncodingStrategy` | How to encode `Data` values |
| `keyEncodingStrategy` | `KeyEncodingStrategy` | How to encode coding keys |
| `nonConformingFloatEncodingStrategy` | `NonConformingFloatEncodingStrategy` | How to handle NaN/Infinity |
| `userInfo` | `[CodingUserInfoKey: Any]` | Contextual information for encoding |

### BONJSONDecoder

| Property | Type | Description |
|----------|------|-------------|
| `dateDecodingStrategy` | `DateDecodingStrategy` | How to decode `Date` values |
| `dataDecodingStrategy` | `DataDecodingStrategy` | How to decode `Data` values |
| `keyDecodingStrategy` | `KeyDecodingStrategy` | How to decode coding keys |
| `nonConformingFloatDecodingStrategy` | `NonConformingFloatDecodingStrategy` | How to handle NaN/Infinity strings |
| `userInfo` | `[CodingUserInfoKey: Any]` | Contextual information for decoding |

## Requirements

- Swift 5.9+
- macOS, iOS, tvOS, watchOS, or Linux

## License

MIT License. See [LICENSE](LICENSE) for details.

## See Also

- [BONJSON Specification](https://github.com/kstenerud/bonjson)
- [C Reference Implementation](https://github.com/kstenerud/ksbonjson)
