# BONJSON Optimization Analysis - Post Phase 2

## Current Performance Summary

**Overall Status: BONJSON is 2.4x faster than Apple's JSON decoder**

| Metric | Value |
|--------|-------|
| Decode 1000 objects (5 fields each) | 480-507 µs |
| Throughput | 53-55 MB/s |
| vs JSON | 2.4x faster |
| Position Map (C) | 80 µs (16% of time) |
| Codable Layer (Swift) | 410 µs (84% of time) |

---

## Detailed Cost Breakdown

### Per-Operation Costs

| Operation | Cost | Notes |
|-----------|------|-------|
| Container creation | 136 ns | Per object, includes `_LazyKeyState` allocation |
| Field lookup (linear, ≤8 fields) | 98 ns | Direct byte comparison |
| Field lookup (dictionary, >8 fields) | 154 ns | Dictionary lookup overhead |
| Nesting overhead | 277 ns | Per extra nesting level |
| String decode (batched) | 17-50 ns | Per string in array |
| Int decode (batched) | 10 ns | Per int in array |
| Double decode (batched) | 10 ns | Per double in array |

### All Primitive Arrays Now Batched

| Array Type | Time (10,000 elements) | Per Element | Status |
|------------|------------------------|-------------|--------|
| `[Int]` | 106 µs | 10 ns | Batched ✓ |
| `[Double]` | 100 µs | 10 ns | Batched ✓ |
| `[String]` | 177 µs | 17 ns | Batched ✓ |

**Ratio: Strings are now only 1.7x slower than integers** (was 21.6x)

---

## Optimization Opportunities (Ranked by Impact)

### 1. ~~HIGH IMPACT: String Array Batch Decode~~ ✓ COMPLETED

**Before:**
- String arrays used element-by-element decoding via `UnkeyedDecodingContainer`
- Each string cost ~216 ns (position map lookup + String creation)
- 10,000 strings: 2.17 ms

**After (Implemented):**
- Added `ksbonjson_map_decodeStringArray()` to C
- Swift creates all strings in a single pass from offset/length pairs
- 10,000 strings: 177 µs (17 ns/str) - **12x faster!**
- 1,000 strings: 50 µs (50 ns/str) - **5x faster!**

---

### 2. MEDIUM IMPACT: Increase Linear Search Threshold

**Current State:**
- Objects with ≤8 fields use linear search (98 ns/field)
- Objects with >8 fields use dictionary (154 ns/field)

**Finding:**
- Linear search is 1.6x faster than dictionary
- Many real-world objects have 10-15 fields

**Proposed Optimization:**
- Increase threshold from 8 to 12 fields
- Profile to find optimal crossover point

**Expected Improvement:**
- 10-20% faster for objects with 9-12 fields

**Effort: Low** (single constant change + profiling)

---

### 3. LOW-MEDIUM IMPACT: Specialized Array-of-Struct Decode

**Current State:**
- Decoding `[SomeStruct].self` creates N separate containers
- Each container allocates `_LazyKeyState` (136 ns)

**Finding:**
- For 1000 objects: 136 µs spent just on container creation
- Same key layout is repeated 1000 times

**Proposed Optimization:**
- Detect when decoding array of identical struct types
- Share key layout information across all elements
- Reuse `_LazyKeyState` instance

**Expected Improvement:**
- 20-30% reduction in array-of-struct decode time
- More impactful for simple structs with few fields

**Effort: Medium-High** (significant decoder changes)

---

### 4. LOW IMPACT: Nested Object Optimization

**Current State:**
- Each nesting level adds ~277 ns overhead
- 3-level nesting: 833 ns vs 279 ns for flat (3x slower)

**Constraint:**
- This is inherent to Codable's design
- Each level requires a new decoder and container

**Possible Approaches:**
- Code generation macro to bypass Codable
- Direct struct construction from position map

**Expected Improvement:**
- 2-3x faster for deeply nested structures
- Only achievable by bypassing Codable

**Effort: High** (requires macro system or alternative API)

---

### 5. LOW IMPACT: Dictionary Optimization for Large Objects

**Current State:**
- Objects with >8 fields use dictionary lookup
- 154 ns per field vs 98 ns for linear search

**Possible Approaches:**
- Pre-compute key hashes in position map
- Use perfect hashing for known key sets
- Inline dictionary for common field counts

**Expected Improvement:**
- Marginal (dictionary is already reasonably fast)

**Effort: Medium-High** (complex implementation)

---

## Recommendations

### Short Term (Easy Wins)

1. **Increase linear search threshold to 12** - Simple change, measure impact
2. **Profile with real-world data structures** - Ensure benchmarks match actual use cases

### Medium Term (Notable Gains)

3. **Implement string array batch decode** - Biggest remaining opportunity
   - Add `ksbonjson_map_getStringOffsets()` to C
   - Swift wrapper creates strings in batch
   - Target: 4-7x improvement for string arrays

### Long Term (Maximum Performance)

4. **Code generation macro** - For users who need maximum speed
   - Generate direct struct construction
   - Bypass Codable entirely for annotated types
   - Target: 5-10x improvement for known types

---

## Current Bottleneck Hierarchy

```
Total Decode Time: 490 µs (100%)
├── C Position Map: 80 µs (16%)
│   └── Very fast, ~330 MB/s
│
└── Swift Codable Layer: 410 µs (84%)
    ├── Container creation: 136 ns × 1000 = 136 µs (28%)
    │   └── _LazyKeyState allocation
    │
    ├── Key lookups: 98 ns × 5000 = 490 µs (100%)
    │   ├── Linear search for small objects
    │   └── Dictionary for large objects
    │
    └── Value extraction: ~10-20 ns per value
        └── Already very fast
```

---

## Comparison with JSON

| Aspect | BONJSON | JSON | Winner |
|--------|---------|------|--------|
| Decode speed | 480 µs | 1.21 ms | BONJSON (2.4x) |
| Data size | 26 KB | 44 KB | BONJSON (41% smaller) |
| Primitive arrays | 10 ns/elem | ~100 ns/elem | BONJSON (10x) |
| String handling | 216 ns/str | ~150 ns/str | JSON (1.4x) |
| Overall throughput | 53 MB/s | 37 MB/s | BONJSON (1.4x) |

**Key Insight:** BONJSON is now faster than JSON in most scenarios. The main weakness is unbatched string array decoding.

---

## Conclusion

BONJSON has achieved its primary optimization goals:
- 2.4x faster than Apple's JSON decoder
- 53 MB/s throughput (target was 50-80 MB/s)

The main remaining optimization opportunity is **string array batch decode**, which could provide 4-7x improvement for string-heavy workloads. Other optimizations have diminishing returns.

For maximum performance beyond what Codable allows, a code generation approach would be needed to bypass the protocol overhead entirely.
