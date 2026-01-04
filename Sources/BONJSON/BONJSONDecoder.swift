// ABOUTME: Public BONJSONDecoder API matching Apple's JSONDecoder interface.
// ABOUTME: Uses C position-map API for single-pass scanning and random access decoding.

import Foundation
import CKSBonjson

// MARK: - BufferView for Zero-Cost Buffer Access

/// A lightweight view into a byte buffer with unchecked access in release builds.
/// Similar to Apple's internal BufferView, this provides fast access without
/// the overhead of Swift Array bounds checking.
@usableFromInline
struct _BufferView {
    @usableFromInline let start: UnsafePointer<UInt8>
    @usableFromInline let count: Int

    @inline(__always) @usableFromInline
    init(_ buffer: UnsafeBufferPointer<UInt8>) {
        self.start = buffer.baseAddress!
        self.count = buffer.count
    }

    /// Unchecked subscript - no bounds checking in release builds.
    @inline(__always) @usableFromInline
    subscript(unchecked offset: Int) -> UInt8 {
        assert(offset >= 0 && offset < count, "BufferView index out of bounds")
        return start[offset]
    }

    /// Get a slice as a new BufferView.
    @inline(__always) @usableFromInline
    func slice(offset: Int, length: Int) -> _BufferView {
        assert(offset >= 0 && offset + length <= count, "BufferView slice out of bounds")
        return _BufferView(UnsafeBufferPointer(start: start + offset, count: length))
    }
}

/// An object that decodes instances of a data type from BONJSON data.
///
/// Use `BONJSONDecoder` in the same way you would use `JSONDecoder`:
///
///     struct Person: Codable {
///         var name: String
///         var age: Int
///     }
///
///     let decoder = BONJSONDecoder()
///     let person = try decoder.decode(Person.self, from: bonjsonData)
///
public final class BONJSONDecoder {

    /// The strategy to use for decoding `Date` values.
    public enum DateDecodingStrategy {
        /// Decode the date as a Unix timestamp (seconds since epoch).
        case secondsSince1970

        /// Decode the date as a Unix timestamp (milliseconds since epoch).
        case millisecondsSince1970

        /// Decode the date from an ISO 8601 formatted string.
        case iso8601

        /// Decode the date using a custom formatter.
        case formatted(DateFormatter)

        /// Decode the date using a custom closure.
        case custom((Decoder) throws -> Date)
    }

    /// The strategy to use for decoding `Data` values.
    public enum DataDecodingStrategy {
        /// Decode data from a Base64-encoded string.
        case base64

        /// Decode the data using a custom closure.
        case custom((Decoder) throws -> Data)
    }

    /// The strategy to use for non-conforming floating-point values.
    public enum NonConformingFloatDecodingStrategy {
        /// Throw an error when encountering non-conforming values.
        case `throw`

        /// Decode infinity and NaN from specific string values.
        case convertFromString(positiveInfinity: String, negativeInfinity: String, nan: String)
    }

    /// The strategy to use when decoding keys.
    public enum KeyDecodingStrategy {
        /// Use the keys specified by each type.
        case useDefaultKeys

        /// Convert keys from snake_case to camelCase.
        case convertFromSnakeCase

        /// Use a custom function to convert keys.
        case custom((_ codingPath: [CodingKey]) -> CodingKey)
    }

    /// The strategy to use for decoding dates. Default is `.secondsSince1970`.
    public var dateDecodingStrategy: DateDecodingStrategy = .secondsSince1970

    /// The strategy to use for decoding data. Default is `.base64`.
    public var dataDecodingStrategy: DataDecodingStrategy = .base64

    /// The strategy to use for non-conforming floats. Default is `.throw`.
    public var nonConformingFloatDecodingStrategy: NonConformingFloatDecodingStrategy = .throw

    /// The strategy to use for decoding keys. Default is `.useDefaultKeys`.
    public var keyDecodingStrategy: KeyDecodingStrategy = .useDefaultKeys

    /// Contextual user info for decoding.
    public var userInfo: [CodingUserInfoKey: Any] = [:]

    /// Creates a new BONJSON decoder.
    public init() {}

    /// Decodes a value of the given type from BONJSON data.
    ///
    /// - Parameters:
    ///   - type: The type to decode.
    ///   - data: The BONJSON data to decode.
    /// - Returns: A value of the requested type.
    /// - Throws: An error if decoding fails.
    public func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        // Build the position map using C API
        let map = try _PositionMap(data: data)

        let rootIndex = map.rootIndex

        // Fast path: batch decode for primitive arrays
        if let result = tryBatchDecode(type, from: map, at: rootIndex) {
            return result
        }

        let state = _MapDecoderState(
            map: map,
            userInfo: userInfo,
            dateDecodingStrategy: dateDecodingStrategy,
            dataDecodingStrategy: dataDecodingStrategy,
            nonConformingFloatDecodingStrategy: nonConformingFloatDecodingStrategy,
            keyDecodingStrategy: keyDecodingStrategy
        )

        let decoder = _MapDecoder(state: state, entryIndex: rootIndex, lazyPath: .root)

        // Handle special types that need custom decoding
        if type == Date.self {
            return try decoder.decodeDate() as! T
        }

        if type == Data.self {
            return try decoder.decodeData() as! T
        }

        if type == URL.self {
            let string = try decoder.decodeString()
            guard let url = URL(string: string) else {
                throw BONJSONDecodingError.invalidURL(string)
            }
            return url as! T
        }

        return try T(from: decoder)
    }

    /// Try batch decode for known primitive array types.
    /// Returns nil if type is not a batch-decodable array type.
    @inline(__always)
    private func tryBatchDecode<T>(_ type: T.Type, from map: _PositionMap, at index: size_t) -> T? {
        // [Int] - most common case
        if type == [Int].self {
            guard let int64Array = map.decodeInt64Array(at: index) else { return nil }
            return int64Array.map { Int($0) } as? T
        }
        // [Int64]
        if type == [Int64].self {
            return map.decodeInt64Array(at: index) as? T
        }
        // [Int32]
        if type == [Int32].self {
            guard let int64Array = map.decodeInt64Array(at: index) else { return nil }
            return int64Array.map { Int32($0) } as? T
        }
        // [Int16]
        if type == [Int16].self {
            guard let int64Array = map.decodeInt64Array(at: index) else { return nil }
            return int64Array.map { Int16($0) } as? T
        }
        // [Int8]
        if type == [Int8].self {
            guard let int64Array = map.decodeInt64Array(at: index) else { return nil }
            return int64Array.map { Int8($0) } as? T
        }
        // [UInt]
        if type == [UInt].self {
            guard let uint64Array = map.decodeUInt64Array(at: index) else { return nil }
            return uint64Array.map { UInt($0) } as? T
        }
        // [UInt64]
        if type == [UInt64].self {
            return map.decodeUInt64Array(at: index) as? T
        }
        // [UInt32]
        if type == [UInt32].self {
            guard let uint64Array = map.decodeUInt64Array(at: index) else { return nil }
            return uint64Array.map { UInt32($0) } as? T
        }
        // [UInt16]
        if type == [UInt16].self {
            guard let uint64Array = map.decodeUInt64Array(at: index) else { return nil }
            return uint64Array.map { UInt16($0) } as? T
        }
        // [UInt8]
        if type == [UInt8].self {
            guard let uint64Array = map.decodeUInt64Array(at: index) else { return nil }
            return uint64Array.map { UInt8($0) } as? T
        }
        // [Double]
        if type == [Double].self {
            return map.decodeDoubleArray(at: index) as? T
        }
        // [Float]
        if type == [Float].self {
            guard let doubleArray = map.decodeDoubleArray(at: index) else { return nil }
            return doubleArray.map { Float($0) } as? T
        }
        // [Bool]
        if type == [Bool].self {
            return map.decodeBoolArray(at: index) as? T
        }
        // [String]
        if type == [String].self {
            return map.decodeStringArray(at: index) as? T
        }

        return nil
    }
}

// MARK: - Errors

