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
6. Container end markers (0xFE) are written when containers are closed

### Decoding Flow

1. User calls `decoder.decode(Type.self, from: data)`
2. `_PositionMap` copies data to stable storage, allocates entry buffer
3. Single C scan (`ksbonjson_map_scan`) builds map of all entries
4. Swift builds next-sibling indices from precomputed subtree sizes for fast child access
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
- All entries: `subtreeSize` (precomputed during scan for O(1) sibling navigation)

## Type Codes

Key type code ranges (defined in `KSBONJSONCommon.h`):
- `0x00-0x64`: Small integers (0 to 100), value = type_code directly
- `0x65-0xA7`: Short strings (0-66 bytes, length = type_code - 0x65)
- `0xA8-0xAB`: Unsigned integers (CPU-native sizes: 1, 2, 4, 8 bytes)
- `0xAC-0xAF`: Signed integers (CPU-native sizes: 1, 2, 4, 8 bytes)
- `0xB0`: Float32
- `0xB1`: Float64
- `0xB2`: Big number (zigzag LEB128 exponent + zigzag LEB128 signed_length + LE magnitude bytes)
- `0xB3`: Null
- `0xB4`: False
- `0xB5`: True
- `0xB6`: Container end marker
- `0xB7`: Array start (delimiter-terminated with 0xB6)
- `0xB8`: Object start (delimiter-terminated with 0xB6)
- `0xB9`: Record definition (key strings terminated with 0xB6)
- `0xBA`: Record instance (ULEB128 def_index + values terminated with 0xB6)
- `0xBB-0xF4`: Reserved
- `0xF5-0xFE`: Typed arrays (element type + ULEB128 count + raw LE data)
- `0xFF`: Long string (FF-terminated: 0xFF + data + 0xFF)

Type detection ranges:
- Small integers: `type_code <= 0x64`
- Short strings: `type_code >= 0x65 && type_code <= 0xA7`
- Typed arrays: `type_code >= 0xF5 && type_code <= 0xFE`

## Container Encoding (Delimiter-Terminated)

Containers (arrays and objects) use a start marker and end delimiter:
- Format: `[type_code] [elements...] [0xB6]`
- Arrays: `0xB7` + values + `0xB6`
- Objects: `0xB8` + key-value pairs + `0xB6`

There is no length prefix or chunking; the decoder scans until it encounters the end marker.

## Integer Encoding

Integers are encoded using the smallest representation:
1. Small int range (0 to 100): Single byte type code, value = type_code directly
   - Type code 0x00 = 0, 0x64 = 100
2. Larger values: Type code indicates sign and byte count, followed by little-endian bytes
   - Unsigned: 0xA8-0xAB (CPU-native sizes: 1, 2, 4, 8 bytes)
   - Signed: 0xAC-0xAF (CPU-native sizes: 1, 2, 4, 8 bytes)
3. Values are rounded up to the next CPU-native size (e.g. a 3-byte value uses 4 bytes)

## Float Encoding

Float encoding attempts smallest lossless representation:
1. If value is a whole number, encode as integer
2. Try float32 if no precision loss
3. Fall back to float64

Note: bfloat16 is no longer supported.

## String Encoding

- Short strings (0-66 bytes): Type codes 0x65-0xA7 encode length (length = type_code - 0x65), followed by UTF-8 bytes
- Long strings: 0xFF + UTF-8 data + 0xFF (FF-terminated, no chunking)

## Big Number Format

Big numbers use zigzag LEB128 metadata and little-endian magnitude bytes:
- Format: `0xB2` + zigzag_leb128(exponent) + zigzag_leb128(signed_length) + magnitude_bytes
- The exponent is a zigzag LEB128 signed integer (base-10 exponent)
- The signed_length is a zigzag LEB128 signed integer encoding both sign and byte count:
  positive N = positive significand with N magnitude bytes, negative -N = negative significand
  with N magnitude bytes, zero = significand is zero (no magnitude bytes)
- The magnitude_bytes are an unsigned integer in little-endian byte order (abs(signed_length) bytes)
- Magnitude must be normalized: the last byte (most significant) must be non-zero
- Value = sign(signed_length) x magnitude x 10^exponent

### Swift Decimal Support

Swift's `Decimal` type is used for encoding and decoding BigNumber values:

