# Swift BONJSON Library

## Overview

This is a Swift library implementing a BONJSON codec - a binary drop-in replacement for JSON. It provides `BONJSONEncoder` and `BONJSONDecoder` classes that work exactly like Apple's `JSONEncoder` and `JSONDecoder`.

BONJSON is a binary format offering 1:1 JSON compatibility with faster processing and enhanced security. It maintains the same type support as JSON: strings, numbers, arrays, objects, booleans, and null.

The BONJSON spec is available at https://raw.githubusercontent.com/kstenerud/bonjson/refs/heads/main/bonjson.md

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

This library implements comprehensive security features as mandated by the BONJSON specification.
All security checks default to the most secure behavior (reject invalid data).

### UTF-8 Validation (Decoder)

The decoder validates UTF-8 strings by default, rejecting:
- Malformed sequences (invalid continuation bytes)
- Overlong encodings (using more bytes than necessary)
- Surrogates (U+D800-U+DFFF, reserved for UTF-16)
- Codepoints above U+10FFFF

Configure via `unicodeDecodingStrategy`:
- `.reject` (default): Throw error on invalid UTF-8
- `.replace`: Replace invalid sequences with U+FFFD (REPLACEMENT CHARACTER)
- `.delete`: Remove invalid bytes from strings

Note: The `.ignore` mode from the BONJSON spec is not supported because Swift's `String`
type only accepts valid UTF-8. Use `.replace` as a permissive alternative.

### NUL Character Handling

NUL characters (U+0000) are a common source of security vulnerabilities and are rejected
by default in both encoding and decoding.

**Decoder** (`nulDecodingStrategy`):
- `.reject` (default): Throw error on NUL in strings
- `.allow`: Allow NUL characters (use only when legitimately needed)

**Encoder** (`nulEncodingStrategy`):
- `.reject` (default): Throw error on NUL in strings
- `.allow`: Allow encoding strings with NUL characters

### Duplicate Object Keys

The BONJSON spec characterizes duplicate keys as "extremely dangerous" and "actively
exploited in the wild." They are rejected by default.

Configure via `duplicateKeyDecodingStrategy`:
- `.reject` (default): Throw error on duplicate keys
- `.keepFirst`: Keep first occurrence, ignore subsequent duplicates (spec: "dangerous")
- `.keepLast`: Replace earlier values with later duplicates (spec: "extremely dangerous")

Note: When duplicate detection is enabled (`.reject` strategy), objects are limited to
256 keys. Objects with more keys will throw a `tooManyKeys` error. This limit does not
apply when using `.keepFirst` or `.keepLast` strategies.

### NaN and Infinity Handling

NaN and infinity are valid IEEE 754 floating-point values but cannot be represented in JSON.
The BONJSON spec provides three options for handling these values, all supported by this library.

**Encoder** (`nonConformingFloatEncodingStrategy`):
- `.throw` (default): Throw error when encoding NaN or infinity (JSON-compatible)
- `.allow`: Encode as IEEE 754 float values directly (warning: not JSON-convertible)
- `.convertToString(positiveInfinity:negativeInfinity:nan:)`: Encode as string representations

**Decoder** (`nonConformingFloatDecodingStrategy`):
- `.throw` (default): Throw error when decoding NaN or infinity values
- `.allow`: Allow NaN and infinity values to pass through
- `.convertFromString(positiveInfinity:negativeInfinity:nan:)`: Decode matching strings as floats

Note: Using `.allow` creates BONJSON data that cannot be converted to JSON. The `.convertToString`
and `.convertFromString` strategies maintain JSON compatibility by using string representations.

### Other Security Limits

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

**BONJSON decoder is now 2.56x FASTER than Apple's JSON decoder!**

| Metric | BONJSON | JSON | Ratio |
|--------|---------|------|-------|
| Decode 1000 objects | 490 µs | 1.26 ms | 0.39x (BONJSON 2.56x faster) |
| Throughput | 53 MB/s | 35 MB/s | 1.5x faster |

Encoder performance is roughly equal to JSON.

### Optimization History

#### Early Phase: Swift-Level Improvements

Applied fundamental Swift optimizations (prior to profiling):
- `@inline(__always)` on hot paths
- `ContiguousArray<T>` for cache locality
- Precomputed next-sibling indices for O(1) child navigation
- O(1) sequential array access in `UnkeyedDecodingContainer`
- String caching to avoid duplicate String objects

#### Phase 1: Batch Decode for Numeric Arrays

Added C batch decode functions to decode entire arrays in one call:

| Type | Before | After | Improvement |
|------|--------|-------|-------------|
| 10,000 ints | 1.61 ms | 109 µs | **16x faster** |
| 10,000 doubles | 1.59 ms | 102 µs | **15.6x faster** |

#### Phase 3: Batch Decode for String Arrays

Added C function to return string offsets/lengths in batch, then Swift creates strings in one pass:

| Type | Before | After | Improvement |
|------|--------|-------|-------------|
| 10,000 strings | 2.17 ms | 177 µs | **12x faster** |
| 1,000 strings | 257 µs | 50 µs | **5x faster** |

#### Phase 2: Lazy Key Cache + Linear Search

Profiling revealed Swift Codable overhead was 94% of decode time. Key optimizations:

1. **Lazy allKeys**: Only build when accessed (rare)
2. **Lazy keyCache**: Only build dictionary on first key lookup
3. **Linear search for small objects (≤8 fields)**: Direct byte comparison avoids dictionary overhead

| Metric | Before Phase 2 | After Phase 2 | Improvement |
|--------|----------------|---------------|-------------|
| Total decode | 1.35 ms | 495 µs | **2.7x faster** |
| Per object overhead | 1.25 µs | 412 ns | **3x faster** |
| Throughput | 20 MB/s | 53 MB/s | **2.6x faster** |
| vs JSON | Equal (1.02x) | 2.4x faster | **Crossed the threshold!** |

#### Phase 4: Increased Linear Search Threshold

Increased threshold from 8 to 12 fields. Linear search is 1.5x faster than dictionary.

| Metric | Before | After | Improvement |
|--------|--------|-------|-------------|
| 10-field objects | 1.66 ms | 865 µs | **1.9x faster** |
| vs JSON | 2.4x faster | 2.56x faster | **+7%** |

### Current Performance Characteristics

- **C position map**: 320 MB/s, ~13ns per entry (18% of decode time)
- **Swift Codable layer**: ~82% of decode time
- **Per-object overhead**: ~280 ns (for 1-field objects)
- **Per-field overhead**: ~153 ns
- **Primitive array decode** (all batched):
  - `[Int]`, `[Double]`, `[Bool]`: ~10 ns per element
  - `[String]`: ~17-50 ns per element

### Optional Future Optimizations

If even more performance is needed:
1. **Container pooling**: Reuse `_LazyKeyState` instances
2. **Code generation macro**: Bypass Codable for annotated types
3. **SIMD scanning**: Vectorized byte detection