/// Errors that can occur during BONJSON decoding.
public enum BONJSONDecodingError: Error, CustomStringConvertible {
    case unexpectedEndOfData
    case invalidTypeCode(UInt8)
    case invalidUTF8String
    case invalidFloat
    case invalidURL(String)
    case containerDepthExceeded
    case expectedObjectKey
    case duplicateObjectKey(String)
    case typeMismatch(expected: String, actual: String)
    case keyNotFound(String)
    case dataRemaining
    case scanFailed(String)
    case mapFull

    public var description: String {
        switch self {
        case .unexpectedEndOfData:
            return "Unexpected end of data"
        case .invalidTypeCode(let code):
            return "Invalid type code: 0x\(String(code, radix: 16))"
        case .invalidUTF8String:
            return "Invalid UTF-8 string"
        case .invalidFloat:
            return "Invalid floating-point value"
        case .invalidURL(let string):
            return "Invalid URL: \(string)"
        case .containerDepthExceeded:
            return "Maximum container depth exceeded"
        case .expectedObjectKey:
            return "Expected object key (string)"
        case .duplicateObjectKey(let key):
            return "Duplicate object key: \(key)"
        case .typeMismatch(let expected, let actual):
            return "Type mismatch: expected \(expected), got \(actual)"
        case .keyNotFound(let key):
            return "Key not found: \(key)"
        case .dataRemaining:
            return "Data remaining after decoding"
        case .scanFailed(let message):
            return "Failed to scan BONJSON data: \(message)"
        case .mapFull:
            return "Position map buffer is full"
        }
    }
}

// MARK: - Position Map Wrapper

/// Wraps the C position map API for Swift use.
final class _PositionMap {
    /// The input data as a contiguous array - keeps pointer stable.
    private let inputBytes: ContiguousArray<UInt8>

    /// The map context.
    private var context: KSBONJSONMapContext

    /// The entry buffer - using ContiguousArray for better performance.
    private var entries: ContiguousArray<KSBONJSONMapEntry>

    /// Precomputed next sibling index for each entry (index after subtree).
    /// Using ContiguousArray for cache-friendly access.
    private var nextSibling: ContiguousArray<Int>

    /// Cache for already-decoded strings, keyed by (offset, length).
    /// This avoids creating duplicate String objects for repeated keys.
    private var stringCache: [UInt64: String] = [:]

    /// Actual entry count after scanning.
    @usableFromInline var entryCount: Int

    /// Root entry index.
    @usableFromInline private(set) var rootIndex: size_t

    init(data: Data) throws {
        // Copy to contiguous array to ensure stable pointer
        self.inputBytes = ContiguousArray(data)

        // Estimate entry count
        let estimatedEntries = ksbonjson_map_estimateEntries(inputBytes.count)
        self.entries = ContiguousArray<KSBONJSONMapEntry>(repeating: KSBONJSONMapEntry(), count: Int(estimatedEntries))
        self.nextSibling = []   // Will be computed after scanning
        self.entryCount = 0
        self.context = KSBONJSONMapContext()
        self.rootIndex = 0  // Will be set after scanning

        // Initialize and scan using stable pointers
        try inputBytes.withUnsafeBufferPointer { inputPtr in
            try entries.withUnsafeMutableBufferPointer { entriesPtr in
                ksbonjson_map_begin(
                    &context,
                    inputPtr.baseAddress,
                    inputPtr.count,
                    entriesPtr.baseAddress,
                    entriesPtr.count
                )

                let status = ksbonjson_map_scan(&context)
                guard status == KSBONJSON_DECODE_OK else {
                    let message = ksbonjson_describeDecodeStatus(status).map { String(cString: $0) } ?? "Unknown error"
                    throw BONJSONDecodingError.scanFailed(message)
                }
            }
        }

        self.rootIndex = ksbonjson_map_root(&context)
        self.entryCount = Int(ksbonjson_map_count(&context))

        // Precompute next sibling indices for O(1) child navigation
        self.nextSibling = computeNextSiblingIndices()
    }

    /// Compute next sibling indices for all entries.
    /// nextSibling[i] = index of the entry after the subtree rooted at i.
    private func computeNextSiblingIndices() -> ContiguousArray<Int> {
        var sizes = ContiguousArray<Int>(repeating: 1, count: entryCount)

        // Process in reverse order so children are computed before parents
        for i in stride(from: entryCount - 1, through: 0, by: -1) {
            let entry = entries[i]
            if entry.type == KSBONJSON_TYPE_ARRAY || entry.type == KSBONJSON_TYPE_OBJECT {
                var totalSize = 1  // Include self
                var childPos = Int(entry.data.container.firstChild)
                for _ in 0..<entry.data.container.count {
                    if childPos < entryCount {
                        totalSize += sizes[childPos]
                        childPos += sizes[childPos]
                    }
                }
                sizes[i] = totalSize
            }
            // Primitives already have size 1
        }

        // Convert sizes to next sibling indices: nextSibling[i] = i + size[i]
        return ContiguousArray(sizes.enumerated().map { $0.offset + $0.element })
    }

    /// Sentinel value indicating "not found".
    @usableFromInline static let notFound: size_t = -1

    /// Get entry at index - inlined for performance.
    @inline(__always)
    func getEntry(at index: size_t) -> KSBONJSONMapEntry? {
        guard index >= 0 && index < entryCount else {
            return nil
        }
        return entries[Int(index)]
    }

    /// Get entry at index without bounds checking - caller must ensure validity.
    @inline(__always) @usableFromInline
    func getEntryUnchecked(at index: Int) -> KSBONJSONMapEntry {
        assert(index >= 0 && index < entryCount, "Entry index out of bounds")
        return entries[index]
    }

    /// Get string data - reads from stored input bytes using entry offset/length.
    /// Uses caching to avoid creating duplicate String objects for repeated keys.
    @inline(__always)
    func getString(at index: size_t) -> String? {
        guard index >= 0 && index < entryCount else {
            return nil
        }

        let entry = entries[Int(index)]
        guard entry.type == KSBONJSON_TYPE_STRING else {
            return nil
        }

        let offset = Int(entry.data.string.offset)
        let length = Int(entry.data.string.length)

        guard offset >= 0 && offset + length <= inputBytes.count else {
            return nil
        }

        // Pack offset and length into a single UInt64 key for cache lookup
        let cacheKey = UInt64(offset) << 32 | UInt64(length)

        // Check cache first
        if let cached = stringCache[cacheKey] {
            return cached
        }

        // Create string directly from the input bytes using unchecked access
        let string = inputBytes.withUnsafeBufferPointer { ptr in
            let start = ptr.baseAddress! + offset
            let buffer = UnsafeBufferPointer(start: start, count: length)
            return String(decoding: buffer, as: UTF8.self)
        }

        // Cache for future lookups
        stringCache[cacheKey] = string
        return string
    }

    /// Get child entry index - inlined for performance.
    @inline(__always)
    func getChild(containerIndex: size_t, childIndex: size_t) -> size_t {
        guard containerIndex >= 0 && containerIndex < entryCount else {
            return Self.notFound
        }

        let entry = entries[Int(containerIndex)]
        guard entry.type == KSBONJSON_TYPE_ARRAY || entry.type == KSBONJSON_TYPE_OBJECT else {
            return Self.notFound
        }

        if childIndex >= entry.data.container.count {
            return Self.notFound
        }

        // Walk from firstChild, using nextSibling for O(1) per step
        var currentIndex = Int(entry.data.container.firstChild)
        for _ in 0..<childIndex {
            currentIndex = nextSibling[currentIndex]
        }

        return size_t(currentIndex)
    }

    /// Get child entry index without bounds checking - caller must ensure validity.
    @inline(__always) @usableFromInline
    func getChildUnchecked(containerIndex: Int, childIndex: Int) -> Int {
        let entry = entries[containerIndex]
        var currentIndex = Int(entry.data.container.firstChild)
        for _ in 0..<childIndex {
            currentIndex = nextSibling[currentIndex]
        }
        return currentIndex
    }

