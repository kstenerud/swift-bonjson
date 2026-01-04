# Swift Codable Architecture and Optimal BONJSON Implementation

## Table of Contents

1. [The Swift Encoder/Decoder Protocol API](#1-the-swift-encoderdecoder-protocol-api)
2. [Apple's JSONEncoder/JSONDecoder Implementation](#2-apples-jsonencoderjsondecoder-implementation)
3. [Language Choice Analysis for Codec Implementation](#3-language-choice-analysis-for-codec-implementation)
4. [Proposed BONJSON Architecture](#4-proposed-bonjson-architecture)
5. [Deep Dive: How Apple Achieves JSON Performance](#5-deep-dive-how-apple-achieves-json-performance)
6. [Exceeding Apple's Performance: Architectural Options](#6-exceeding-apples-performance-architectural-options)

---

## 1. The Swift Encoder/Decoder Protocol API

### 1.1 Core Protocols

Swift's Codable system is built on a hierarchy of protocols that must be implemented by any compliant codec:

#### The `Encoder` Protocol

```swift
public protocol Encoder {
    /// The path of coding keys taken to get to this point in encoding.
    var codingPath: [CodingKey] { get }

    /// Any contextual information set by the user for encoding.
    var userInfo: [CodingUserInfoKey: Any] { get }

    /// Returns an encoding container appropriate for holding multiple values
    /// keyed by the given key type.
    func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key>

    /// Returns an encoding container appropriate for holding multiple unkeyed values.
    func unkeyedContainer() -> UnkeyedEncodingContainer

    /// Returns an encoding container appropriate for holding a single primitive value.
    func singleValueContainer() -> SingleValueEncodingContainer
}
```

#### The `Decoder` Protocol

```swift
public protocol Decoder {
    /// The path of coding keys taken to get to this point in decoding.
    var codingPath: [CodingKey] { get }

    /// Any contextual information set by the user for decoding.
    var userInfo: [CodingUserInfoKey: Any] { get }

    /// Returns the data stored in this decoder as represented in a container
    /// keyed by the given key type.
    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key>

    /// Returns the data stored in this decoder as represented in an unkeyed container.
    func unkeyedContainer() throws -> UnkeyedDecodingContainer

    /// Returns the data stored in this decoder as represented in a container
    /// appropriate for holding a single primitive value.
    func singleValueContainer() throws -> SingleValueDecodingContainer
}
```

### 1.2 Encoding Container Protocols

#### `KeyedEncodingContainerProtocol`

This protocol handles dictionary-like structures where values are accessed by keys:

```swift
public protocol KeyedEncodingContainerProtocol {
    associatedtype Key: CodingKey

    var codingPath: [CodingKey] { get }

    // Primitive encoding methods (one for each type)
    mutating func encodeNil(forKey key: Key) throws
    mutating func encode(_ value: Bool, forKey key: Key) throws
    mutating func encode(_ value: String, forKey key: Key) throws
    mutating func encode(_ value: Double, forKey key: Key) throws
    mutating func encode(_ value: Float, forKey key: Key) throws
    mutating func encode(_ value: Int, forKey key: Key) throws
    mutating func encode(_ value: Int8, forKey key: Key) throws
    mutating func encode(_ value: Int16, forKey key: Key) throws
    mutating func encode(_ value: Int32, forKey key: Key) throws
    mutating func encode(_ value: Int64, forKey key: Key) throws
    mutating func encode(_ value: UInt, forKey key: Key) throws
    mutating func encode(_ value: UInt8, forKey key: Key) throws
    mutating func encode(_ value: UInt16, forKey key: Key) throws
    mutating func encode(_ value: UInt32, forKey key: Key) throws
    mutating func encode(_ value: UInt64, forKey key: Key) throws
    mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws

    // Conditional encoding (encodes nil if value is nil)
    mutating func encodeIfPresent(_ value: Bool?, forKey key: Key) throws
    // ... (one for each type)

    // Nested containers
    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy keyType: NestedKey.Type,
        forKey key: Key
    ) -> KeyedEncodingContainer<NestedKey>

    mutating func nestedUnkeyedContainer(forKey key: Key) -> UnkeyedEncodingContainer

    // Super encoder for inheritance hierarchies
    mutating func superEncoder() -> Encoder
    mutating func superEncoder(forKey key: Key) -> Encoder
}
```

#### `UnkeyedEncodingContainer`

Handles array-like sequences:

```swift
public protocol UnkeyedEncodingContainer {
    var codingPath: [CodingKey] { get }
    var count: Int { get }

    // One encode method per primitive type
    mutating func encodeNil() throws
    mutating func encode(_ value: Bool) throws
    mutating func encode(_ value: String) throws
    // ... (all primitive types)
    mutating func encode<T: Encodable>(_ value: T) throws

    // Nested containers
    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy keyType: NestedKey.Type
    ) -> KeyedEncodingContainer<NestedKey>

    mutating func nestedUnkeyedContainer() -> UnkeyedEncodingContainer
    mutating func superEncoder() -> Encoder
}
```

#### `SingleValueEncodingContainer`

Handles primitive top-level values:

```swift
public protocol SingleValueEncodingContainer {
    var codingPath: [CodingKey] { get }

    mutating func encodeNil() throws
    mutating func encode(_ value: Bool) throws
    mutating func encode(_ value: String) throws
    // ... (all primitive types)
    mutating func encode<T: Encodable>(_ value: T) throws
}
```

### 1.3 Decoding Container Protocols

The decoding containers mirror the encoding containers but with `decode` methods:

#### `KeyedDecodingContainerProtocol`

```swift
public protocol KeyedDecodingContainerProtocol {
    associatedtype Key: CodingKey

    var codingPath: [CodingKey] { get }
    var allKeys: [Key] { get }

    func contains(_ key: Key) -> Bool

    // Decode methods for each type
    func decodeNil(forKey key: Key) throws -> Bool
    func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool
    func decode(_ type: String.Type, forKey key: Key) throws -> String
    // ... (all primitive types)
    func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T

    // Conditional decoding (returns nil if key doesn't exist)
    func decodeIfPresent(_ type: Bool.Type, forKey key: Key) throws -> Bool?
    // ... (all types)

    // Nested containers
    func nestedContainer<NestedKey: CodingKey>(
        keyedBy type: NestedKey.Type,
        forKey key: Key
    ) throws -> KeyedDecodingContainer<NestedKey>

    func nestedUnkeyedContainer(forKey key: Key) throws -> UnkeyedDecodingContainer

    func superDecoder() throws -> Decoder
    func superDecoder(forKey key: Key) throws -> Decoder
}
```

#### `UnkeyedDecodingContainer`

```swift
public protocol UnkeyedDecodingContainer {
    var codingPath: [CodingKey] { get }
    var count: Int? { get }  // nil if count is unknown
    var isAtEnd: Bool { get }
    var currentIndex: Int { get }

    // Decode methods advance the current index
    mutating func decodeNil() throws -> Bool
    mutating func decode(_ type: Bool.Type) throws -> Bool
    // ... (all types)

    // Nested containers
    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy type: NestedKey.Type
    ) throws -> KeyedDecodingContainer<NestedKey>

    mutating func nestedUnkeyedContainer() throws -> UnkeyedDecodingContainer
    mutating func superDecoder() throws -> Decoder
}
```

### 1.4 Critical Implementation Challenges

#### Challenge 1: Container Finalization

**The Problem**: The Encoder protocol provides no callback for when a container is finished. When `encode(to:)` returns, the encoder doesn't know which containers need closing.

```swift
struct Person: Encodable {
    var name: String
    var age: Int

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(age, forKey: .age)
        // Function returns - encoder never gets notified that container is done!
    }
}
```

**Implications for streaming encoders**: A streaming encoder that writes directly to output cannot know when to write the container-end marker. This is why Apple's implementation uses an intermediate representation.

#### Challenge 2: Random Access Decoding

**The Problem**: `KeyedDecodingContainer` allows random-access by key. Decoders must support accessing any key at any time:

```swift
func decode(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    // These can be called in ANY order
    let z = try container.decode(Int.self, forKey: .z)
    let a = try container.decode(Int.self, forKey: .a)
    let m = try container.decode(Int.self, forKey: .m)
}
```

**Implications for streaming decoders**: A streaming decoder must either:
1. Build an intermediate representation (parse once, access randomly)
2. Pre-scan and build a position index (scan once, seek for access)
3. Re-parse on each access (poor performance)

#### Challenge 3: Nested Container Creation

**The Problem**: Nested containers can be created without immediately using them, and the parent container continues to be usable:

```swift
var container = encoder.unkeyedContainer()
try container.encode(1)
var nested = container.nestedUnkeyedContainer()  // Creates nested array
try container.encode(2)  // Back to parent!
try nested.encode(3)     // Now writes to nested
try container.encode(4)  // Back to parent again!
```

**Implications**: The encoder must track container depth and handle interleaved writes correctly.

---

## 2. Apple's JSONEncoder/JSONDecoder Implementation

### 2.1 Historical Evolution

Apple's JSON codec has evolved through three distinct implementations:

| Era | Implementation | Language | Notes |
|-----|---------------|----------|-------|
| Pre-Swift | NSJSONSerialization | Objective-C/CoreFoundation | C-based parsing, NSObject output |
| Swift 4-5.8 | swift-corelibs-foundation | Swift + NSJSONSerialization | Swift Codable layer over ObjC parser |
| Swift 5.9+ | swift-foundation | Pure Swift | Complete rewrite, no ObjC dependency |

### 2.2 Modern Implementation Architecture (swift-foundation)

The modern implementation in [swift-foundation](https://github.com/swiftlang/swift-foundation/blob/main/Sources/FoundationEssentials/JSON/JSONEncoder.swift) is structured into distinct layers:

```
┌─────────────────────────────────────────────────────────────────┐
│                     Public API Layer                             │
│  JSONEncoder / JSONDecoder                                       │
│  - Strategy configuration (date, data, key, float)               │
│  - Thread-safe property access via locks                         │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                  Protocol Implementation Layer                   │
│  __JSONEncoder / JSONDecoderImpl                                 │
│  - Implements Encoder/Decoder protocols                          │
│  - Container creation and management                             │
│  - Coding path tracking                                          │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                  Intermediate Representation Layer               │
│  JSONFuture (encoding) / JSONMap (decoding)                      │
│  - Defers actual work until necessary                            │
│  - Enables random access for decoding                            │
│  - Accumulates encoded values before serialization               │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                    Serialization Layer                           │
│  JSONWriter (encoding) / JSONScanner (decoding)                  │
│  - Writes bytes to buffer / parses bytes to JSONMap              │
│  - Performance-critical, heavily optimized                       │
└─────────────────────────────────────────────────────────────────┘
```

### 2.3 Encoding Implementation Details

#### The JSONFuture System

Apple's encoder doesn't write bytes immediately. Instead, it builds a tree of `JSONFuture` values:

```swift
enum JSONFuture {
    case value(JSONEncoderValue)
    case nestedArray(RefArray)
    case nestedObject(RefObject)

    final class RefArray { var values: [JSONFuture] }
    final class RefObject { var values: [(key: String, value: JSONFuture)] }
}
```

**Why this design?**

1. **Solves the finalization problem**: Container boundaries are implicit in the tree structure
2. **Enables key sorting**: Objects can be sorted before serialization
3. **Supports super-encoders**: Reference types allow shared mutation
4. **Lazy evaluation**: Conversion to bytes happens only at the end

#### The JSONWriter

The [JSONWriter](https://github.com/swiftlang/swift-foundation/blob/main/Sources/FoundationEssentials/JSON/JSONWriter.swift) is a simple, fast byte buffer:

```swift
struct JSONWriter {
    var bytes: [UInt8] = []

    @inline(__always)
    mutating func write(_ byte: UInt8) {
        bytes.append(byte)
    }

    @inline(__always)
    mutating func write(_ string: String) {
        bytes.append(contentsOf: string.utf8)
    }
}
```

**Performance optimizations**:
- `@inline(__always)` on hot paths
- Pre-computed escape tables for strings
- Direct byte array manipulation (no String intermediates)
- Hardcoded common indentation levels

### 2.4 Decoding Implementation Details

#### The JSONMap System

Rather than parsing JSON into Swift objects, the [JSONScanner](https://github.com/swiftlang/swift-foundation/blob/main/Sources/FoundationEssentials/JSON/JSONScanner.swift) creates a `JSONMap` - an integer array describing the JSON structure:

```swift
// Conceptual structure (actual implementation is more complex)
struct JSONMap {
    var buffer: [Int]  // Type markers + metadata + offsets
    // Example: [OBJECT, 2, 0, STRING, 5, 10, ...]
    //          type   count offset  type len offset
}
```

**Key insight**: Strings and numbers are NOT parsed during scanning. The map stores byte offsets, and actual parsing happens only when a value is decoded.

**Why this design?**

1. **Lazy parsing**: Only parse values that are actually requested
2. **Random access**: Jump to any key by following offsets
3. **Minimal copying**: Original bytes remain in place
4. **Skip optimization**: Unused branches can be skipped entirely

#### The BufferView System

Apple uses a custom [BufferView](https://github.com/swiftlang/swift-foundation/tree/main/Sources/FoundationEssentials/JSON) abstraction for safe, efficient byte access:

```swift
struct BufferView<Element> {
    let start: UnsafePointer<Element>
    let count: Int
    // Provides bounds-checked access in debug, unchecked in release
}
```

### 2.5 Why Apple Rewrote Everything in Pure Swift

The move from ObjC/CoreFoundation to pure Swift was driven by:

1. **Cross-platform support**: Swift on Linux/Windows doesn't have Foundation
2. **Performance**: No ObjC bridging overhead
3. **Type safety**: Eliminates NSObject boxing/unboxing
4. **Optimization opportunities**: Swift compiler can inline and optimize
5. **Maintainability**: Single language codebase

The performance results were significant - the pure Swift implementation is competitive with or faster than the ObjC version on Apple platforms, while also working on Linux.

---

## 3. Language Choice Analysis for Codec Implementation

### 3.1 What C Does Well

| Capability | Why It Matters for Codecs |
|------------|---------------------------|
| **Direct memory manipulation** | Read/write bytes without abstraction overhead |
| **Predictable performance** | No GC pauses, no hidden allocations |
| **Minimal function call overhead** | Critical for hot loops parsing millions of bytes |
| **SIMD intrinsics** | Vectorized operations for string scanning |
| **Bit manipulation** | Efficient type code encoding/decoding |
| **Control over memory layout** | Pack structures exactly as needed |

**Ideal for**:
- Low-level byte scanning and writing
- Performance-critical inner loops
- SIMD-accelerated parsing (like simdjson)
- Memory-efficient buffer management

### 3.2 What Swift Does Well

| Capability | Why It Matters for Codecs |
|------------|---------------------------|
| **Protocol conformance** | Implementing Encoder/Decoder protocols cleanly |
| **Type safety** | Catch errors at compile time |
| **Generics** | Handle any `Encodable`/`Decodable` type |
| **Value types** | Containers as efficient structs |
| **Copy-on-write** | Efficient immutable-style APIs |
| **Optionals** | Clean nil handling for `decodeIfPresent` |
| **Error handling** | Throwing functions for decode errors |

**Ideal for**:
- Protocol implementation (Encoder, Decoder, containers)
- Type-safe API surfaces
- Strategy handling (date formats, key conversion)
- Container management and coding path tracking

### 3.3 Swift Calling C: Performance Reality

According to [Daniel Lemire's research](https://lemire.me/blog/2016/09/29/can-swift-code-call-c-code-without-overhead/), **calling C functions from Swift has virtually zero overhead** in release builds. The cost of a Swift→C call is the same as a C→C call.

However, **the overhead is in the bridging patterns, not the calls themselves**:

| Pattern | Overhead | Example |
|---------|----------|---------|
| Simple scalar arguments | None | `ksbonjson_addInt(ctx, 42)` |
| Pointer arguments | None | `ksbonjson_addString(ctx, ptr, len)` |
| Callback functions | Minor | Callback closures require context management |
| String bridging | High | Converting `String` to C string copies bytes |
| Array bridging | High | Converting `[UInt8]` to C buffer may copy |
| Object bridging | Very High | ARC reference counting at boundary |

### 3.4 The Current Implementation's Inefficiencies

The current BONJSON implementation suffers from several architectural problems:

#### Problem 1: Callback-Per-Value Overhead

```swift
// Current: Every encoded value triggers a callback
ksbonjson_beginEncode(&context, { (data, length, userData) -> Int32 in
    let encoder = Unmanaged<Encoder>.fromOpaque(userData!).takeUnretainedValue()
    encoder.buffer.append(contentsOf: UnsafeBufferPointer(start: data, count: length))
    return 0
}, Unmanaged.passUnretained(self).toOpaque())
```

Each call:
1. Enters Swift from C
2. Recovers the encoder from an opaque pointer
3. Appends bytes (may trigger reallocation)
4. Returns to C

For a 1000-element array, this happens 1000+ times.

#### Problem 2: Container Tracking Mismatch

The C library doesn't know about Swift's container model. The Swift layer has to track container depth separately:

```swift
// Current: Swift manually tracks what C already knows
private var containerStack: [(type: ContainerType, depth: Int)] = []

func prepareToEncode(at depth: Int) throws {
    // Close containers down to the target depth
    while currentDepth > depth {
        try ksbonjson_endContainer(&context)
        currentDepth -= 1
    }
}
```

This duplicates logic and adds overhead.

#### Problem 3: Decoder Position Caching

The decoder scans containers to build position caches:

```swift
// Current: Scan object once, cache positions
private mutating func scanObject() throws {
    while !isAtEnd {
        let key = try readKey()
        keyPositions[key] = cursor.position
        try skipValue()  // Skip without decoding
    }
}
```

This is necessary for random access but:
- Allocates a dictionary per object
- Requires scanning all keys even if only one is needed
- Duplicates work if the same key is accessed multiple times

---

## 4. Proposed BONJSON Architecture

### 4.1 Design Principles

1. **C for byte-level operations**: All reading/writing of BONJSON bytes happens in C
2. **Swift for protocol implementation**: All Encoder/Decoder protocol logic in Swift
3. **Minimal boundary crossings**: Batch operations to reduce call overhead
4. **Shared data structures**: Use C-compatible layouts Swift can access directly
5. **No intermediate representation on encode**: Stream directly to output buffer
6. **Lazy evaluation on decode**: Parse values only when requested

### 4.2 Proposed Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                     Swift: Public API                            │
│  BONJSONEncoder / BONJSONDecoder                                 │
│  - Configuration strategies                                       │
│  - Top-level encode/decode methods                               │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                 Swift: Container Implementation                  │
│  Implements Encoder/Decoder protocols                            │
│  Calls C functions for actual byte operations                    │
│  Manages coding path and error handling                          │
└─────────────────────────────────────────────────────────────────┘
                              │
              ┌───────────────┴───────────────┐
              ▼                               ▼
┌─────────────────────────┐     ┌─────────────────────────────────┐
│   C: Encoding Engine    │     │      C: Decoding Engine         │
│                         │     │                                  │
│ - Buffer management     │     │ - Buffer view (no copy)         │
│ - Type code writing     │     │ - Map building (like JSONMap)   │
│ - Integer encoding      │     │ - Value parsing on demand       │
│ - Float encoding        │     │ - String/number lazy decode     │
│ - String encoding       │     │ - Position tracking             │
│ - Container markers     │     │ - Skip optimization             │
└─────────────────────────┘     └─────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│               C: Shared Buffer Structure                         │
│  Memory-mapped or pre-allocated buffer                           │
│  Swift has direct UnsafeRawBufferPointer access                  │
│  No copying between Swift and C                                  │
└─────────────────────────────────────────────────────────────────┘
```

### 4.3 Encoding Strategy: Direct Buffer Access

**Key insight**: Instead of callbacks, give Swift direct access to the C buffer.

#### C Header Design

```c
// Encoding context with directly accessible buffer
typedef struct {
    uint8_t* buffer;           // Swift can read this pointer
    size_t capacity;           // Current allocation size
    size_t position;           // Current write position
    uint8_t containerStack[256]; // Container type stack
    uint8_t containerDepth;    // Current nesting depth
} BONJSONEncodeContext;

// Initialize with pre-allocated buffer
void bonjson_encode_init(BONJSONEncodeContext* ctx, uint8_t* buffer, size_t capacity);

// Core encoding functions - return new position (or error)
size_t bonjson_write_null(BONJSONEncodeContext* ctx);
size_t bonjson_write_bool(BONJSONEncodeContext* ctx, bool value);
size_t bonjson_write_int(BONJSONEncodeContext* ctx, int64_t value);
size_t bonjson_write_uint(BONJSONEncodeContext* ctx, uint64_t value);
size_t bonjson_write_float(BONJSONEncodeContext* ctx, double value);
size_t bonjson_write_string(BONJSONEncodeContext* ctx, const char* str, size_t len);

// Container operations
size_t bonjson_begin_object(BONJSONEncodeContext* ctx);
size_t bonjson_begin_array(BONJSONEncodeContext* ctx);
size_t bonjson_end_container(BONJSONEncodeContext* ctx);

// Finalize and get buffer info
size_t bonjson_encode_finish(BONJSONEncodeContext* ctx);

// Buffer management
bool bonjson_ensure_capacity(BONJSONEncodeContext* ctx, size_t additional);
```

#### Swift Integration

```swift
final class _BONJSONEncoderState {
    private var context: BONJSONEncodeContext
    private var buffer: UnsafeMutableRawBufferPointer

    init(initialCapacity: Int = 256) {
        buffer = .allocate(byteCount: initialCapacity, alignment: 1)
        context = BONJSONEncodeContext()
        bonjson_encode_init(&context, buffer.baseAddress, initialCapacity)
    }

    // Direct buffer access - no callback overhead
    @inline(__always)
    func writeInt(_ value: Int64) {
        ensureCapacity(9)  // Max int size
        context.position = bonjson_write_int(&context, value)
    }

    @inline(__always)
    func writeString(_ value: String) {
        value.utf8CString.withUnsafeBufferPointer { buf in
            ensureCapacity(buf.count + 5)
            context.position = bonjson_write_string(&context, buf.baseAddress, buf.count - 1)
        }
    }

    func finish() -> Data {
        let length = bonjson_encode_finish(&context)
        return Data(bytes: buffer.baseAddress!, count: length)
    }

    private func ensureCapacity(_ additional: Int) {
        if context.position + additional > buffer.count {
            grow(to: max(buffer.count * 2, context.position + additional))
        }
    }

    private func grow(to newCapacity: Int) {
        let newBuffer = UnsafeMutableRawBufferPointer.allocate(byteCount: newCapacity, alignment: 1)
        newBuffer.copyMemory(from: UnsafeRawBufferPointer(buffer))
        buffer.deallocate()
        buffer = newBuffer
        context.buffer = buffer.baseAddress!.assumingMemoryBound(to: UInt8.self)
        context.capacity = newCapacity
    }
}
```

**Benefits**:
- No callback overhead
- Swift controls buffer growth (knows allocation patterns)
- C does byte-level encoding (optimal instruction selection)
- Single pointer dereference to access buffer

### 4.4 Decoding Strategy: Position Map with Lazy Parsing

**Key insight**: Build a lightweight map during scanning, parse values only when needed.

#### C Header Design

```c
// Position map entry - describes a value's location
typedef struct {
    uint32_t offset;      // Byte offset in input buffer
    uint32_t length;      // Byte length of value
    uint8_t type;         // Value type code
    uint8_t flags;        // Flags (e.g., string has escapes)
} BONJSONMapEntry;

// Object key entry
typedef struct {
    uint32_t keyOffset;   // Key string offset
    uint16_t keyLength;   // Key string length
    uint16_t valueIndex;  // Index into map entries
} BONJSONKeyEntry;

// Decode context
typedef struct {
    const uint8_t* input;      // Input buffer (no copy)
    size_t inputLength;
    BONJSONMapEntry* entries;  // Value entries
    size_t entryCount;
    BONJSONKeyEntry* keys;     // Object keys
    size_t keyCount;
} BONJSONDecodeContext;

// Initialize and scan
int bonjson_decode_init(BONJSONDecodeContext* ctx, const uint8_t* data, size_t length);
int bonjson_scan(BONJSONDecodeContext* ctx);  // Build position map

// Access values by index
int bonjson_get_type(BONJSONDecodeContext* ctx, size_t index);
int64_t bonjson_decode_int(BONJSONDecodeContext* ctx, size_t index);
uint64_t bonjson_decode_uint(BONJSONDecodeContext* ctx, size_t index);
double bonjson_decode_float(BONJSONDecodeContext* ctx, size_t index);
size_t bonjson_decode_string(BONJSONDecodeContext* ctx, size_t index, char* out, size_t outLen);

// Container access
size_t bonjson_object_count(BONJSONDecodeContext* ctx, size_t containerIndex);
size_t bonjson_array_count(BONJSONDecodeContext* ctx, size_t containerIndex);
int bonjson_object_find_key(BONJSONDecodeContext* ctx, size_t containerIndex,
                            const char* key, size_t keyLen);
size_t bonjson_container_child(BONJSONDecodeContext* ctx, size_t containerIndex, size_t childNum);
```

#### Swift Integration

```swift
final class _BONJSONDecoderState {
    private var context: BONJSONDecodeContext

    init(data: Data) throws {
        context = BONJSONDecodeContext()
        try data.withUnsafeBytes { buffer in
            let result = bonjson_decode_init(&context, buffer.baseAddress, buffer.count)
            guard result == 0 else { throw BONJSONDecodingError.invalidData }

            let scanResult = bonjson_scan(&context)
            guard scanResult == 0 else { throw BONJSONDecodingError.invalidData }
        }
    }

    func decodeInt(at index: Int) -> Int64 {
        return bonjson_decode_int(&context, index)
    }

    func decodeString(at index: Int) -> String {
        // Get length first
        let entry = context.entries[index]
        var buffer = [CChar](repeating: 0, count: Int(entry.length) + 1)
        bonjson_decode_string(&context, index, &buffer, buffer.count)
        return String(cString: buffer)
    }

    func findKey(in containerIndex: Int, key: String) -> Int? {
        let result = key.withCString { keyPtr in
            bonjson_object_find_key(&context, containerIndex, keyPtr, key.utf8.count)
        }
        return result >= 0 ? result : nil
    }
}
```

### 4.5 Container Protocol Implementation

```swift
struct _BONJSONKeyedEncodingContainer<Key: CodingKey>: KeyedEncodingContainerProtocol {
    private let state: _BONJSONEncoderState
    private let depth: Int  // Track depth for container management
    let codingPath: [CodingKey]

    init(state: _BONJSONEncoderState, codingPath: [CodingKey], depth: Int) {
        self.state = state
        self.codingPath = codingPath
        self.depth = depth
    }

    mutating func encode(_ value: String, forKey key: Key) throws {
        // Write key
        state.writeString(key.stringValue)
        // Write value
        state.writeString(value)
    }

    mutating func encode(_ value: Int, forKey key: Key) throws {
        state.writeString(key.stringValue)
        state.writeInt(Int64(value))
    }

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy keyType: NestedKey.Type,
        forKey key: Key
    ) -> KeyedEncodingContainer<NestedKey> {
        // Write key for nested container
        state.writeString(key.stringValue)
        // Begin nested object
        state.beginObject()

        return KeyedEncodingContainer(_BONJSONKeyedEncodingContainer<NestedKey>(
            state: state,
            codingPath: codingPath + [key],
            depth: depth + 1
        ))
    }

    // Container finalization happens via reference tracking:
    // State knows current depth, closes containers automatically
}
```

### 4.6 Performance Comparison: Expected Results

| Operation | Current Implementation | Proposed Implementation |
|-----------|----------------------|------------------------|
| Encode 1000 ints | 1000 callbacks | 1000 direct C calls |
| Buffer growth | Per-callback check | Batched in Swift |
| String encoding | Copy to Swift buffer, callback | Direct to C buffer |
| Container tracking | Duplicate in Swift + C | Single source of truth in C |
| Decode object scan | Swift cursor + dict alloc | C builds map, Swift reads |
| Key lookup | Swift dict lookup | C binary search on sorted keys |
| Value parsing | Always at scan time | Only when accessed |

### 4.7 Implementation Phases

#### Phase 1: C Library Restructure
- Add direct buffer access to encoder context
- Add position map structure for decoder
- Add key search optimization for objects
- Expose structures in header for Swift access

#### Phase 2: Swift Encoder Rewrite
- Direct buffer pointer management
- Remove callback mechanism
- Inline hot path functions
- Implement container finalization via depth tracking

#### Phase 3: Swift Decoder Rewrite
- Use C position map
- Lazy value parsing
- Key lookup via C binary search
- Cache decoded values in Swift layer

#### Phase 4: Optimization
- Profile and identify remaining bottlenecks
- Consider SIMD for string scanning
- Add special-case fast paths for common patterns
- Benchmark against Apple's JSON

---

## Summary

The key insights for building a high-performance BONJSON codec:

1. **Use C for byte-level operations**: Type code encoding, integer packing, buffer management
2. **Use Swift for protocol logic**: Encoder/Decoder implementation, strategy handling, error management
3. **Minimize boundary crossings**: Direct buffer access instead of callbacks
4. **Lazy evaluation on decode**: Build position maps, parse values on demand
5. **Learn from Apple**: Their JSONMap approach is the right model for decoding

The current implementation's main problem is trying to use the C library as a black box with callbacks. The optimal approach integrates C and Swift as cooperative layers with shared data structures and direct memory access.

---

## 5. Deep Dive: How Apple Achieves JSON Performance

### 5.1 Core Performance Techniques

Apple's swift-foundation JSON implementation uses a layered set of optimizations:

#### 5.1.1 Aggressive Inlining

```swift
@inline(__always)
func checkNotNull<T>(_ value: JSONMap.Value, expectedType: T.Type, ...) throws

@inline(__always)
private func decodeFixedWidthInteger<T: FixedWidthInteger>() throws -> T
```

The `@inline(__always)` attribute forces the compiler to inline small, frequently-called methods, eliminating function call overhead in hot paths. Apple uses this extensively on:
- Validation methods
- Type conversion methods
- Buffer access methods

#### 5.1.2 Branch Prediction Hints

```swift
guard byte != ._backslash && _fastPath(byte & 0xe0 != 0) else { break }
```

The undocumented `_fastPath()` and `_slowPath()` compiler hints tell the optimizer which branch is likely. This improves instruction cache utilization and reduces pipeline stalls.

#### 5.1.3 Unchecked Buffer Access

```swift
let byte0 = (length > 0) ? bytes[uncheckedOffset: 0] : nil
let ascii = bytes[unchecked: readIndex]
```

Using `[unchecked:]` subscripts eliminates bounds-checking in release builds. Apple validates bounds once at the scan level, then uses unchecked access for individual bytes.

#### 5.1.4 BufferView: Zero-Cost Safe Abstraction

Apple developed [BufferView](https://gist.github.com/atrick/4fab6886518f756295f77445e4bf0788) specifically for this use case:

```swift
struct BufferView<Element> {
    let start: UnsafePointer<Element>
    let count: Int
    // Bounds-checked in debug, unchecked in release
}
```

Key properties:
- **No reference counting**: Unlike Array slices, doesn't retain parent
- **Compile-time lifetime safety**: Uses Swift's non-escaping types
- **Stack allocation**: Temporary views allocate on stack, not heap
- **Cross-module efficiency**: Concrete representation without generics bloat

#### 5.1.5 SIMD-Style Packed Comparisons

```swift
static func noByteMatches(_ asciiByte: UInt8, in hexString: UInt32) -> Bool {
    let t0 = UInt32(0x01010101) &* UInt32(asciiByte)
    let t1 = ((hexString ^ t0) & 0x7f7f7f7f) &+ 0x7f7f7f7f
    let t2 = ((hexString | t1) & 0x80808080) ^ 0x80808080
    return t2 == 0
}
```

This technique processes 4 bytes simultaneously using arithmetic operations instead of loops, achieving SIMD-like parallelism without explicit SIMD instructions.

#### 5.1.6 Bitwise Character Classification

```swift
static var whitespaceBitmap: UInt64 {
    1 << UInt8._space | 1 << UInt8._return | 1 << UInt8._newline | 1 << UInt8._tab
}

if Self.whitespaceBitmap & (1 << ascii) != 0 { ... }
```

Replaces multiple comparisons with a single bitwise operation for constant-time character set checking.

#### 5.1.7 Manual Loop Unrolling

```swift
while remainingBuffer.count >= 4 {
    if let res = check(0) { return res }
    if let res = check(1) { return res }
    if let res = check(2) { return res }
    if let res = check(3) { return res }
    remainingBuffer = remainingBuffer.dropFirst(4)
}
```

Processing 4 elements per loop iteration reduces loop overhead and improves instruction pipelining.

### 5.2 Architectural Design: The JSONMap System

Apple's key insight: **Don't parse what you don't need.**

```
┌─────────────────────────────────────────────────────────────────┐
│                      Input: JSON Bytes                           │
│  {"name": "Alice", "age": 30, "addresses": [...]}               │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                   Stage 1: Structural Scan                       │
│  Single pass: find all structural characters, validate UTF-8     │
│  Output: JSONMap (integer array of offsets and types)           │
│  - NO string parsing (just note offset and length)              │
│  - NO number parsing (just note offset)                         │
│  - NO memory allocation for values                              │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                   Stage 2: Lazy Value Access                     │
│  Parse values ON DEMAND when Codable requests them              │
│  - String requested? Parse from offset now                      │
│  - Number requested? Parse from offset now                      │
│  - Object field unused? Never parsed at all                     │
└─────────────────────────────────────────────────────────────────┘
```

The JSONMap is a flat integer array storing:
- Value types
- Byte offsets into original input
- Container counts
- Flags (has escapes, has exponent, etc.)

**Benefits:**
1. **Cache locality**: All metadata in contiguous memory
2. **Minimal allocation**: One integer array, not thousands of objects
3. **Skip optimization**: Unused values cost nothing
4. **Random access**: Jump to any key without sequential scan

### 5.3 Why Apple Switched to Pure Swift

Apple rewrote their JSON codec from Objective-C/CoreFoundation to pure Swift for:

1. **Cross-platform**: Swift on Linux/Windows lacks ObjC runtime
2. **No bridging overhead**: ObjC→Swift bridging is expensive
3. **Type safety**: Eliminates NSObject boxing/unboxing
4. **Compiler optimization**: Swift optimizer can inline and specialize
5. **Unified codebase**: One language, one optimization target

The pure Swift version matches or exceeds ObjC performance on Apple platforms while also working on Linux.

---

## 6. Exceeding Apple's Performance: Architectural Options

### 6.1 The Fundamental Challenge

BONJSON has a potential advantage over JSON: binary format with simpler parsing rules. However, this advantage is currently negated by:

1. **Codable protocol overhead**: Every value access goes through protocol dispatch
2. **Position map construction**: Single-pass scan still allocates and fills arrays
3. **Child access O(n)**: Navigating to the n-th child requires iteration
4. **String allocation**: Every string decode creates a new String object

To exceed Apple's ~50 MB/s JSON decode, we need to eliminate these bottlenecks.

### 6.2 Option A: Pure Swift with Extreme Optimization

**Approach**: Rewrite entirely in Swift, applying Apple's techniques.

```swift
// Example: BufferView-style access
@usableFromInline
struct BONJSONBufferView {
    @usableFromInline let start: UnsafeRawPointer
    @usableFromInline let count: Int

    @inline(__always) @usableFromInline
    subscript(unchecked offset: Int) -> UInt8 {
        start.load(fromByteOffset: offset, as: UInt8.self)
    }
}

// Example: Inline fast paths
@inline(__always)
private func decodeSmallInt(at offset: Int) -> Int8 {
    let byte = buffer[unchecked: offset]
    return Int8(bitPattern: byte)  // Type code IS the value for -100...100
}
```

**Pros:**
- Single language, easier maintenance
- Swift optimizer can see everything
- Access to Swift SIMD types (SIMD8, SIMD16, etc.)
- Natural Codable integration

**Cons:**
- Requires deep Swift optimization expertise
- Limited control over memory layout
- Harder to share with non-Swift platforms

**Expected speedup**: 5-10x (approach Apple's level)

### 6.3 Option B: C Core with Minimal Swift Wrapper

**Approach**: Move ALL parsing and serialization to C, Swift only handles Codable protocol routing.

```
┌─────────────────────────────────────────────────────────────────┐
│  Swift: Protocol Routing Only (< 100 lines)                     │
│  - Receives encode/decode calls                                  │
│  - Routes to C by type code                                      │
│  - Returns C results to caller                                   │
└─────────────────────────────────────────────────────────────────┘
                              │ Direct C calls
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  C: Complete Codec Engine                                        │
│  - Scan and build position map                                   │
│  - Decode values directly to caller-provided memory              │
│  - Encode values directly to buffer                              │
│  - All hot paths in C                                            │
└─────────────────────────────────────────────────────────────────┘
```

**Key C API design:**
```c
// Decode directly to caller's memory
void bonjson_decode_string_direct(
    BONJSONContext* ctx,
    size_t entryIndex,
    char* outBuffer,       // Caller provides buffer
    size_t* outLength      // Actual length returned
);

// Batch decode for arrays
void bonjson_decode_int_array(
    BONJSONContext* ctx,
    size_t arrayIndex,
    int64_t* outArray,     // Caller provides buffer
    size_t count
);
```

**Pros:**
- Maximum control over memory and performance
- Predictable performance, no GC
- SIMD intrinsics available
- Shareable with C/C++ projects

**Cons:**
- Manual memory management
- Harder Swift integration
- Two languages to maintain

**Expected speedup**: 10-20x (can exceed Apple)

### 6.4 Option C: C++ Template-Based Type Specialization

**Approach**: Use C++ templates to generate specialized encode/decode code per type.

```cpp
template<typename T>
struct BONJSONDecoder;

template<>
struct BONJSONDecoder<int64_t> {
    static inline int64_t decode(const uint8_t* data, size_t offset) {
        uint8_t typeCode = data[offset];
        if (typeCode >= 0x00 && typeCode <= 0x64) {
            return static_cast<int64_t>(typeCode);  // Small int
        }
        // Handle other cases...
    }
};

template<>
struct BONJSONDecoder<std::string_view> {
    static inline std::string_view decode(const uint8_t* data, size_t offset) {
        // Zero-copy string view into original buffer
    }
};
```

**Pros:**
- Compile-time type specialization
- Zero virtual dispatch overhead
- Can use std::string_view for zero-copy strings
- move semantics for efficient value transfer

**Cons:**
- C++ complexity
- Harder Swift interop (need C bridge)
- Template bloat can hurt instruction cache

**Expected speedup**: 15-25x (likely fastest option)

### 6.5 Option D: Code Generation at Build Time

**Approach**: Generate specialized Swift code for known types.

```swift
// User writes:
@BONJSONOptimized
struct Person: Codable {
    var name: String
    var age: Int
}

// Build plugin generates:
extension Person {
    @inline(__always)
    static func _bonjson_decode(from buffer: UnsafeRawBufferPointer, at offset: inout Int) -> Person {
        // Direct field-by-field decode, no protocol overhead
        let name = _decodeString(buffer, &offset)
        let age = _decodeInt(buffer, &offset)
        return Person(name: name, age: age)
    }
}
```

**Pros:**
- Zero runtime protocol overhead
- Type-specific optimizations
- Still pure Swift
- Works with Swift macros (5.9+)

**Cons:**
- Requires build tooling
- Generated code maintenance
- Only works for known types

**Expected speedup**: 10-20x for optimized types

### 6.6 Option E: SIMD-Accelerated Parser (simdjson-style)

**Approach**: Apply [simdjson](https://github.com/simdjson/simdjson)'s techniques to BONJSON.

```
Stage 1: Vectorized Structure Discovery
┌─────────────────────────────────────────────────────────────────┐
│  Load 64 bytes at a time using SIMD                             │
│  Find all type codes in parallel                                 │
│  Build structural index with one pass                            │
│  Validate UTF-8 in strings using SIMD                           │
└─────────────────────────────────────────────────────────────────┘

Stage 2: On-Demand Value Extraction
┌─────────────────────────────────────────────────────────────────┐
│  Jump directly to value using index                              │
│  Vectorized number parsing (multiple digits at once)             │
│  Vectorized string copying                                       │
└─────────────────────────────────────────────────────────────────┘
```

**SIMD opportunities in BONJSON:**
- Finding container end markers (0x9b) in bulk
- Validating UTF-8 in string data
- Parsing multi-byte integers
- Bulk copying string data

**Pros:**
- 2-10x speedup from SIMD alone (per simdjson benchmarks)
- BONJSON simpler to parse than JSON (no escapes, known lengths)
- Can achieve GB/s throughput

**Cons:**
- Architecture-specific code (AVX2, NEON, etc.)
- Significant complexity
- May not help small documents

**Expected speedup**: 20-50x (GB/s range)

### 6.7 Option F: Hybrid Architecture

**Approach**: Combine best elements from multiple options.

```
┌─────────────────────────────────────────────────────────────────┐
│  Layer 1: Swift Public API                                       │
│  - BONJSONEncoder/Decoder matching Apple's interface             │
│  - Strategy handling (dates, keys, etc.)                         │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  Layer 2: Swift Fast Path                                        │
│  - Code-generated decoders for common types                      │
│  - Inline BufferView access                                      │
│  - Direct struct construction for @BONJSONOptimized types        │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  Layer 3: C/C++ SIMD Core                                        │
│  - SIMD structure discovery                                      │
│  - Vectorized UTF-8 validation                                   │
│  - Position map construction                                     │
│  - Batch value extraction                                        │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  Layer 4: Shared Buffer                                          │
│  - Memory-mapped or pre-allocated                                │
│  - Zero-copy between layers                                      │
│  - Reference counted for cleanup                                 │
└─────────────────────────────────────────────────────────────────┘
```

**Recommended hybrid approach:**

1. **C for SIMD scanning**: Vectorized structure discovery
2. **C for position map**: Direct memory, no Swift overhead
3. **Swift for protocol routing**: Clean Codable implementation
4. **Code generation for hot types**: Bypass Codable for known structs
5. **BufferView-style access**: Zero-copy throughout

**Expected speedup**: 30-100x (exceeds Apple significantly)

### 6.8 Comparison Matrix

| Option | Expected Speedup | Complexity | Maintainability | Platform Support |
|--------|-----------------|------------|-----------------|------------------|
| A: Pure Swift | 5-10x | Medium | High | All Swift platforms |
| B: C Core | 10-20x | Medium | Medium | Excellent |
| C: C++ Templates | 15-25x | High | Low | Good |
| D: Code Generation | 10-20x | High | Medium | Swift 5.9+ |
| E: SIMD Parser | 20-50x | Very High | Low | x86-64, ARM64 |
| F: Hybrid | 30-100x | Very High | Medium | Excellent |

### 6.9 Recommended Path Forward

**Phase 1: Low-Hanging Fruit (2-5x improvement)**
1. Apply Apple's inlining patterns (`@inline(__always)`)
2. Use unchecked buffer access in release builds
3. Precompute all navigation indices (child offsets)
4. Eliminate per-decode allocations

**Phase 2: Architectural Improvements (5-10x total)**
1. Implement BufferView-style zero-copy access
2. Move position map construction entirely to C
3. Add batch decode APIs for arrays of primitives
4. Cache String objects for repeated keys

**Phase 3: Advanced Optimizations (10-50x total)**
1. Add SIMD scanning for structure discovery
2. Vectorized UTF-8 validation
3. Code generation for common struct patterns
4. Memory-mapped I/O for large documents

**Phase 4: Exceed Apple (50-100x total)**
1. Full simdjson-style two-stage parsing
2. Architecture-specific SIMD kernels (AVX2, NEON)
3. Zero-copy string_view equivalents
4. Thread-parallel scanning for very large documents

---

## 7. Profiling Results and Revised Recommendations (January 2026)

### 7.1 Key Profiling Findings

Detailed profiling revealed a critical insight: **The C layer is fast; Swift Codable is the bottleneck.**

| Component | Time | % of Total | Throughput |
|-----------|------|------------|------------|
| C Position Map Scan | 80 µs | 6% | 319 MB/s |
| Swift Codable Layer | 1.27 ms | 94% | ~20 MB/s |

The C scanner processes entries at 13ns each, achieving 319 MB/s. This is competitive with the fastest JSON parsers. However, Swift's Codable machinery dominates total time:

- **Container creation**: ~470ns per object
- **Field decoding**: ~176ns per field
- **Primitive arrays**: 160ns per element (should be <10ns)

### 7.2 Why Previous Assumptions Were Wrong

**Original assumption**: "Moving more to C will make BONJSON faster."

**Reality**: C is only 6% of time. Doubling C performance saves 40µs out of 1.35ms (3%).

**Original assumption**: "SIMD scanning will provide major speedups."

**Reality**: SIMD speeds up the 6%, not the 94%. Maximum gain: ~5%.

**Original assumption**: "BONJSON's binary format should be much faster than JSON text."

**Reality**: Both BONJSON and JSON are bottlenecked by Codable. BONJSON decode time (1.26ms) ≈ JSON decode time (1.23ms) despite BONJSON being 41% smaller.

### 7.3 Revised Optimization Strategy

Given that Codable is the bottleneck, the optimization strategy must change:

#### Tier 1: Reduce Codable Overhead (2-3x improvement)

1. **Batch Decode for Primitive Arrays**
   ```c
   // New C API
   void ksbonjson_decode_int64_array(ctx, arrayIndex, outBuffer, count);
   ```
   - Decoding `[Int]` calls C once instead of 10,000 times
   - Reduces per-element overhead from 160ns to ~10ns
   - **Expected gain**: 10-15x for primitive arrays

2. **Lazy Key Cache**
   - Current: Build full dictionary at container creation
   - Proposed: Build cache on first key access
   - **Expected gain**: 20-50% for partial key access

3. **Container Object Pooling**
   - Reuse `KeyedDecodingContainer` instances for same type
   - Avoid repeated dictionary allocation
   - **Expected gain**: 10-20% for arrays of objects

#### Tier 2: Bypass Codable Selectively (5-10x improvement)

4. **Code Generation Macro**
   ```swift
   @BONJSONOptimized
   struct Person: Codable {
       var name: String
       var age: Int
   }

   // Generates direct decode without Codable overhead:
   extension Person {
       static func _bonjson_decode(from map: _PositionMap, at index: Int) -> Person {
           // Direct field extraction, no containers
       }
   }
   ```
   - Requires Swift 5.9+ macros
   - Opt-in per type
   - **Expected gain**: 5-10x for annotated types

5. **Specialized Collection Decoders**
   - Detect `[KnownType].self` patterns
   - Use batch decode without per-element containers
   - **Expected gain**: 3-5x for typed arrays

#### Tier 3: Alternative Non-Codable API (10x+ improvement)

6. **Direct Position Map Access**
   ```swift
   // Skip Codable entirely for maximum performance
   let map = try BONJSONMap(data: data)
   let name = map.getString(at: map.findKey("name"))
   let age = map.getInt(at: map.findKey("age"))
   ```
   - Zero protocol overhead
   - Manual but fast
   - **Expected gain**: Approach C speed (10-15x)

### 7.4 Revised Recommendation Matrix

| Approach | Effort | Improvement | Compatibility |
|----------|--------|-------------|---------------|
| Batch primitive decode | Low | 10-15x (arrays) | Full |
| Lazy key cache | Low | 20-50% (partial) | Full |
| Container pooling | Medium | 10-20% | Full |
| Code generation macro | High | 5-10x (opt-in) | Swift 5.9+ |
| Direct map API | Medium | 10-15x | Non-Codable |

### 7.5 Recommended Path Forward

**Phase 1: Quick Wins (1-2 weeks)**
1. Add batch decode C APIs for primitive arrays
2. Implement lazy key cache in containers
3. Expected result: 2-3x faster for typical workloads

**Phase 2: Selective Bypass (2-4 weeks)**
4. Design code generation macro for common patterns
5. Add specialized `[T].self` decode paths
6. Expected result: 5-10x for annotated types

**Phase 3: Power User API (optional)**
7. Expose direct position map access for maximum performance
8. Document trade-offs vs Codable
9. Expected result: 10-15x for power users

### 7.6 Theoretical Performance Limits

| Scenario | Throughput | Relative to Current |
|----------|------------|---------------------|
| Current implementation | 20 MB/s | 1x |
| With batch primitives | 50-80 MB/s | 2.5-4x |
| With code generation | 100-200 MB/s | 5-10x |
| Direct map API | 300+ MB/s | 15x+ |
| C scan only (theoretical) | 319 MB/s | 16x |
| C with SIMD (theoretical) | 1+ GB/s | 50x+ |

The fundamental limit for Codable-compatible decode is ~100-200 MB/s due to protocol overhead. Exceeding this requires bypassing Codable.

---

## References

- [Swift Foundation JSON Implementation](https://github.com/swiftlang/swift-foundation/tree/main/Sources/FoundationEssentials/JSON)
- [Swift CoreLibs Foundation](https://github.com/swiftlang/swift-corelibs-foundation)
- [Daniel Lemire: Swift Calling C Performance](https://lemire.me/blog/2016/09/29/can-swift-code-call-c-code-without-overhead/)
- [BufferView Roadmap](https://gist.github.com/atrick/4fab6886518f756295f77445e4bf0788)
- [simdjson: Parsing Gigabytes of JSON per Second](https://github.com/simdjson/simdjson)
- [simdjson Paper](https://arxiv.org/pdf/1902.08318)
- [Swift SIMD Evolution Proposal](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0229-simd.md)
- [Flight School Codable DIY Kit](https://github.com/Flight-School/Codable-DIY-Kit)
- [Swift Encoder/Decoder Slides](https://kaitlin.dev/files/encoder_decoder_slides.pdf)
- [FlatBuffers Zero-Copy Design](https://en.wikipedia.org/wiki/FlatBuffers)
- [Apple UnsafeBufferPointer Documentation](https://developer.apple.com/documentation/swift/unsafebufferpointer)
- [WWDC20: Safely Manage Pointers in Swift](https://developer.apple.com/videos/play/wwdc2020/10167/)