**Encoding**: When encoding a `Decimal` value, it is automatically encoded as a BONJSON BigNumber,
preserving precision that would be lost with Double conversion. Values with mantissa > 64 bits
(e.g., 2^64) are encoded by writing raw magnitude bytes directly from the Decimal's internal
mantissa words.

**Decoding**: When decoding a BigNumber to `Decimal`, the full precision is preserved within
implementation limits.

**Implementation Limits**:
- Significand: up to 19 decimal digits for roundtrip (limited by UInt64 internal storage)
- Exponent: -128 to 127 (limited by Swift Decimal's exponent range)

Values exceeding these limits can be decoded to Double (with precision loss), or presented as
strings using the `outOfRangeBigNumberDecodingStrategy = .stringify` option.

## Typed Arrays

Typed arrays encode homogeneous numeric arrays more compactly:
- Format: `type_code` + ULEB128(element_count) + raw LE element data
- Element types: uint8-64 (0xFE-0xFB), sint8-64 (0xFA-0xF7), float32 (0xF6), float64 (0xF5)
- No per-element type codes; all elements share the same type
- The decoder expands typed arrays into regular array entries in the position map, so the
  Swift Codable layer requires no changes

The Swift encoder automatically uses typed arrays for all numeric array types:
`[Int]`, `[Int64]`, `[Int32]`, `[Int16]`, `[Int8]`, `[UInt64]`, `[UInt]`, `[UInt32]`, `[UInt16]`,
`[UInt8]`, `[Double]`, `[Float]`. Bool arrays (`[Bool]`) use regular array encoding since booleans
aren't numeric typed arrays. Batch encoding works at all levels: root-level arrays, arrays inside
objects, and nested arrays.

## Records

Records provide compact encoding for repeated object schemas:
- Record definition: `0xB9` + key strings + `0xB6` (stored before root value)
- Record instance: `0xBA` + ULEB128(def_index) + values + `0xB6`
- The decoder expands record instances into regular object entries in the position map,
  so the Swift Codable layer requires no changes
- Maximum 256 record definitions per document

The Swift encoder auto-detects record encoding for root-level arrays of ≥2 same-schema objects.
Detection works by probing the first element's keys with a lightweight `_KeyCaptureEncoder`, then
encoding all elements as record instances. If any element's keys don't match the schema, encoding
falls back to regular array-of-objects format by resetting the buffer position and re-encoding.

Record definitions are written as raw bytes directly to the buffer (bypassing C container state)
because the C encoder's container-aware string functions would corrupt internal state tracking.

The decoder handles records transparently — the position map retry logic doubles the entry buffer
when `KSBONJSON_DECODE_MAP_FULL` is returned, since record instances expand to more entries than
the compact wire format suggests.

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

When using `.convertFromString` on the decoder, NaN/Infinity float values encountered as BONJSON
floats are automatically presented as their string representation when decoded as `String.Type`.
This allows decode-only stringify behavior without separate encoding.

### BigNumber Resource Limits

Configurable limits for BigNumber values (decoder only):

| Property | Default | Description |
|----------|---------|-------------|
| `maxBigNumberExponent` | nil (no limit) | Maximum absolute exponent value |
| `maxBigNumberMagnitude` | nil (no limit) | Maximum magnitude in bytes |

When limits are exceeded, behavior depends on `outOfRangeBigNumberDecodingStrategy`:
- `.throw` (default): Throw error
- `.stringify`: Present the value as a string when decoded as `String.Type`

### Unicode Normalization

Configure via `unicodeNormalizationStrategy`:
- `.none` (default): No normalization, strings returned as-is
- `.nfc`: Apply NFC (Canonical Decomposition followed by Canonical Composition)

When NFC normalization is active with `.reject` duplicate key strategy, duplicate detection
occurs after normalization so that NFC-equivalent keys are correctly detected as duplicates.

Note: Swift's `String` type internally normalizes Unicode, so the `.none` strategy cannot
distinguish differently-encoded forms of the same character (e.g., precomposed vs decomposed)
at the String comparison level. This is a fundamental limitation of Swift's String type.

### Resource Limits

All limits default to BONJSON spec-recommended values:

| Property | Default | Description |
|----------|---------|-------------|
| `maxDepth` | 512 | Maximum container nesting depth |
| `maxStringLength` | 10,000,000 | Maximum string length in bytes |
| `maxContainerSize` | 1,000,000 | Maximum elements in a container |
| `maxDocumentSize` | 2,000,000,000 | Maximum document size in bytes |

All limits are configurable on both `BONJSONEncoder` and `BONJSONDecoder`.

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

### Unit Tests (BONJSONTests.swift)

Tests cover:
- Round-trip encoding/decoding for all primitive types
- Container types (arrays, objects)
- Special types (Date, Data, URL)
- Edge cases (empty containers, large strings)
- Error handling (type mismatches)

### Conformance Tests (ConformanceTests.swift)

Universal cross-implementation tests from `../bonjson/tests/`. These verify correct BONJSON behavior across all implementations.

The conformance test runner:
- Parses test specification JSON files (type `bonjson-test`)
- Handles test types: `encode`, `decode`, `roundtrip`, `encode_error`, `decode_error`
- Supports `$number` marker for special values (NaN, Infinity, hex floats, big integers)
- Maps library errors to standardized error types
- Supports options: `allow_nul`, `allow_nan_infinity`

**Important**: The `runner/` directory contains tests to validate the test runner itself. See `Tests/README.md`.

Run conformance tests only:
```bash
swift test --filter Conformance
```

**Supported test options:**
- `allow_nul`, `allow_nan_infinity`, `allow_trailing_bytes`
- `max_depth`, `max_container_size`, `max_string_length`, `max_document_size`
- `nan_infinity_behavior`: "allow", "stringify" (NaN/Inf floats presented as strings when decoded as String)
- `duplicate_key`: "keep_first", "keep_last"
- `invalid_utf8`: "replace", "delete"
- `max_bignumber_exponent`, `max_bignumber_magnitude`
- `out_of_range`: "stringify" (out-of-range BigNumbers presented as strings)
- `unicode_normalization`: "none", "nfc"

**Supported capabilities:**
- `int64`, `encode_nul_rejection`, `nan_infinity_stringify`
- `bignumber_resource_limits`, `out_of_range_stringify`, `unicode_normalization`
- `typed_arrays`, `records`

**Skipped tests (29 total):**
- 15 `arbitrary_precision_bignumber` tests (C layer stores UInt64 significand)
- 2 `signaling_nan` tests (Swift doesn't distinguish sNaN vs qNaN)
- 2 `raw_string_bytes` tests (Swift String requires valid UTF-8)
- 8 BigNumber exponent tests outside -128 to 127 (exceeds Swift Decimal range)
- 2 chunked string tests (chunking removed in new wire format)

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

**BONJSON decoder is 1.5-2.2x faster than Apple's JSON decoder** across different workloads.

| Metric | BONJSON | JSON | Speedup |
|--------|---------|------|---------|
| Decode 1000 small objects | 414 µs | 823 µs | 1.99x |
| Decode 500 medium objects | 941 µs | 1.42 ms | 1.51x |
| Decode 1000 long strings | 155 µs | 342 µs | 2.20x |
| Decode 500 string-heavy objects | 516 µs | 766 µs | 1.48x |

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

#### Phase 5: SIMD String Scanning

Added platform-specific SIMD (NEON/SSE2) with scalar fallback in `KSBONJSONSimd.h`:
- `ksbonjson_simd_findByte()` for 0xFF terminator search in long strings
- `ksbonjson_simd_containsByte()` for NUL byte detection
- `ksbonjson_simd_isAllAscii()` for UTF-8 validation fast path

No measurable impact on current benchmarks (strings too short). Benefits large strings/documents.

#### Phase 6: Precomputed Subtree Sizes in C

Moved subtree size computation from Swift post-processing into C scan pass:
- Added `subtreeSize` field to `KSBONJSONMapEntry`, set during scan at zero extra cost
- Swift post-processing reduced from reverse-order walk to simple `i + subtreeSize` loop
- Recursive `mapSubtreeSize()` replaced with inline lookup

| Metric | Before | After | Improvement |
|--------|--------|-------|-------------|
| Decode 500 medium objects | 1.42x vs JSON | 1.51x vs JSON | **+6%** |
| Decode 500 string-heavy | 1.39x vs JSON | 1.48x vs JSON | **+6%** |

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