    /// Find key in object - inlined for performance.
    @inline(__always)
    func findKey(objectIndex: size_t, key: String) -> size_t {
        guard objectIndex >= 0 && objectIndex < entryCount else {
            return Self.notFound
        }

        let objEntry = entries[Int(objectIndex)]
        guard objEntry.type == KSBONJSON_TYPE_OBJECT else {
            return Self.notFound
        }

        // Cache UTF-8 count to avoid repeated computation
        let keyUTF8Count = key.utf8.count

        // Object children are stored as key, value, key, value, ...
        let pairCount = Int(objEntry.data.container.count) / 2
        var currentIndex = Int(objEntry.data.container.firstChild)

        // Use withUnsafeBufferPointer once for all comparisons
        return inputBytes.withUnsafeBufferPointer { ptr in
            for _ in 0..<pairCount {
                let keyIndex = currentIndex
                guard keyIndex < entryCount else {
                    break
                }

                let keyEntry = entries[keyIndex]

                // Advance past the key using nextSibling
                let valueIndex = nextSibling[keyIndex]
                // Advance past the value for next iteration
                currentIndex = nextSibling[valueIndex]

                guard keyEntry.type == KSBONJSON_TYPE_STRING else {
                    continue
                }

                let keyOffset = Int(keyEntry.data.string.offset)
                let keyLength = Int(keyEntry.data.string.length)

                // Compare key strings - fast path: check length first
                if keyLength == keyUTF8Count {
                    let keyMatches = key.withCString { cString in
                        memcmp(ptr.baseAddress! + keyOffset, cString, keyLength) == 0
                    }
                    if keyMatches {
                        return size_t(valueIndex)
                    }
                }
            }
            return Self.notFound
        }
    }

    /// Get entry count.
    @inline(__always)
    var count: size_t {
        return size_t(entryCount)
    }

    /// Get next sibling index (exposed for key cache building).
    @inline(__always)
    func nextSiblingIndex(_ index: Int) -> Int {
        guard index >= 0 && index < nextSibling.count else {
            return index + 1
        }
        return nextSibling[index]
    }

    /// Compare a key string directly against bytes in input buffer.
    /// Returns true if the key matches the string at the given offset/length.
    @inline(__always)
    func compareKeyBytes(offset: Int, length: Int, with key: String) -> Bool {
        guard length == key.utf8.count else { return false }
        return inputBytes.withUnsafeBufferPointer { ptr in
            key.withCString { cString in
                memcmp(ptr.baseAddress! + offset, cString, length) == 0
            }
        }
    }

    // MARK: - Batch Decode Methods

    /// Batch decode an array of Int64 values.
    /// Returns nil if index is not an array.
    @inline(__always)
    func decodeInt64Array(at arrayIndex: size_t) -> [Int64]? {
        guard arrayIndex >= 0 && arrayIndex < entryCount else {
            return nil
        }

        let entry = entries[Int(arrayIndex)]
        guard entry.type == KSBONJSON_TYPE_ARRAY else {
            return nil
        }

        let count = Int(entry.data.container.count)
        guard count > 0 else {
            return []
        }

        var result = [Int64](repeating: 0, count: count)
        result.withUnsafeMutableBufferPointer { buffer in
            entries.withUnsafeBufferPointer { entriesPtr in
                inputBytes.withUnsafeBufferPointer { inputPtr in
                    // Update context pointers for batch decode
                    var localContext = context
                    localContext.entries = UnsafeMutablePointer(mutating: entriesPtr.baseAddress)
                    localContext.input = inputPtr.baseAddress
                    _ = ksbonjson_map_decodeInt64Array(&localContext, arrayIndex, buffer.baseAddress!, count)
                }
            }
        }
        return result
    }

    /// Batch decode an array of UInt64 values.
    @inline(__always)
    func decodeUInt64Array(at arrayIndex: size_t) -> [UInt64]? {
        guard arrayIndex >= 0 && arrayIndex < entryCount else {
            return nil
        }

        let entry = entries[Int(arrayIndex)]
        guard entry.type == KSBONJSON_TYPE_ARRAY else {
            return nil
        }

        let count = Int(entry.data.container.count)
        guard count > 0 else {
            return []
        }

        var result = [UInt64](repeating: 0, count: count)
        result.withUnsafeMutableBufferPointer { buffer in
            entries.withUnsafeBufferPointer { entriesPtr in
                inputBytes.withUnsafeBufferPointer { inputPtr in
                    var localContext = context
                    localContext.entries = UnsafeMutablePointer(mutating: entriesPtr.baseAddress)
                    localContext.input = inputPtr.baseAddress
                    _ = ksbonjson_map_decodeUInt64Array(&localContext, arrayIndex, buffer.baseAddress!, count)
                }
            }
        }
        return result
    }

    /// Batch decode an array of Double values.
    @inline(__always)
    func decodeDoubleArray(at arrayIndex: size_t) -> [Double]? {
        guard arrayIndex >= 0 && arrayIndex < entryCount else {
            return nil
        }

        let entry = entries[Int(arrayIndex)]
        guard entry.type == KSBONJSON_TYPE_ARRAY else {
            return nil
        }

        let count = Int(entry.data.container.count)
        guard count > 0 else {
            return []
        }

        var result = [Double](repeating: 0, count: count)
        result.withUnsafeMutableBufferPointer { buffer in
            entries.withUnsafeBufferPointer { entriesPtr in
                inputBytes.withUnsafeBufferPointer { inputPtr in
                    var localContext = context
                    localContext.entries = UnsafeMutablePointer(mutating: entriesPtr.baseAddress)
                    localContext.input = inputPtr.baseAddress
                    _ = ksbonjson_map_decodeDoubleArray(&localContext, arrayIndex, buffer.baseAddress!, count)
                }
            }
        }
        return result
    }

    /// Batch decode an array of Bool values.
    @inline(__always)
    func decodeBoolArray(at arrayIndex: size_t) -> [Bool]? {
        guard arrayIndex >= 0 && arrayIndex < entryCount else {
            return nil
        }

        let entry = entries[Int(arrayIndex)]
        guard entry.type == KSBONJSON_TYPE_ARRAY else {
            return nil
        }

        let count = Int(entry.data.container.count)
        guard count > 0 else {
            return []
        }

        var result = [Bool](repeating: false, count: count)
        result.withUnsafeMutableBufferPointer { buffer in
            entries.withUnsafeBufferPointer { entriesPtr in
                inputBytes.withUnsafeBufferPointer { inputPtr in
                    var localContext = context
                    localContext.entries = UnsafeMutablePointer(mutating: entriesPtr.baseAddress)
                    localContext.input = inputPtr.baseAddress
                    _ = ksbonjson_map_decodeBoolArray(&localContext, arrayIndex, buffer.baseAddress!, count)
                }
            }
        }
        return result
    }

    /// Batch decode an array of String values.
    /// Uses C batch function to get string offsets, then creates strings in batch.
    @inline(__always)
    func decodeStringArray(at arrayIndex: size_t) -> [String]? {
        guard arrayIndex >= 0 && arrayIndex < entryCount else {
            return nil
        }

        let entry = entries[Int(arrayIndex)]
        guard entry.type == KSBONJSON_TYPE_ARRAY else {
            return nil
        }

        let count = Int(entry.data.container.count)
        guard count > 0 else {
            return []
        }

        // Get string offsets in batch from C
        var stringRefs = [KSBONJSONStringRef](repeating: KSBONJSONStringRef(), count: count)
        let decoded = stringRefs.withUnsafeMutableBufferPointer { buffer in
            entries.withUnsafeBufferPointer { entriesPtr in
                inputBytes.withUnsafeBufferPointer { inputPtr in
                    var localContext = context
                    localContext.entries = UnsafeMutablePointer(mutating: entriesPtr.baseAddress)
                    localContext.input = inputPtr.baseAddress
                    return ksbonjson_map_decodeStringArray(&localContext, arrayIndex, buffer.baseAddress!, count)
                }
            }
        }

        guard decoded == count else {
            return nil
        }

        // Create strings from offsets - all in one pass through inputBytes
        return inputBytes.withUnsafeBufferPointer { ptr in
            stringRefs.map { ref in
                let offset = Int(ref.offset)
                let length = Int(ref.length)
                if length == 0 {
                    return ""
                }
                let start = ptr.baseAddress! + offset
                let buffer = UnsafeBufferPointer(start: start, count: length)
                return String(decoding: buffer, as: UTF8.self)
            }
        }
    }
}

