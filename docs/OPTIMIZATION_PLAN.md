# BONJSON Optimization Plan

## Approach

Incremental optimization with profiling after each change. Start with easy wins, measure impact, and let data guide next steps. All changes maintain full Codable compatibility.

## Baseline Metrics (Current State)

| Metric | Value |
|--------|-------|
| Decode 1000 SimpleObjects | 1.35 ms |
| Position map creation | 80 µs (6%) |
| Codable overhead | 1.27 ms (94%) |
| Per-object overhead | 1.25 µs |
| Per-field overhead | 176 ns |
| Primitive array (10k ints) | 1.61 ms (160 ns/element) |
| Throughput | 20 MB/s |

---

## Phase 1: Batch Decode for Primitive Arrays

**Goal**: Reduce per-element overhead from 160ns to ~10ns for `[Int]`, `[Double]`, `[Bool]`, `[String]`.

### Step 1.1: Add C batch decode API

Add to `KSBONJSONDecoder.h`:
```c
// Batch decode primitives from an array entry
size_t ksbonjson_decode_int64_array(
    KSBONJSONMapContext* ctx,
    size_t arrayIndex,
    int64_t* outBuffer,
    size_t maxCount);

size_t ksbonjson_decode_double_array(
    KSBONJSONMapContext* ctx,
    size_t arrayIndex,
    double* outBuffer,
    size_t maxCount);

size_t ksbonjson_decode_bool_array(
    KSBONJSONMapContext* ctx,
    size_t arrayIndex,
    bool* outBuffer,
    size_t maxCount);
```

