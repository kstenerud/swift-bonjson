# Swift BONJSON Library

## Overview

This is a Swift library implementing a BONJSON codec - a binary drop-in replacement for JSON. It provides `BONJSONEncoder` and `BONJSONDecoder` classes that work exactly like Apple's `JSONEncoder` and `JSONDecoder`.

BONJSON is a binary format offering 1:1 JSON compatibility with faster processing and enhanced security. It maintains the same type support as JSON: strings, numbers, arrays, objects, booleans, and null.

## Architecture

### Source Files

- **BONJSONTypeCodes.swift**: Defines all BONJSON type codes and constants. Type codes are single bytes that identify the data type and sometimes encode small values directly.

- **BONJSONWriter.swift**: Low-level encoding primitives. Handles binary encoding of all BONJSON types using efficient intrinsics (leadingZeroBitCount, trailingZeroBitCount).

- **BONJSONReader.swift**: Low-level decoding primitives. Parses binary BONJSON data into an intermediate `BONJSONValue` representation.

- **BONJSONEncoder.swift**: Public encoder API matching `JSONEncoder` interface. Implements Swift's `Encoder` protocol with keyed, unkeyed, and single-value containers.

- **BONJSONDecoder.swift**: Public decoder API matching `JSONDecoder` interface. Implements Swift's `Decoder` protocol with all container types.

### Encoding Flow

1. User calls `encoder.encode(value)`
2. Value's `Encodable.encode(to:)` method builds an intermediate `_EncodedValue` representation
3. The intermediate representation is serialized to binary BONJSON using `BONJSONWriter`

### Decoding Flow

1. User calls `decoder.decode(Type.self, from: data)`
2. `BONJSONReader` parses binary data into `BONJSONValue` intermediate representation
3. Type's `Decodable.init(from:)` extracts values from the intermediate representation

## Type Codes

Key type code ranges:
- `0x00-0x64`: Small positive integers (0-100) encoded directly
- `0x6d`: Null
- `0x6e-0x6f`: Boolean (false, true)
- `0x70-0x77`: Unsigned integers (1-8 bytes)
- `0x78-0x7f`: Signed integers (1-8 bytes)
- `0x80-0x8f`: Short strings (0-15 bytes, length in lower nibble)
- `0x99`: Array start
- `0x9a`: Object start
- `0x9b`: Container end
- `0x9c-0xff`: Small negative integers (-100 to -1)

## Length Field Encoding

Length fields use variable-width encoding with a continuation bit for string chunking:
- Single byte for lengths 0-127
- Multi-byte for larger values, using leading zero count for efficient decoding
- LSB indicates if more chunks follow (for chunked strings)

## Integer Encoding

Integers are encoded using the smallest representation:
1. Small int range (-100 to 100): Single byte type code encodes the value
2. Larger values: Type code indicates byte count, followed by little-endian bytes
3. Unsigned values try signed encoding when MSB allows (saves type code range)

## Float Encoding

Float encoding attempts smallest lossless representation:
1. If value is a whole number, encode as integer
2. Try float32 if no precision loss
3. Fall back to float64

## String Encoding

- Short strings (0-15 bytes): Type code encodes length, followed by UTF-8 bytes
- Long strings: Type code `0x68`, followed by chunked length-prefixed UTF-8 data
- Each chunk validated as complete UTF-8 (per spec security requirement)

## Security Features

Per the BONJSON specification:
- Duplicate object keys are rejected during decoding
- Invalid UTF-8 is rejected
- NaN and infinity values throw errors (configurable via strategy)
- Container depth is limited (default 200)

## Usage Example

```swift
import BONJSON

struct Person: Codable {
    var name: String
    var age: Int
}

// Encoding
let encoder = BONJSONEncoder()
let person = Person(name: "Alice", age: 30)
let data = try encoder.encode(person)

// Decoding
let decoder = BONJSONDecoder()
let decoded = try decoder.decode(Person.self, from: data)
```

## Configuration Strategies

Both encoder and decoder support strategies matching `JSONEncoder`/`JSONDecoder`:

- **Date encoding/decoding**: `.secondsSince1970`, `.millisecondsSince1970`, `.iso8601`, `.formatted()`, `.custom()`
- **Data encoding/decoding**: `.base64`, `.custom()`
- **Key encoding/decoding**: `.useDefaultKeys`, `.convertToSnakeCase`/`.convertFromSnakeCase`, `.custom()`
- **Non-conforming float**: `.throw`, `.convertToString()`/`.convertFromString()`

## Testing

Run tests with:
```bash
swift test
```

Tests cover:
- Round-trip encoding/decoding for all primitive types
- Container types (arrays, objects)
- Special types (Date, Data, URL)
- Edge cases (empty containers, max depth, large strings)
- Error handling (type mismatches, duplicate keys)

## Build Commands

```bash
swift build        # Build the library
swift test         # Run all tests
swift build -c release  # Build optimized release version
```