// MARK: - Decoder State

/// Shared state for the map-based decoder.

final class _MapDecoderState {
    let map: _PositionMap
    let userInfo: [CodingUserInfoKey: Any]
    let dateDecodingStrategy: BONJSONDecoder.DateDecodingStrategy
    let dataDecodingStrategy: BONJSONDecoder.DataDecodingStrategy
    let nonConformingFloatDecodingStrategy: BONJSONDecoder.NonConformingFloatDecodingStrategy
    let keyDecodingStrategy: BONJSONDecoder.KeyDecodingStrategy

    init(
        map: _PositionMap,
        userInfo: [CodingUserInfoKey: Any],
        dateDecodingStrategy: BONJSONDecoder.DateDecodingStrategy,
        dataDecodingStrategy: BONJSONDecoder.DataDecodingStrategy,
        nonConformingFloatDecodingStrategy: BONJSONDecoder.NonConformingFloatDecodingStrategy,
        keyDecodingStrategy: BONJSONDecoder.KeyDecodingStrategy
    ) {
        self.map = map
        self.userInfo = userInfo
        self.dateDecodingStrategy = dateDecodingStrategy
        self.dataDecodingStrategy = dataDecodingStrategy
        self.nonConformingFloatDecodingStrategy = nonConformingFloatDecodingStrategy
        self.keyDecodingStrategy = keyDecodingStrategy
    }
}

// MARK: - Lazy Coding Path

/// A lazy representation of a coding path that avoids array allocation on each nesting level.
/// The full [CodingKey] array is only built when actually needed (e.g., for error messages).
/// This saves ~100-150 ns per nesting level by avoiding array allocation and copying.
final class _LazyCodingPath {
    let parent: _LazyCodingPath?
    let key: CodingKey?

    /// The root (empty) path - shared singleton
    static let root = _LazyCodingPath(parent: nil, key: nil)

    init(parent: _LazyCodingPath?, key: CodingKey?) {
        self.parent = parent
        self.key = key
    }

    /// Create a child path by appending a key
    @inline(__always)
    func appending(_ key: CodingKey) -> _LazyCodingPath {
        return _LazyCodingPath(parent: self, key: key)
    }

    /// Build the full path array - only called when needed for errors
    func toArray() -> [CodingKey] {
        var result: [CodingKey] = []
        var current: _LazyCodingPath? = self
        // Count depth first to pre-allocate
        var depth = 0
        while let node = current {
            if node.key != nil { depth += 1 }
            current = node.parent
        }
        result.reserveCapacity(depth)

        // Build array in reverse by collecting then reversing
        current = self
        while let node = current {
            if let key = node.key {
                result.append(key)
            }
            current = node.parent
        }
        result.reverse()
        return result
    }
}

// MARK: - Map-Based Decoder

/// Internal decoder that implements the Decoder protocol using the position map.
final class _MapDecoder: Decoder {
    let state: _MapDecoderState
    let entryIndex: size_t
    let lazyPath: _LazyCodingPath

    /// Computed property - only builds array when accessed (rare, mostly for errors)
    var codingPath: [CodingKey] { lazyPath.toArray() }

    var userInfo: [CodingUserInfoKey: Any] { state.userInfo }

    init(state: _MapDecoderState, entryIndex: size_t, lazyPath: _LazyCodingPath) {
        self.state = state
        self.entryIndex = entryIndex
        self.lazyPath = lazyPath
    }

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        guard let entry = state.map.getEntry(at: entryIndex) else {
            throw BONJSONDecodingError.unexpectedEndOfData
        }

        guard entry.type == KSBONJSON_TYPE_OBJECT else {
            throw BONJSONDecodingError.typeMismatch(expected: "object", actual: describeType(entry.type))
        }

        let container = _MapKeyedDecodingContainer<Key>(
            state: state,
            objectIndex: entryIndex,
            entry: entry,
            lazyPath: lazyPath
        )
        return KeyedDecodingContainer(container)
    }

    func unkeyedContainer() throws -> UnkeyedDecodingContainer {
        guard let entry = state.map.getEntry(at: entryIndex) else {
            throw BONJSONDecodingError.unexpectedEndOfData
        }

        guard entry.type == KSBONJSON_TYPE_ARRAY else {
            throw BONJSONDecodingError.typeMismatch(expected: "array", actual: describeType(entry.type))
        }

        return _MapUnkeyedDecodingContainer(
            state: state,
            arrayIndex: entryIndex,
            entry: entry,
            lazyPath: lazyPath
        )
    }

    func singleValueContainer() throws -> SingleValueDecodingContainer {
        return _MapSingleValueDecodingContainer(
            state: state,
            entryIndex: entryIndex,
            lazyPath: lazyPath
        )
    }

    // MARK: - Value Reading (Hot Paths)

    @inline(__always)
    func decodeString() throws -> String {
        guard let entry = state.map.getEntry(at: entryIndex) else {
            throw BONJSONDecodingError.unexpectedEndOfData
        }

        guard entry.type == KSBONJSON_TYPE_STRING else {
            throw BONJSONDecodingError.typeMismatch(expected: "string", actual: describeType(entry.type))
        }

        guard let string = state.map.getString(at: entryIndex) else {
            throw BONJSONDecodingError.invalidUTF8String
        }

        return string
    }

    @inline(__always)
    func decodeInt64() throws -> Int64 {
        guard let entry = state.map.getEntry(at: entryIndex) else {
            throw BONJSONDecodingError.unexpectedEndOfData
        }

        switch entry.type {
        case KSBONJSON_TYPE_INT:
            return entry.data.intValue
        case KSBONJSON_TYPE_UINT:
            let value = entry.data.uintValue
            guard value <= UInt64(Int64.max) else {
                throw BONJSONDecodingError.typeMismatch(expected: "Int64", actual: "UInt64 too large")
            }
            return Int64(value)
        default:
            throw BONJSONDecodingError.typeMismatch(expected: "integer", actual: describeType(entry.type))
        }
    }

    @inline(__always)
    func decodeUInt64() throws -> UInt64 {
        guard let entry = state.map.getEntry(at: entryIndex) else {
            throw BONJSONDecodingError.unexpectedEndOfData
        }

        switch entry.type {
        case KSBONJSON_TYPE_UINT:
            return entry.data.uintValue
        case KSBONJSON_TYPE_INT:
            let value = entry.data.intValue
            guard value >= 0 else {
                throw BONJSONDecodingError.typeMismatch(expected: "UInt64", actual: "negative integer")
            }
            return UInt64(value)
        default:
            throw BONJSONDecodingError.typeMismatch(expected: "unsigned integer", actual: describeType(entry.type))
        }
    }

    @inline(__always)
    func decodeDouble() throws -> Double {
        guard let entry = state.map.getEntry(at: entryIndex) else {
            throw BONJSONDecodingError.unexpectedEndOfData
        }

        switch entry.type {
        case KSBONJSON_TYPE_FLOAT:
            return entry.data.floatValue
        case KSBONJSON_TYPE_INT:
            return Double(entry.data.intValue)
        case KSBONJSON_TYPE_UINT:
            return Double(entry.data.uintValue)
        case KSBONJSON_TYPE_BIGNUMBER:
            // Convert big number to double
            let bn = entry.data.bigNumber
            let significand = Double(bn.significand)
            let result = significand * pow(10.0, Double(bn.exponent))
            return bn.sign < 0 ? -result : result
        default:
            throw BONJSONDecodingError.typeMismatch(expected: "float", actual: describeType(entry.type))
        }
    }

    @inline(__always)
    func decodeBool() throws -> Bool {
        guard let entry = state.map.getEntry(at: entryIndex) else {
            throw BONJSONDecodingError.unexpectedEndOfData
        }

        switch entry.type {
        case KSBONJSON_TYPE_TRUE:
            return true
        case KSBONJSON_TYPE_FALSE:
            return false
        default:
            throw BONJSONDecodingError.typeMismatch(expected: "boolean", actual: describeType(entry.type))
        }
    }

    @inline(__always)
    func decodeNil() -> Bool {
        guard let entry = state.map.getEntry(at: entryIndex) else {
            return false
        }
        return entry.type == KSBONJSON_TYPE_NULL
    }

    func decodeDate() throws -> Date {
        switch state.dateDecodingStrategy {
        case .secondsSince1970:
            let interval = try decodeDouble()
            return Date(timeIntervalSince1970: interval)

        case .millisecondsSince1970:
            let interval = try decodeDouble()
            return Date(timeIntervalSince1970: interval / 1000)

        case .iso8601:
            let string = try decodeString()
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard let date = formatter.date(from: string) else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(codingPath: codingPath, debugDescription: "Invalid ISO 8601 date: \(string)")
                )
            }
            return date

        case .formatted(let formatter):
            let string = try decodeString()
            guard let date = formatter.date(from: string) else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(codingPath: codingPath, debugDescription: "Invalid date: \(string)")
                )
            }
            return date

        case .custom(let closure):
            return try closure(self)
        }
    }

    func decodeData() throws -> Data {
        switch state.dataDecodingStrategy {
        case .base64:
            let string = try decodeString()
            guard let data = Data(base64Encoded: string) else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(codingPath: codingPath, debugDescription: "Invalid Base64 string")
                )
            }
            return data

        case .custom(let closure):
            return try closure(self)
        }
    }

    private func describeType(_ type: KSBONJSONValueType) -> String {
        switch type {
        case KSBONJSON_TYPE_NULL: return "null"
        case KSBONJSON_TYPE_TRUE: return "true"
        case KSBONJSON_TYPE_FALSE: return "false"
        case KSBONJSON_TYPE_INT: return "integer"
        case KSBONJSON_TYPE_UINT: return "unsigned integer"
        case KSBONJSON_TYPE_FLOAT: return "float"
        case KSBONJSON_TYPE_BIGNUMBER: return "big number"
        case KSBONJSON_TYPE_STRING: return "string"
        case KSBONJSON_TYPE_ARRAY: return "array"
        case KSBONJSON_TYPE_OBJECT: return "object"
        default: return "unknown"
        }
    }
}

