# Swift BONJSON Library

## Overview

This is a Swift library implementing a BONJSON codec - a binary drop-in replacement for JSON. It provides `BONJSONEncoder` and `BONJSONDecoder` classes that work exactly like Apple's `JSONEncoder` and `JSONDecoder`.

BONJSON is a binary format offering 1:1 JSON compatibility with faster processing and enhanced security. It maintains the same type support as JSON: strings, numbers, arrays, objects, booleans, and null.

## Architecture

This library uses a streaming architecture that avoids intermediate representations:
- **Encoding**: Calls the C ksbonjson library directly during encoding, streaming bytes to output
- **Decoding**: Uses cursor-based parsing, reading binary data directly without building a tree

### Source Files

- **Sources/CKSBonjson/**: C library providing low-level BONJSON encoding functions
  - `KSBONJSONEncoder.c/h`: C encoder API
  - `KSBONJSONDecoder.c/h`: C decoder API (used for reference, not directly called)
  - `KSBONJSONCommon.h`: Type codes and shared constants
  - `include/CKSBonjson.h`: Umbrella header for Swift import

- **Sources/BONJSON/BONJSONEncoder.swift**: Public encoder API matching `JSONEncoder` interface
  - Implements Swift's `Encoder` protocol with keyed, unkeyed, and single-value containers
  - Uses `_EncoderState` class to hold C context and output buffer
  - Tracks container depth for automatic container closing
  - Streams directly to C library functions (`ksbonjson_addString`, `ksbonjson_beginObject`, etc.)

- **Sources/BONJSON/BONJSONDecoder.swift**: Public decoder API matching `JSONDecoder` interface
  - Uses `_DecodingCursor` for position-based binary parsing
  - Keyed containers scan object once, cache key positions for random access
  - Unkeyed containers scan array once, cache element positions
  - No intermediate `BONJSONValue` representation - decodes directly from bytes

### Encoding Flow

1. User calls `encoder.encode(value)`
2. `_EncoderState` initializes C encoding context with a callback that appends to buffer
3. Value's `Encodable.encode(to:)` calls container methods
4. Container methods call C library functions directly (e.g., `ksbonjson_addString`)
5. Container depth tracking ensures proper closing of nested containers
6. `ksbonjson_endEncode` finalizes the output

### Decoding Flow

1. User calls `decoder.decode(Type.self, from: data)`
2. `_DecodingCursor` wraps the data for position-based reading
3. Type's `Decodable.init(from:)` requests containers
4. Containers scan their contents once, caching positions:
   - Keyed containers build `[String: Int]` mapping keys to value positions
   - Unkeyed containers build `[Int]` array of element positions
5. Subsequent access uses cached positions for direct reads

## Type Codes

Key type code ranges (defined in `KSBONJSONCommon.h`):
- `0x00-0x64`: Small positive integers (0-100) encoded directly
- `0x68`: Long string (followed by length-prefixed chunks)
- `0x69`: Big number (for arbitrary precision decimals)
- `0x6a-0x6c`: Floats (16-bit, 32-bit, 64-bit)
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
- Format: `payload = (length << 1) | continuation_flag`
- Trailing zeros in first byte indicate total byte count
- Single byte encodes lengths 0-127 (after bit manipulation)
- Multi-byte for larger values
- Continuation flag (bit 0 of payload) indicates if more chunks follow

## Integer Encoding

Integers are encoded using the smallest representation:
1. Small int range (-100 to 100): Single byte type code encodes the value
2. Larger values: Type code indicates byte count, followed by little-endian bytes
3. Unsigned values try signed encoding when MSB allows (saves type code range)

## Float Encoding

Float encoding attempts smallest lossless representation:
1. If value is a whole number, encode as integer
2. Try bfloat16 if no precision loss
3. Try float32 if no precision loss
4. Fall back to float64

## String Encoding

- Short strings (0-15 bytes): Type code encodes length, followed by UTF-8 bytes
- Long strings: Type code `0x68`, followed by length-field-prefixed UTF-8 data
- Length field includes continuation bit for chunked encoding

## Big Number Format

Big numbers use a header byte followed by data:
- Header: `SSSSS EE N` where:
  - N (bit 0): sign (0 = positive, 1 = negative)
  - EE (bits 1-2): exponent length (0-3 bytes)
  - SSSSS (bits 3-7): significand length (0-31 bytes)
- Followed by exponent bytes (little-endian signed)
- Followed by significand bytes (little-endian unsigned)

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
- Edge cases (empty containers, large strings)
- Error handling (type mismatches)

## Build Commands

```bash
swift build        # Build the library
swift test         # Run all tests
swift build -c release  # Build optimized release version
```

## Benchmarks

Run benchmarks with:
```bash
swift run bonjson-benchmark
```

Current performance vs Apple's JSON:
- BONJSON produces 24-82% smaller output depending on data type
- Booleans: 5.4x smaller
- Small integers: 2.9x smaller
- Large integers: 2x smaller
- Strings: 1.3x smaller
- Objects: 1.3x smaller

Speed is currently slower than Apple's JSON due to:
- C library callback overhead for each encoded value
- Container scanning overhead in decoder for position caching
- Swift/C bridge overhead
