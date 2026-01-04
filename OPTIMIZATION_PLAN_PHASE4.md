# BONJSON Optimization Plan - Phase 4

## Current State (Post String Batch Decode)

**BONJSON is 2.4x faster than Apple's JSON decoder**

| Metric | Value |
|--------|-------|
| Decode 1000 objects (5 fields) | 500 µs |
| Throughput | 52 MB/s |
| vs JSON | 0.41x (2.4x faster) |
| Position Map (C) | 80 µs (16%) |
| Codable Layer (Swift) | 414 µs (84%) |

---

## Per-Operation Cost Breakdown

| Operation | Cost | Notes |
|-----------|------|-------|
| Container creation | 127 ns | `_LazyKeyState` class allocation |
| Field lookup (linear, ≤8 fields) | 98 ns | Direct byte comparison |
| Field lookup (dictionary, >8 fields) | 147 ns | 1.5x slower than linear |
| Nesting overhead | 275 ns | Per extra nesting level |
| Primitive array element | 10-18 ns | All types batched ✓ |

---

## Remaining Bottleneck Analysis

### 1. Nesting Overhead (549 ns for 2 levels)

```
Flat object (1 level):    277 ns
Nested (3 levels):        826 ns
Extra cost per level:     ~275 ns
```

**Root cause**: Each nesting level requires:
- New `_MapDecoder` instance
- New `_MapKeyedDecodingContainer`
- New `_LazyKeyState` allocation

**Optimization potential**: Limited without bypassing Codable

---

### 2. Dictionary vs Linear Search (1.5x difference)

```
5-field objects (linear):  98 ns/field
15-field objects (dict):   147 ns/field
Ratio: 1.5x slower
```

**Current threshold**: 8 fields

**Observation**: Linear search is significantly faster. Could increase threshold.

---

### 3. Container Creation (127 ns per object)

For 1000 objects: 127 µs just for container creation

**Root cause**: `_LazyKeyState` class allocation per container

---

## Optimization Options

### Option A: Increase Linear Search Threshold (Easy)

**Change**: Increase `kSmallObjectThreshold` from 8 to 12

**Expected impact**:
- Objects with 9-12 fields get 1.5x faster field lookup
- Negligible cost for smaller objects

**Effort**: 5 minutes (one line change)
**Risk**: Very low

---

### Option B: Container State Pooling (Medium)

**Change**: Pool and reuse `_LazyKeyState` instances instead of allocating new ones

**Implementation**:
```swift
final class _LazyKeyStatePool {
    private var pool: [_LazyKeyState] = []

    func acquire(entry: KSBONJSONMapEntry) -> _LazyKeyState {
        if let state = pool.popLast() {
            state.reset(entry: entry)
            return state
        }
        return _LazyKeyState(entry: entry)
    }

    func release(_ state: _LazyKeyState) {
        pool.append(state)
    }
}
```

**Expected impact**:
- Reduce container creation from 127 ns to ~50 ns
- 60% reduction in container overhead

**Effort**: 2-3 hours
**Risk**: Medium (need careful lifecycle management)

---

### Option C: Specialized Array-of-Struct Decode (Medium-High)

**Change**: Detect `[SomeStruct].self` and share key layout across all elements

**Implementation**:
- First element: build key layout normally
- Subsequent elements: reuse key offsets from first element
- Assumes all elements have same structure (true for typed arrays)

**Expected impact**:
- 30-50% faster for arrays of identical structs
- Container creation done once instead of N times

**Effort**: 1-2 days
**Risk**: Medium (assumption that all elements have same keys)

---

### Option D: Code Generation Macro (High effort, High reward)

**Change**: Swift macro that generates direct decode code

```swift
@BONJSONOptimized
struct Person: Codable {
    var name: String
    var age: Int
}

// Generated:
extension Person {
    static func _bonjsonDecode(from map: _PositionMap, at index: size_t) -> Person {
        // Direct field access, no containers
    }
}
```

**Expected impact**:
- 5-10x faster for annotated types
- Bypasses Codable entirely

**Effort**: 1-2 weeks
**Risk**: High (macro complexity, Swift version requirements)

---

## Recommendation

### Immediate (Today)

1. **Option A**: Increase linear search threshold to 12
   - Simple, low-risk, measurable improvement

### Short-term (This week)

2. **Option B**: Container state pooling
   - Moderate effort, good return
   - Reduces container creation overhead by 60%

### Medium-term (If needed)

3. **Option C**: Array-of-struct specialization
   - Only if profiling shows array-heavy workloads

### Long-term (Future consideration)

4. **Option D**: Code generation
   - For users who need maximum performance
   - Requires significant investment

---

## Success Metrics

Current state: 2.4x faster than JSON

| Optimization | Expected Result |
|--------------|-----------------|
| After Option A | 2.5x faster |
| After Option B | 2.7-2.8x faster |
| After Option C | 3x faster |
| After Option D | 5-10x faster |

---

## Conclusion

BONJSON has achieved excellent performance (2.4x faster than JSON). The remaining optimizations have diminishing returns:

- **Option A** (threshold increase) is a quick win
- **Option B** (pooling) offers moderate improvement
- **Options C & D** are for specialized use cases

The decoder is now production-ready for most workloads.