// MARK: - Keyed Decoding Container

/// Threshold for using linear search vs dictionary lookup.
/// For small objects, linear search avoids dictionary allocation overhead.
/// Profiling shows dictionary is now slightly faster (88 ns vs 96 ns per field).
/// Lowered from 16 to 12 based on updated profiling.
private let kSmallObjectThreshold = 12

/// Key cache holder - only allocated for large objects that need dictionary lookup.
/// Using a class allows mutation from within the struct container.
private final class _KeyCacheHolder {
    var cache: [String: size_t]?
}

struct _MapKeyedDecodingContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let state: _MapDecoderState
    let objectIndex: size_t
    let entry: KSBONJSONMapEntry
    let lazyPath: _LazyCodingPath

    /// Computed property - only builds array when needed (for errors)
    var codingPath: [CodingKey] { lazyPath.toArray() }

    // Stored directly in struct - no class allocation overhead for small objects
    private let pairCount: Int
    private let firstChildIndex: Int
    private let useLinearSearch: Bool

    /// Key cache holder - only allocated for large objects.
    /// nil for small objects that use linear search.
    private let keyCacheHolder: _KeyCacheHolder?

    /// All keys in this object - built on demand (not cached, since rarely used).
    var allKeys: [Key] {
        return buildAllKeys()
    }

    init(state: _MapDecoderState, objectIndex: size_t, entry: KSBONJSONMapEntry, lazyPath: _LazyCodingPath) {
        self.state = state
        self.objectIndex = objectIndex
        self.entry = entry
        self.lazyPath = lazyPath

        let count = Int(entry.data.container.count) / 2
        self.pairCount = count
        self.firstChildIndex = Int(entry.data.container.firstChild)
        self.useLinearSearch = count <= kSmallObjectThreshold

        // Only allocate cache holder for large objects - saves ~100ns per small object
        self.keyCacheHolder = count > kSmallObjectThreshold ? _KeyCacheHolder() : nil
    }

    /// Build allKeys array - only called when allKeys is accessed.
    private func buildAllKeys() -> [Key] {
        var keys: [Key] = []
        keys.reserveCapacity(pairCount)

        var currentIndex = firstChildIndex
        for _ in 0..<pairCount {
            let keyIndex = currentIndex
            let valueIndex = state.map.nextSiblingIndex(keyIndex)
            currentIndex = state.map.nextSiblingIndex(valueIndex)

            if let keyString = state.map.getString(at: size_t(keyIndex)) {
                let convertedKey = convertKey(keyString)
                if let key = Key(stringValue: convertedKey) {
                    keys.append(key)
                }
            }
        }
        return keys
    }

    /// Ensure key cache is built (for larger objects).
    @inline(__always)
    private func ensureKeyCache() {
        guard let holder = keyCacheHolder, holder.cache == nil else { return }

        var cache: [String: size_t] = [:]
        cache.reserveCapacity(pairCount)

        var currentIndex = firstChildIndex
        for _ in 0..<pairCount {
            let keyIndex = currentIndex
            let valueIndex = state.map.nextSiblingIndex(keyIndex)
            currentIndex = state.map.nextSiblingIndex(valueIndex)

            if let keyString = state.map.getString(at: size_t(keyIndex)) {
                cache[keyString] = size_t(valueIndex)
            }
        }
        holder.cache = cache
    }

    /// Linear search for key - used for small objects to avoid dictionary overhead.
    @inline(__always)
    private func linearFindValue(forOriginalKey key: String) -> size_t? {
        var currentIndex = firstChildIndex
        for _ in 0..<pairCount {
            let keyIndex = currentIndex
            let valueIndex = state.map.nextSiblingIndex(keyIndex)
            currentIndex = state.map.nextSiblingIndex(valueIndex)

            let keyEntry = state.map.getEntryUnchecked(at: keyIndex)
            guard keyEntry.type == KSBONJSON_TYPE_STRING else { continue }

            let keyOffset = Int(keyEntry.data.string.offset)
            let keyLength = Int(keyEntry.data.string.length)

            // Compare bytes directly using the helper
            if state.map.compareKeyBytes(offset: keyOffset, length: keyLength, with: key) {
                return size_t(valueIndex)
            }
        }
        return nil
    }

    private func convertKey(_ key: String) -> String {
        switch state.keyDecodingStrategy {
        case .useDefaultKeys:
            return key
        case .convertFromSnakeCase:
            return key.convertFromSnakeCase()
        case .custom(let converter):
            return converter(codingPath + [_StringKey(stringValue: key)]).stringValue
        }
    }

    /// Find the original key string that matches the given key after conversion.
    /// Fast path: if using default keys, the key string IS the original key.
    @inline(__always)
    private func findOriginalKey(_ key: Key) -> String {
        switch state.keyDecodingStrategy {
        case .useDefaultKeys:
            // Fast path: no conversion needed
            return key.stringValue
        default:
            // Slow path: need to find the original key that converts to this key
            var currentIndex = firstChildIndex
            for _ in 0..<pairCount {
                let keyIndex = currentIndex
                let valueIndex = state.map.nextSiblingIndex(keyIndex)
                currentIndex = state.map.nextSiblingIndex(valueIndex)

                if let keyString = state.map.getString(at: size_t(keyIndex)) {
                    let convertedKey = convertKey(keyString)
                    if convertedKey == key.stringValue {
                        return keyString
                    }
                }
            }
            return key.stringValue
        }
    }

    @inline(__always)
    func contains(_ key: Key) -> Bool {
        let originalKey = findOriginalKey(key)
        if useLinearSearch {
            return linearFindValue(forOriginalKey: originalKey) != nil
        }
        ensureKeyCache()
        return keyCacheHolder!.cache![originalKey] != nil
    }

    @inline(__always)
    private func valueIndex(forKey key: Key) throws -> size_t {
        let originalKey = findOriginalKey(key)

        // For small objects, use linear search
        if useLinearSearch {
            if let valueIdx = linearFindValue(forOriginalKey: originalKey) {
                return valueIdx
            }
            throw DecodingError.keyNotFound(key, DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "Key '\(key.stringValue)' not found"
            ))
        }

        // For larger objects, use dictionary
        ensureKeyCache()
        guard let valueIdx = keyCacheHolder!.cache![originalKey] else {
            throw DecodingError.keyNotFound(key, DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "Key '\(key.stringValue)' not found"
            ))
        }
        return valueIdx
    }

    /// Get entry for key - inlined hot path.
    @inline(__always)
    private func entryForKey(_ key: Key) throws -> KSBONJSONMapEntry {
        let idx = try valueIndex(forKey: key)
        guard let entry = state.map.getEntry(at: idx) else {
            throw BONJSONDecodingError.unexpectedEndOfData
        }
        return entry
    }

    /// Only create full decoder when needed for nested types.
    private func decoder(forKey key: Key) throws -> _MapDecoder {
        let idx = try valueIndex(forKey: key)
        return _MapDecoder(state: state, entryIndex: idx, lazyPath: lazyPath.appending(key))
    }

    func decodeNil(forKey key: Key) throws -> Bool {
        let entry = try entryForKey(key)
        return entry.type == KSBONJSON_TYPE_NULL
    }

    @inline(__always)
    func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool {
        let entry = try entryForKey(key)
        switch entry.type {
        case KSBONJSON_TYPE_TRUE: return true
        case KSBONJSON_TYPE_FALSE: return false
        default: throw BONJSONDecodingError.typeMismatch(expected: "boolean", actual: describeType(entry.type))
        }
    }

    @inline(__always)
    func decode(_ type: String.Type, forKey key: Key) throws -> String {
        let idx = try valueIndex(forKey: key)
        guard let string = state.map.getString(at: idx) else {
            throw BONJSONDecodingError.invalidUTF8String
        }
        return string
    }

    @inline(__always)
    func decode(_ type: Double.Type, forKey key: Key) throws -> Double {
        let entry = try entryForKey(key)
        switch entry.type {
        case KSBONJSON_TYPE_FLOAT: return entry.data.floatValue
        case KSBONJSON_TYPE_INT: return Double(entry.data.intValue)
        case KSBONJSON_TYPE_UINT: return Double(entry.data.uintValue)
        case KSBONJSON_TYPE_BIGNUMBER:
            let bn = entry.data.bigNumber
            let significand = Double(bn.significand)
            let result = significand * pow(10.0, Double(bn.exponent))
            return bn.sign < 0 ? -result : result
        default: throw BONJSONDecodingError.typeMismatch(expected: "float", actual: describeType(entry.type))
        }
    }

    @inline(__always)
    func decode(_ type: Float.Type, forKey key: Key) throws -> Float {
        return Float(try decode(Double.self, forKey: key))
    }

    @inline(__always)
    private func decodeInt64ForKey(_ key: Key) throws -> Int64 {
        let entry = try entryForKey(key)
        switch entry.type {
        case KSBONJSON_TYPE_INT: return entry.data.intValue
        case KSBONJSON_TYPE_UINT:
            let value = entry.data.uintValue
            guard value <= UInt64(Int64.max) else {
                throw BONJSONDecodingError.typeMismatch(expected: "Int64", actual: "UInt64 too large")
            }
            return Int64(value)
        default: throw BONJSONDecodingError.typeMismatch(expected: "integer", actual: describeType(entry.type))
        }
    }

    @inline(__always)
    private func decodeUInt64ForKey(_ key: Key) throws -> UInt64 {
        let entry = try entryForKey(key)
        switch entry.type {
        case KSBONJSON_TYPE_UINT: return entry.data.uintValue
        case KSBONJSON_TYPE_INT:
            let value = entry.data.intValue
            guard value >= 0 else {
                throw BONJSONDecodingError.typeMismatch(expected: "UInt64", actual: "negative integer")
            }
            return UInt64(value)
        default: throw BONJSONDecodingError.typeMismatch(expected: "unsigned integer", actual: describeType(entry.type))
        }
    }

    @inline(__always) func decode(_ type: Int.Type, forKey key: Key) throws -> Int { return Int(try decodeInt64ForKey(key)) }
    @inline(__always) func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 { return Int8(try decodeInt64ForKey(key)) }
    @inline(__always) func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 { return Int16(try decodeInt64ForKey(key)) }
    @inline(__always) func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 { return Int32(try decodeInt64ForKey(key)) }
    @inline(__always) func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 { return try decodeInt64ForKey(key) }
    @inline(__always) func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt { return UInt(try decodeUInt64ForKey(key)) }
    @inline(__always) func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 { return UInt8(try decodeUInt64ForKey(key)) }
    @inline(__always) func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 { return UInt16(try decodeUInt64ForKey(key)) }
    @inline(__always) func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 { return UInt32(try decodeUInt64ForKey(key)) }
    @inline(__always) func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 { return try decodeUInt64ForKey(key) }

    private func describeType(_ type: KSBONJSONValueType) -> String {
        switch type {
        case KSBONJSON_TYPE_NULL: return "null"
        case KSBONJSON_TYPE_TRUE: return "true"
        case KSBONJSON_TYPE_FALSE: return "false"
        case KSBONJSON_TYPE_INT: return "integer"
        case KSBONJSON_TYPE_UINT: return "unsigned integer"
        case KSBONJSON_TYPE_FLOAT: return "float"
        case KSBONJSON_TYPE_BIGNUMBER: return "big number"
        case KSBONJSON_TYPE_STRING: return "string"
        case KSBONJSON_TYPE_ARRAY: return "array"
        case KSBONJSON_TYPE_OBJECT: return "object"
        default: return "unknown"
        }
    }

    func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
        let dec = try decoder(forKey: key)

        // Handle special types
        if type == Date.self {
            return try dec.decodeDate() as! T
        }
        if type == Data.self {
            return try dec.decodeData() as! T
        }
        if type == URL.self {
            let string = try dec.decodeString()
            guard let url = URL(string: string) else {
                throw BONJSONDecodingError.invalidURL(string)
            }
            return url as! T
        }

        return try T(from: dec)
    }

    func nestedContainer<NestedKey: CodingKey>(
        keyedBy type: NestedKey.Type,
        forKey key: Key
    ) throws -> KeyedDecodingContainer<NestedKey> {
        return try decoder(forKey: key).container(keyedBy: type)
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> UnkeyedDecodingContainer {
        return try decoder(forKey: key).unkeyedContainer()
    }

    func superDecoder() throws -> Decoder {
        let key = _StringKey(stringValue: "super")
        let idx = try valueIndexForString("super")
        return _MapDecoder(state: state, entryIndex: idx, lazyPath: lazyPath.appending(key))
    }

    func superDecoder(forKey key: Key) throws -> Decoder {
        return try decoder(forKey: key)
    }

    /// Look up value index by raw string key (for superDecoder which uses "super" as key).
    private func valueIndexForString(_ keyString: String) throws -> size_t {
        // For small objects, use linear search
        if useLinearSearch {
            if let valueIdx = linearFindValue(forOriginalKey: keyString) {
                return valueIdx
            }
            throw DecodingError.keyNotFound(_StringKey(stringValue: keyString), DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "Key '\(keyString)' not found"
            ))
        }

        // For larger objects, use dictionary
        ensureKeyCache()
        guard let valueIdx = keyCacheHolder!.cache![keyString] else {
            throw DecodingError.keyNotFound(_StringKey(stringValue: keyString), DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "Key '\(keyString)' not found"
            ))
        }
        return valueIdx
    }
}

