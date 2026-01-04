# Swift Codable Architecture and Optimal BONJSON Implementation

## Table of Contents

1. [The Swift Encoder/Decoder Protocol API](#1-the-swift-encoderdecoder-protocol-api)
2. [Apple's JSONEncoder/JSONDecoder Implementation](#2-apples-jsonencoderjsondecoder-implementation)
3. [Language Choice Analysis for Codec Implementation](#3-language-choice-analysis-for-codec-implementation)
4. [Proposed BONJSON Architecture](#4-proposed-bonjson-architecture)

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

## References

- [Swift Foundation JSON Implementation](https://github.com/swiftlang/swift-foundation/tree/main/Sources/FoundationEssentials/JSON)
- [Swift CoreLibs Foundation](https://github.com/swiftlang/swift-corelibs-foundation)
- [Daniel Lemire: Swift Calling C Performance](https://lemire.me/blog/2016/09/29/can-swift-code-call-c-code-without-overhead/)
- [Flight School Codable DIY Kit](https://github.com/Flight-School/Codable-DIY-Kit)
- [Swift Encoder/Decoder Slides](https://kaitlin.dev/files/encoder_decoder_slides.pdf)
- [FlatBuffers Zero-Copy Design](https://en.wikipedia.org/wiki/FlatBuffers)
- [Apple UnsafeBufferPointer Documentation](https://developer.apple.com/documentation/swift/unsafebufferpointer)
- [WWDC20: Safely Manage Pointers in Swift](https://developer.apple.com/videos/play/wwdc2020/10167/)
