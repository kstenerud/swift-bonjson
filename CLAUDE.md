# Swift BONJSON Library

## Overview

This is a Swift library implementing a BONJSON codec - a binary drop-in replacement for JSON. It provides `BONJSONEncoder` and `BONJSONDecoder` classes that work exactly like Apple's `JSONEncoder` and `JSONDecoder`.

BONJSON is a binary format offering 1:1 JSON compatibility with faster processing and enhanced security. It maintains the same type support as JSON: strings, numbers, arrays, objects, booleans, and null.

## Architecture

This library uses two different approaches optimized for their respective tasks:

- **Encoding**: Uses C buffer-based API for direct memory writes, with Swift managing buffer growth
- **Decoding**: Uses C position-map API for single-pass scanning, building a map of all values for random access

### Source Files

- **Sources/CKSBonjson/**: C library providing low-level BONJSON encoding/decoding
  - `KSBONJSONEncoder.c/h`: Dual API - buffer-based (new) and callback-based (legacy)
  - `KSBONJSONDecoder.c/h`: Dual API - position-map (new) and callback-based (legacy)
  - `KSBONJSONCommon.h`: Type codes and shared constants
  - `include/CKSBonjson.h`: Umbrella header for Swift import

- **Sources/BONJSON/BONJSONEncoder.swift**: Public encoder API matching `JSONEncoder` interface
  - Uses `_BufferEncoderState` with `KSBONJSONBufferEncodeContext` for direct buffer writes
  - Swift manages buffer growth, C writes directly to buffer
  - Container finalization happens when new sibling starts (due to Encoder protocol design)

- **Sources/BONJSON/BONJSONDecoder.swift**: Public decoder API matching `JSONDecoder` interface
  - Uses `_PositionMap` wrapping `KSBONJSONMapContext` for single-pass scanning
  - Builds map of all values with pre-decoded primitives (int/float stored directly)
  - Uses precomputed subtree sizes and next-sibling indices for O(1) per-step child access
  - Strings stored as offset/length pairs, created on demand

### Encoding Flow

1. User calls `encoder.encode(value)`
2. `_BufferEncoderState` creates a Swift buffer and C context pointing to it
3. Value's `Encodable.encode(to:)` calls container methods
4. Container methods call C buffer functions (`ksbonjson_encodeToBuffer_*`)
5. Swift checks capacity before each write, grows buffer if needed via `ksbonjson_encodeToBuffer_setBuffer`
6. Container finalization is deferred until next sibling or parent completion

### Decoding Flow

1. User calls `decoder.decode(Type.self, from: data)`
2. `_PositionMap` copies data to stable storage, allocates entry buffer
3. Single C scan (`ksbonjson_map_scan`) builds map of all entries
4. Swift computes subtree sizes and next-sibling indices for fast child access
5. Decoder containers use the map for random access:
   - Primitives: read pre-decoded value directly from entry
   - Strings: create String from offset/length in original data
   - Containers: navigate via precomputed indices

### Position Map Entry Types

The C `KSBONJSONMapEntry` stores decoded values inline:
- `KSBONJSON_TYPE_NULL`, `_FALSE`, `_TRUE`: No data needed
- `KSBONJSON_TYPE_INT`: `int64_t` value stored directly
- `KSBONJSON_TYPE_UINT`: `uint64_t` value stored directly
- `KSBONJSON_TYPE_FLOAT`: `double` value stored directly
- `KSBONJSON_TYPE_BIGNUMBER`: significand/exponent/sign stored
- `KSBONJSON_TYPE_STRING`: offset and length into original input
- `KSBONJSON_TYPE_ARRAY`, `_OBJECT`: firstChild index and count

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
swift test --filter Benchmark
```

### Size Comparison (BONJSON vs JSON)
- Booleans: 5.4x smaller (82% savings)
- Small integers (0-99): 2.9x smaller (65% savings)
- Large integers: 2x smaller (50% savings)
- Doubles: 1.3x smaller (24% savings)
- Strings: 1.3x smaller (25% savings)
- Objects: 1.3x smaller (24% savings)

### Speed Comparison
BONJSON is currently slower than Apple's JSON:
- Encode: ~6-10x slower
- Decode: ~20-60x slower

### Performance Limitations

The current architecture trades speed for correctness and simplicity:

1. **Position map overhead**: Building the map scans all data upfront, even if only part is needed
2. **Child access is O(n)**: Accessing the n-th child requires iterating through n-1 siblings
3. **Swift Codable overhead**: Protocol machinery creates many intermediate objects
4. **String allocation**: Each string decode creates a new String object

Apple's JSONDecoder uses highly optimized C++ with custom Swift bridging. Matching that performance would require:
- Lazy parsing without upfront scanning
- Direct struct creation bypassing Codable
- Unsafe memory operations

### Future Optimization Opportunities

1. **Lazy position map**: Only scan what's needed during decode
2. **Streaming decoder**: Avoid position map entirely for sequential access
3. **Specialized decoders**: Skip Codable overhead for known types
4. **String interning**: Reuse String objects for repeated keys