**Effort**: Low (add ~50 lines of C)
**Risk**: Low (additive, doesn't change existing behavior)

### Step 1.2: Add Swift wrapper in _PositionMap

```swift
extension _PositionMap {
    func decodeInt64Array(at arrayIndex: size_t) -> [Int64]? {
        // Call C batch function
    }
}
```

### Step 1.3: Specialize UnkeyedDecodingContainer

Detect when decoding homogeneous primitive arrays and use batch path:

```swift
// In BONJSONDecoder.decode(_:from:)
if type == [Int].self {
    return try decodeBatchIntArray(from: map) as! T
}
```

### Step 1.4: Profile and measure

Run profiling tests, compare:
- Primitive array decode time
- Overall throughput improvement
- Impact on non-array decodes (should be zero)

**Expected result**: 10-15x faster for `[Int]`, `[Double]`, etc.

---

## Phase 2: Lazy Key Cache

**Goal**: Don't build full key dictionary upfront; build on demand.

### Step 2.1: Change keyCache to lazy initialization

Current:
```swift
init(...) {
    // Build entire cache upfront
    var cache: [String: size_t] = [:]
    for each key in object {
        cache[keyString] = valueIndex
    }
    self.keyCache = cache
}
```

Proposed:
```swift
init(...) {
    // Just store object info, don't scan keys yet
    self.keyCache = nil  // Lazy
}

private mutating func ensureKeyCache() {
    if keyCache == nil {
        // Build cache now
    }
}
```

### Step 2.2: Optimize for sequential access pattern

Many Codable types access keys in declaration order. Track if we're hitting keys sequentially and skip dictionary entirely:

```swift
private var lastKeyIndex: Int = -1
private var isSequential: Bool = true

func valueIndex(forKey key: Key) -> size_t {
    // Fast path: check if it's the next key
    if isSequential, let nextIdx = checkNextKey(key) {
        return nextIdx
    }
    // Slow path: dictionary lookup
    ensureKeyCache()
    return keyCache[key]
}
```

### Step 2.3: Profile and measure

Test cases:
- Full object decode (all keys accessed)
- Partial object decode (some keys accessed)
- Sequential vs random key access

**Expected result**: 20-50% faster for partial access, minimal overhead for full access.

---

## Phase 3: Reduce Container Creation Overhead

**Goal**: Reduce the ~470ns per-object container creation overhead.

### Step 3.1: Profile container creation in detail

Add timing to identify exactly what's slow:
- Dictionary allocation
- Key string creation
- allKeys array building
- Entry lookup

### Step 3.2: Avoid allKeys allocation when not needed

Current: Always build `allKeys: [Key]` array.
Proposed: Build lazily only when accessed.

```swift
private var _allKeys: [Key]?

var allKeys: [Key] {
    if _allKeys == nil {
        _allKeys = buildAllKeys()
    }
    return _allKeys!
}
```

### Step 3.3: Use stack allocation for small objects

For objects with ≤8 fields, use fixed-size array instead of dictionary:

```swift
// For small objects, linear search beats dictionary
private let smallKeyCache: (key: String, value: size_t)?  // Up to 8
private var largeKeyCache: [String: size_t]?  // Fallback
```

### Step 3.4: Profile and measure

Compare container creation overhead before/after.

**Expected result**: 20-40% reduction in per-object overhead.

---

## Phase 4: Specialized Collection Decode

**Goal**: Fast path for `[SomeStruct].self` without per-element container creation.

### Step 4.1: Detect array-of-structs pattern

```swift
// In BONJSONDecoder
if let elementType = T.self as? [Any].Type {
    // Check if element type is a known struct
}
```

### Step 4.2: Batch container creation

Instead of creating N containers for N objects, create one "batch container" that handles all objects with shared state.

### Step 4.3: Profile and measure

Test with arrays of 100, 500, 1000 objects.

**Expected result**: 2-3x faster for arrays of objects.

---

## Phase 5: Code Generation (Optional)

**Goal**: For users who want maximum speed, generate direct decode code.

### Step 5.1: Design macro API

```swift
@attached(extension, conformances: BONJSONOptimized)
@attached(member, names: named(_bonjson_decode))
public macro BONJSONOptimized() = #externalMacro(...)
```

### Step 5.2: Implement macro

Generate:
```swift
extension Person: BONJSONOptimized {
    static func _bonjson_decode(from map: _PositionMap, at index: size_t) throws -> Person {
        let entry = map.getEntry(at: index)!
        let nameIdx = map.findKey(objectIndex: index, key: "name")
        let ageIdx = map.findKey(objectIndex: index, key: "age")
        return Person(
            name: map.getString(at: nameIdx)!,
            age: Int(map.getEntry(at: ageIdx)!.data.intValue)
        )
    }
}
```

### Step 5.3: Hook into decoder

```swift
// In BONJSONDecoder.decode
if let optimized = T.self as? BONJSONOptimized.Type {
    return try optimized._bonjson_decode(from: map, at: rootIndex) as! T
}
```

**Expected result**: 5-10x faster for annotated types.

---

## Phase 6: Direct Map API (Optional)

**Goal**: Expose raw map access for power users who don't need Codable.

### Step 6.1: Design public API

```swift
public struct BONJSONMap {
    public init(data: Data) throws

    public func getString(forKey key: String) -> String?
    public func getInt(forKey key: String) -> Int?
    public func getDouble(forKey key: String) -> Double?
    public func getArray(forKey key: String) -> BONJSONMapArray?
    public func getObject(forKey key: String) -> BONJSONMap?
}
```

### Step 6.2: Document trade-offs

- Faster but manual
- No type safety
- Recommended for hot paths only

**Expected result**: Near-C speed (300+ MB/s).

---

## Execution Order

| Step | Effort | Expected Gain | Cumulative |
|------|--------|---------------|------------|
| 1.1-1.4: Batch primitives | 1 day | 10-15x (arrays) | Baseline + arrays |
| 2.1-2.3: Lazy key cache | 1 day | 20-50% (partial) | +20% typical |
| 3.1-3.4: Container overhead | 2 days | 20-40% | +30-50% total |
| 4.1-4.3: Collection decode | 2 days | 2-3x (object arrays) | +100-200% |
| 5.1-5.3: Code generation | 1 week | 5-10x (opt-in) | +500-1000% opt-in |
| 6.1-6.2: Direct API | 2 days | 10-15x (manual) | Max performance |

## Success Criteria

| Metric | Current | Target (Phase 4) | Stretch (Phase 5+) |
|--------|---------|------------------|-------------------|
| Throughput | 20 MB/s | 50-80 MB/s | 200+ MB/s |
| vs JSON | 1.0x | 2-3x faster | 5-10x faster |
| Primitive arrays | 160 ns/elem | 10 ns/elem | 5 ns/elem |
| Object arrays | 1.25 µs/obj | 500 ns/obj | 100 ns/obj |

## Profiling Protocol

After each step:
1. Run `ProfilingTests.testSummary()`
2. Record all metrics
3. Compare to previous step
4. Decide whether to continue or pivot

Document results in PROFILING.md under dated sections.
