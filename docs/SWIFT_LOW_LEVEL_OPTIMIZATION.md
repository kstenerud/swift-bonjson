# Low-Level Swift Optimization Tips

A summary of optimization techniques gathered from the Swift community, particularly from
[tayloraswift's swift-png project](https://github.com/tayloraswift/swift-png) and the
[Swift Forums discussion](https://forums.swift.org/t/low-level-swift-optimization-tips/37917).

These techniques helped achieve native Swift DEFLATE performance within 15% of system libz.

---

## Table of Contents

1. [Compiler Settings](#compiler-settings)
2. [Memory Layout & Buffers](#memory-layout--buffers)
3. [Dynamic Dispatch Reduction](#dynamic-dispatch-reduction)
4. [Arithmetic & Integer Operations](#arithmetic--integer-operations)
5. [Closures & Capture Lists](#closures--capture-lists)
6. [Loop Optimization](#loop-optimization)
7. [Container Types](#container-types)
8. [Inlining](#inlining)
9. [Traditional C Wisdom That Still Applies](#traditional-c-wisdom-that-still-applies)

---

## Compiler Settings

### Optimization Levels

| Flag | Purpose |
|------|---------|
| `-Onone` | Debug builds, preserves debug info |
| `-O` | Performance-focused optimization |
| `-Osize` | Aggressive optimization prioritizing code size |

### Whole Module Optimization (WMO)

Use `-whole-module-optimization` to compile the entire module as one unit. This enables
cross-file optimizations at the cost of longer compile times. With WMO enabled, `internal`
declarations can be automatically devirtualized module-wide.

---

## Memory Layout & Buffers

### Use ManagedBuffer Instead of UnsafeMutableBufferPointer

`ManagedBuffer<Header, Element>` stores the header and element values **inline** within a
single heap allocation. This avoids double indirection that occurs when wrapping buffers
in classes.

**Why it matters:** Element access requires only one pointer dereference, and offsets can
be calculated at compile time.

```swift
// Prefer this - single allocation, inline storage
class MyBuffer: ManagedBuffer<MyHeader, UInt8> { }

// Avoid this - two levels of heap indirection
class MyBuffer {
    var storage: UnsafeMutableBufferPointer<UInt8>
}
```

### Don't Put Count/Capacity in Buffer Headers

Store `count` and `capacity` separately (e.g., in a surrounding struct on the stack)
rather than in the buffer's header structure.

**Why:** These metadata are frequently accessed, while buffer reads/writes follow
streaming patterns moving away from the front. Separating them improves memory access
patterns.

```swift
// Better: metadata on stack, buffer reference separate
struct MyCollection {
    var count: Int        // On stack
    var capacity: Int     // On stack
    var buffer: ManagedBuffer<Void, Element>  // Header is Void
}
```

### Use Shorter Integer Types for Buffer Elements

For large arrays serving as lookup tables, shorter types (`Int32`, `Int16`, `UInt8`)
improve memory locality compared to using `Int` everywhere.

**Guidelines:**
- Class properties: use `Int`
- Struct properties (non-array): use `Int`
- Direct array elements in large buffers: use shorter types, cast at usage site

---

## Dynamic Dispatch Reduction

### Use `final` Keyword

Prevents method/property overriding, enabling direct function calls instead of indirect
vtable lookups:

```swift
final class FastClass {
    var value: Int
    func compute() { }  // Direct call, no vtable lookup
}
```

### Access Control for Optimization

**`private`/`fileprivate`:** Restricts visibility to current file, allowing compiler to
infer `final` automatically and eliminate indirect calls.

```swift
private class InternalHelper {
    func doWork() { }  // Compiler can devirtualize
}
```

**`internal` + WMO:** When Whole Module Optimization is enabled, `internal` declarations
can be devirtualized across the entire module.

### Class-Constrained Protocols

Mark protocols that will only be implemented by classes:

```swift
protocol MyClassProtocol: AnyObject { }  // Enables optimizations
```

---

## Arithmetic & Integer Operations

### Overflow-Checked vs Wrapping Arithmetic

**Surprising finding:** `&+`, `&-`, `&*` are NOT inherently faster than `+`, `-`, `*`.

The overflow check in `+` always takes the same branch (the non-trapping path), so it's
effectively free due to branch prediction. Using wrapping operators can actually
**inhibit** other compiler optimizations.

**Example of inhibited optimization:**
```swift
// With &+, compiler can't assume result is positive
let result = positiveA &+ positiveB  // Could wrap to negative!
// This breaks subsequent bounds check optimizations
```

### Exception: Masking Shift Operators

`&<<` and `&>>` typically **do** outperform non-masking equivalents because shift
operation branches suffer from poor prediction.

```swift
// Prefer masking shifts
let shifted = value &>> 4  // Faster than >>
```

### Truncating Integers

Avoid unnecessary integer truncation. Use the natural integer size unless you have a
specific reason (like memory layout in buffers).

---

## Closures & Capture Lists

### Don't Use Capture Lists Unnecessarily

Non-escaping closures execute like standard function calls. Variable access from enclosing
scopes does **not** require reference counting overhead.

**Problem with unnecessary capture lists:** They force captured variables onto the heap,
incurring allocation and function call overhead.

```swift
// Bad: unnecessary capture list
array.forEach { [someValue] element in
    process(element, someValue)
}

// Good: direct access, no overhead for non-escaping closure
array.forEach { element in
    process(element, someValue)
}
```

**Only use capture lists when:**
- The closure escapes
- You need specific capture semantics (weak/unowned)
- You need to capture a specific value at closure creation time

### Prefer inout Over Capturing for Non-Escaping Closures

When closures don't actually escape, pass variables as `inout` parameters instead of
capturing them. This reduces reference counting overhead.

---

## Loop Optimization

### Don't Manually Vectorize Loops

Swift's compiler excels at automatic loop vectorization. Manual SIMD constructs often
**obstruct** this optimization.

```swift
// Bad: manual SIMD may prevent compiler optimizations
for i in stride(from: 0, to: count, by: 4) {
    let vec = SIMD4<Int>(...)
    // manual vector operations
}

// Good: let compiler vectorize
for i in 0..<count {
    result[i] = a[i] + b[i]
}
```

**To enable auto-vectorization:**
- Keep loop bodies simple and vectorizable
- Avoid trapping operations in hot loops (use `&+` if overflow is impossible)
- Avoid early exits or complex control flow

### Don't Use SIMD Types for Non-SIMD Purposes

Avoid using `SIMD2<Int>` or similar types for index pairs or coordinates when you're not
doing actual SIMD operations. Use tuples or custom types instead for better semantic
clarity and potentially better optimization.

---

## Container Types

### Value Types in Arrays

Use structs/enums instead of classes in arrays when possible:
- Cannot be bridged to NSArray, eliminating bridging overhead
- Avoid reference counting (unless containing reference types)

```swift
// Good: value type, no reference counting
struct Entry {
    var key: Int
    var value: Int
}
var entries: [Entry]
```

### ContiguousArray for Reference Types

When you don't need NSArray bridging:

```swift
var objects: ContiguousArray<MyClass> = [...]
```

### Avoid Dictionary.init(grouping:by:)

As of Swift 5.2+, this initializer exhibits poor performance compared to naive two-pass
bucketing (one pass determining sub-array counts, another populating them).

**Only use when:**
- Processing single-pass sequences
- You specifically need `[Key: [Element]]` output format

### Copy-on-Write Optimization

Use `inout` parameters instead of copy-and-return to avoid triggering COW copies:

```swift
// Inefficient: may copy due to +1 parameter semantics
func append(_ a: [Int]) -> [Int] {
    var a = a
    a.append(1)
    return a
}

// Efficient: no unnecessary copy
func append(_ a: inout [Int]) {
    a.append(1)
}
```

---

## Inlining

### Avoid @inline(__always)

This attribute doesn't universally improve performance. Excessive inlining:
- Increases code size
- Consumes additional CPU instruction cache
- Can actually hurt performance

The compiler typically makes better inlining decisions than manual annotations.

### @inlinable Is Different

`@inlinable` exposes the function body to other modules for potential inlining. This
generally **does** improve performance for hot cross-module calls, but increases binary
size and couples your ABI.

```swift
// Good for hot paths called from other modules
@inlinable
public func fastOperation(_ x: Int) -> Int {
    return x &<< 2
}
```

---

## Traditional C Wisdom That Still Applies

### Memory Locality

Consolidated storage arrays with `Range<Int>` intervals outperform nested arrays:

```swift
// Better memory locality
struct FlatStorage {
    var data: [Element]
    var ranges: [Range<Int>]  // Indices into data
}

// Worse: scattered allocations
var nested: [[Element]]
```

### Lookup Tables

- Small lookup tables (under 512 bytes) in L1 cache beat sequences of 5-6+ arithmetic
  instructions
- Properly-aligned consolidated tables outperform separately-allocated alternatives

### Bit Operations

Bit shifting by multiples of 8 translates to efficient byte-level load/store operations:

```swift
// Efficient: translates to byte load
let byte = (value >> 8) & 0xFF

// Also efficient
let combined = (a << 8) | b
```

---

## Summary: What Works vs What Doesn't

### Do This

- Use `ManagedBuffer` for custom buffer types
- Use `final`, `private`, `fileprivate` to enable devirtualization
- Enable Whole Module Optimization for release builds
- Let the compiler vectorize loops
- Use `inout` parameters for mutation
- Use shorter integer types in large buffer arrays
- Keep hot data in contiguous memory

### Don't Do This

- Don't use `@inline(__always)` liberally
- Don't manually vectorize with SIMD types
- Don't assume `&+` is faster than `+`
- Don't use unnecessary capture lists
- Don't put frequently-accessed metadata in buffer headers
- Don't use `Dictionary.init(grouping:by:)` for performance-critical code

---

## References

- [Swift Forums: Low-level swift optimization tips](https://forums.swift.org/t/low-level-swift-optimization-tips/37917)
- [Apple Swift Optimization Tips](https://github.com/apple/swift/blob/main/docs/OptimizationTips.rst)
- [swift-png Project](https://github.com/tayloraswift/swift-png)
- [swift-png Optimization Notes (archived)](https://github.com/tayloraswift/swift-png/blame/62490efbc1ce5cab1b717391830dd7f31e18f8f1/notes/low-level-swift-optimization.md)