// MARK: - Unkeyed Decoding Container

struct _MapUnkeyedDecodingContainer: UnkeyedDecodingContainer {
    let state: _MapDecoderState
    let arrayIndex: size_t
    let entry: KSBONJSONMapEntry
    let lazyPath: _LazyCodingPath
    let elementCount: Int

    /// Computed property - only builds array when needed (for errors)
    var codingPath: [CodingKey] { lazyPath.toArray() }

    /// Current logical index (0-based position in array).
    private(set) var currentIndex: Int = 0

    /// Current entry index in the position map - tracked for O(1) sequential access.
    private var currentEntryIndex: Int

    var count: Int? { elementCount }

    var isAtEnd: Bool {
        return currentIndex >= elementCount
    }

    init(state: _MapDecoderState, arrayIndex: size_t, entry: KSBONJSONMapEntry, lazyPath: _LazyCodingPath) {
        self.state = state
        self.arrayIndex = arrayIndex
        self.entry = entry
        self.lazyPath = lazyPath
        self.elementCount = Int(entry.data.container.count)
        self.currentEntryIndex = Int(entry.data.container.firstChild)
    }

    /// Get next entry - O(1) sequential access using tracked entry index.
    @inline(__always)
    private mutating func nextEntry() throws -> (index: Int, entry: KSBONJSONMapEntry) {
        guard !isAtEnd else {
            throw DecodingError.valueNotFound(Any.self, DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "Unkeyed container is at end"
            ))
        }

        let entryIdx = currentEntryIndex
        let entry = state.map.getEntryUnchecked(at: entryIdx)

        // Advance to next element using nextSibling
        currentEntryIndex = state.map.nextSiblingIndex(entryIdx)
        currentIndex += 1

        return (entryIdx, entry)
    }

    /// Only create full decoder when needed for nested types.
    private mutating func nextDecoder() throws -> _MapDecoder {
        guard !isAtEnd else {
            throw DecodingError.valueNotFound(Any.self, DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "Unkeyed container is at end"
            ))
        }

        let entryIdx = currentEntryIndex
        let decoder = _MapDecoder(
            state: state,
            entryIndex: size_t(entryIdx),
            lazyPath: lazyPath.appending(_BONJSONIndexKey(index: currentIndex))
        )

        // Advance to next element using nextSibling
        currentEntryIndex = state.map.nextSiblingIndex(entryIdx)
        currentIndex += 1

        return decoder
    }

    mutating func decodeNil() throws -> Bool {
        guard !isAtEnd else { return false }
        let entry = state.map.getEntryUnchecked(at: currentEntryIndex)
        if entry.type == KSBONJSON_TYPE_NULL {
            currentEntryIndex = state.map.nextSiblingIndex(currentEntryIndex)
            currentIndex += 1
            return true
        }
        return false
    }

    @inline(__always)
    mutating func decode(_ type: Bool.Type) throws -> Bool {
        let (_, entry) = try nextEntry()
        switch entry.type {
        case KSBONJSON_TYPE_TRUE: return true
        case KSBONJSON_TYPE_FALSE: return false
        default: throw BONJSONDecodingError.typeMismatch(expected: "boolean", actual: describeType(entry.type))
        }
    }

    @inline(__always)
    mutating func decode(_ type: String.Type) throws -> String {
        let (idx, entry) = try nextEntry()
        guard entry.type == KSBONJSON_TYPE_STRING else {
            throw BONJSONDecodingError.typeMismatch(expected: "string", actual: describeType(entry.type))
        }
        guard let string = state.map.getString(at: size_t(idx)) else {
            throw BONJSONDecodingError.invalidUTF8String
        }
        return string
    }

    @inline(__always)
    mutating func decode(_ type: Double.Type) throws -> Double {
        let (_, entry) = try nextEntry()
        switch entry.type {
        case KSBONJSON_TYPE_FLOAT: return entry.data.floatValue
        case KSBONJSON_TYPE_INT: return Double(entry.data.intValue)
        case KSBONJSON_TYPE_UINT: return Double(entry.data.uintValue)
        case KSBONJSON_TYPE_BIGNUMBER:
            let bn = entry.data.bigNumber
            let significand = Double(bn.significand)
            let result = significand * pow(10.0, Double(bn.exponent))
            return bn.sign < 0 ? -result : result
        default: throw BONJSONDecodingError.typeMismatch(expected: "float", actual: describeType(entry.type))
        }
    }

    @inline(__always)
    mutating func decode(_ type: Float.Type) throws -> Float {
        return Float(try decode(Double.self))
    }

    @inline(__always)
    private mutating func decodeInt64Value() throws -> Int64 {
        let (_, entry) = try nextEntry()
        switch entry.type {
        case KSBONJSON_TYPE_INT: return entry.data.intValue
        case KSBONJSON_TYPE_UINT:
            let value = entry.data.uintValue
            guard value <= UInt64(Int64.max) else {
                throw BONJSONDecodingError.typeMismatch(expected: "Int64", actual: "UInt64 too large")
            }
            return Int64(value)
        default: throw BONJSONDecodingError.typeMismatch(expected: "integer", actual: describeType(entry.type))
        }
    }

    @inline(__always)
    private mutating func decodeUInt64Value() throws -> UInt64 {
        let (_, entry) = try nextEntry()
        switch entry.type {
        case KSBONJSON_TYPE_UINT: return entry.data.uintValue
        case KSBONJSON_TYPE_INT:
            let value = entry.data.intValue
            guard value >= 0 else {
                throw BONJSONDecodingError.typeMismatch(expected: "UInt64", actual: "negative integer")
            }
            return UInt64(value)
        default: throw BONJSONDecodingError.typeMismatch(expected: "unsigned integer", actual: describeType(entry.type))
        }
    }

    @inline(__always) mutating func decode(_ type: Int.Type) throws -> Int { return Int(try decodeInt64Value()) }
    @inline(__always) mutating func decode(_ type: Int8.Type) throws -> Int8 { return Int8(try decodeInt64Value()) }
    @inline(__always) mutating func decode(_ type: Int16.Type) throws -> Int16 { return Int16(try decodeInt64Value()) }
    @inline(__always) mutating func decode(_ type: Int32.Type) throws -> Int32 { return Int32(try decodeInt64Value()) }
    @inline(__always) mutating func decode(_ type: Int64.Type) throws -> Int64 { return try decodeInt64Value() }
    @inline(__always) mutating func decode(_ type: UInt.Type) throws -> UInt { return UInt(try decodeUInt64Value()) }
    @inline(__always) mutating func decode(_ type: UInt8.Type) throws -> UInt8 { return UInt8(try decodeUInt64Value()) }
    @inline(__always) mutating func decode(_ type: UInt16.Type) throws -> UInt16 { return UInt16(try decodeUInt64Value()) }
    @inline(__always) mutating func decode(_ type: UInt32.Type) throws -> UInt32 { return UInt32(try decodeUInt64Value()) }
    @inline(__always) mutating func decode(_ type: UInt64.Type) throws -> UInt64 { return try decodeUInt64Value() }

    private func describeType(_ type: KSBONJSONValueType) -> String {
        switch type {
        case KSBONJSON_TYPE_NULL: return "null"
        case KSBONJSON_TYPE_TRUE: return "true"
        case KSBONJSON_TYPE_FALSE: return "false"
        case KSBONJSON_TYPE_INT: return "integer"
        case KSBONJSON_TYPE_UINT: return "unsigned integer"
        case KSBONJSON_TYPE_FLOAT: return "float"
        case KSBONJSON_TYPE_BIGNUMBER: return "big number"
        case KSBONJSON_TYPE_STRING: return "string"
        case KSBONJSON_TYPE_ARRAY: return "array"
        case KSBONJSON_TYPE_OBJECT: return "object"
        default: return "unknown"
        }
    }

    mutating func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let decoder = try nextDecoder()

        if type == Date.self {
            return try decoder.decodeDate() as! T
        }
        if type == Data.self {
            return try decoder.decodeData() as! T
        }
        if type == URL.self {
            let string = try decoder.decodeString()
            guard let url = URL(string: string) else {
                throw BONJSONDecodingError.invalidURL(string)
            }
            return url as! T
        }

        return try T(from: decoder)
    }

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy type: NestedKey.Type
    ) throws -> KeyedDecodingContainer<NestedKey> {
        return try nextDecoder().container(keyedBy: type)
    }

    mutating func nestedUnkeyedContainer() throws -> UnkeyedDecodingContainer {
        return try nextDecoder().unkeyedContainer()
    }

    mutating func superDecoder() throws -> Decoder {
        return try nextDecoder()
    }
}

// MARK: - Single Value Decoding Container

struct _MapSingleValueDecodingContainer: SingleValueDecodingContainer {
    let state: _MapDecoderState
    let entryIndex: size_t
    let lazyPath: _LazyCodingPath
    /// Cached entry - avoid repeated lookups
    private let entry: KSBONJSONMapEntry?

    /// Computed property - only builds array when needed (for errors)
    var codingPath: [CodingKey] { lazyPath.toArray() }

    init(state: _MapDecoderState, entryIndex: size_t, lazyPath: _LazyCodingPath) {
        self.state = state
        self.entryIndex = entryIndex
        self.lazyPath = lazyPath
        self.entry = state.map.getEntry(at: entryIndex)
    }

    @inline(__always)
    func decodeNil() -> Bool {
        return entry?.type == KSBONJSON_TYPE_NULL
    }

    @inline(__always)
    func decode(_ type: Bool.Type) throws -> Bool {
        guard let entry = entry else {
            throw BONJSONDecodingError.unexpectedEndOfData
        }
        switch entry.type {
        case KSBONJSON_TYPE_TRUE: return true
        case KSBONJSON_TYPE_FALSE: return false
        default: throw BONJSONDecodingError.typeMismatch(expected: "boolean", actual: describeType(entry.type))
        }
    }

    @inline(__always)
    func decode(_ type: String.Type) throws -> String {
        guard let entry = entry, entry.type == KSBONJSON_TYPE_STRING else {
            throw BONJSONDecodingError.typeMismatch(expected: "string", actual: entry.map { describeType($0.type) } ?? "nil")
        }
        guard let string = state.map.getString(at: entryIndex) else {
            throw BONJSONDecodingError.invalidUTF8String
        }
        return string
    }

    @inline(__always)
    func decode(_ type: Double.Type) throws -> Double {
        guard let entry = entry else {
            throw BONJSONDecodingError.unexpectedEndOfData
        }
        switch entry.type {
        case KSBONJSON_TYPE_FLOAT: return entry.data.floatValue
        case KSBONJSON_TYPE_INT: return Double(entry.data.intValue)
        case KSBONJSON_TYPE_UINT: return Double(entry.data.uintValue)
        case KSBONJSON_TYPE_BIGNUMBER:
            let bn = entry.data.bigNumber
            let significand = Double(bn.significand)
            let result = significand * pow(10.0, Double(bn.exponent))
            return bn.sign < 0 ? -result : result
        default: throw BONJSONDecodingError.typeMismatch(expected: "float", actual: describeType(entry.type))
        }
    }

    @inline(__always)
    func decode(_ type: Float.Type) throws -> Float {
        return Float(try decode(Double.self))
    }

    @inline(__always)
    private func decodeInt64() throws -> Int64 {
        guard let entry = entry else {
            throw BONJSONDecodingError.unexpectedEndOfData
        }
        switch entry.type {
        case KSBONJSON_TYPE_INT: return entry.data.intValue
        case KSBONJSON_TYPE_UINT:
            let value = entry.data.uintValue
            guard value <= UInt64(Int64.max) else {
                throw BONJSONDecodingError.typeMismatch(expected: "Int64", actual: "UInt64 too large")
            }
            return Int64(value)
        default: throw BONJSONDecodingError.typeMismatch(expected: "integer", actual: describeType(entry.type))
        }
    }

    @inline(__always)
    private func decodeUInt64() throws -> UInt64 {
        guard let entry = entry else {
            throw BONJSONDecodingError.unexpectedEndOfData
        }
        switch entry.type {
        case KSBONJSON_TYPE_UINT: return entry.data.uintValue
        case KSBONJSON_TYPE_INT:
            let value = entry.data.intValue
            guard value >= 0 else {
                throw BONJSONDecodingError.typeMismatch(expected: "UInt64", actual: "negative integer")
            }
            return UInt64(value)
        default: throw BONJSONDecodingError.typeMismatch(expected: "unsigned integer", actual: describeType(entry.type))
        }
    }

    @inline(__always) func decode(_ type: Int.Type) throws -> Int { return Int(try decodeInt64()) }
    @inline(__always) func decode(_ type: Int8.Type) throws -> Int8 { return Int8(try decodeInt64()) }
    @inline(__always) func decode(_ type: Int16.Type) throws -> Int16 { return Int16(try decodeInt64()) }
    @inline(__always) func decode(_ type: Int32.Type) throws -> Int32 { return Int32(try decodeInt64()) }
    @inline(__always) func decode(_ type: Int64.Type) throws -> Int64 { return try decodeInt64() }
    @inline(__always) func decode(_ type: UInt.Type) throws -> UInt { return UInt(try decodeUInt64()) }
    @inline(__always) func decode(_ type: UInt8.Type) throws -> UInt8 { return UInt8(try decodeUInt64()) }
    @inline(__always) func decode(_ type: UInt16.Type) throws -> UInt16 { return UInt16(try decodeUInt64()) }
    @inline(__always) func decode(_ type: UInt32.Type) throws -> UInt32 { return UInt32(try decodeUInt64()) }
    @inline(__always) func decode(_ type: UInt64.Type) throws -> UInt64 { return try decodeUInt64() }

    private func describeType(_ type: KSBONJSONValueType) -> String {
        switch type {
        case KSBONJSON_TYPE_NULL: return "null"
        case KSBONJSON_TYPE_TRUE: return "true"
        case KSBONJSON_TYPE_FALSE: return "false"
        case KSBONJSON_TYPE_INT: return "integer"
        case KSBONJSON_TYPE_UINT: return "unsigned integer"
        case KSBONJSON_TYPE_FLOAT: return "float"
        case KSBONJSON_TYPE_BIGNUMBER: return "big number"
        case KSBONJSON_TYPE_STRING: return "string"
        case KSBONJSON_TYPE_ARRAY: return "array"
        case KSBONJSON_TYPE_OBJECT: return "object"
        default: return "unknown"
        }
    }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        // Handle special types inline without creating decoder
        if type == Date.self {
            let decoder = _MapDecoder(state: state, entryIndex: entryIndex, lazyPath: lazyPath)
            return try decoder.decodeDate() as! T
        }
        if type == Data.self {
            let decoder = _MapDecoder(state: state, entryIndex: entryIndex, lazyPath: lazyPath)
            return try decoder.decodeData() as! T
        }
        if type == URL.self {
            let string = try decode(String.self)
            guard let url = URL(string: string) else {
                throw BONJSONDecodingError.invalidURL(string)
            }
            return url as! T
        }

        let decoder = _MapDecoder(state: state, entryIndex: entryIndex, lazyPath: lazyPath)
        return try T(from: decoder)
    }
}

// MARK: - Helper CodingKey Types

/// A simple CodingKey for string keys.
struct _StringKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

// _BONJSONIndexKey is defined in BONJSONEncoder.swift

// MARK: - String Extensions

extension String {
    /// Converts a snake_case string to camelCase.
    func convertFromSnakeCase() -> String {
        guard contains("_") else { return self }

        var result = ""
        var capitalizeNext = false

        for char in self {
            if char == "_" {
                capitalizeNext = true
            } else if capitalizeNext {
                result += char.uppercased()
                capitalizeNext = false
            } else {
                result += String(char)
            }
        }

        return result
    }
}
