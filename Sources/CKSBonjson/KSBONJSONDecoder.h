//
//  KSBONJSONDecoder.h
//
//  Created by Karl Stenerud on 2024-07-07.
//
//  Copyright (c) 2024 Karl Stenerud. All rights reserved.
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall remain in place
// in this source code.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.
//

#ifndef KSBONJSONDecoder_h
#define KSBONJSONDecoder_h

#include <stdbool.h>
#include <stdint.h>
#include <sys/types.h>


#ifdef __cplusplus
extern "C" {
#endif


// ============================================================================
// Compile-time Configuration
// ============================================================================

#ifndef KSBONJSON_MAX_CONTAINER_DEPTH
#   define KSBONJSON_MAX_CONTAINER_DEPTH 200
#endif

#ifndef KSBONJSON_RESTRICT
#   ifdef __cplusplus
#       define KSBONJSON_RESTRICT __restrict__
#   else
#       define KSBONJSON_RESTRICT restrict
#   endif
#endif

#ifndef KSBONJSON_PUBLIC
#   if defined _WIN32 || defined __CYGWIN__
#       define KSBONJSON_PUBLIC __declspec(dllimport)
#   else
#       define KSBONJSON_PUBLIC
#   endif
#endif


// ============================================================================
// Common Types
// ============================================================================

#ifndef TYPEDEF_KSBIGNUMBER
#define TYPEDEF_KSBIGNUMBER
    typedef struct
    {
        uint64_t significand;
        int32_t exponent;
        int32_t significandSign;
    } KSBigNumber;

    static inline KSBigNumber ksbonjson_newBigNumber(int sign, uint64_t significandAbs, int32_t exponent)
    {
        KSBigNumber v = {
            .significand = significandAbs,
            .exponent = exponent,
            .significandSign = (int32_t)sign,
        };
        return v;
    }
#endif


// ============================================================================
// Decoder Status Codes
// ============================================================================

typedef enum
{
    KSBONJSON_DECODE_OK = 0,
    KSBONJSON_DECODE_INCOMPLETE = 1,
    KSBONJSON_DECODE_UNCLOSED_CONTAINERS = 2,
    KSBONJSON_DECODE_UNBALANCED_CONTAINERS = 3,
    KSBONJSON_DECODE_CONTAINER_DEPTH_EXCEEDED = 4,
    KSBONJSON_DECODE_EXPECTED_OBJECT_NAME = 5,
    KSBONJSON_DECODE_EXPECTED_OBJECT_VALUE = 6,
    KSBONJSON_DECODE_INVALID_DATA = 7,
    KSBONJSON_DECODE_DUPLICATE_OBJECT_NAME = 8,
    KSBONJSON_DECODE_VALUE_OUT_OF_RANGE = 9,
    KSBONJSON_DECODE_NUL_CHARACTER = 10,
    KSBONJSON_DECODE_MAP_FULL = 11,
    KSBONJSON_DECODE_INVALID_UTF8 = 12,
    KSBONJSON_DECODE_TOO_MANY_KEYS = 13,
    KSBONJSON_DECODE_COULD_NOT_PROCESS_DATA = 100,
} ksbonjson_decodeStatus;


// ============================================================================
// Security Configuration Flags
// ============================================================================

/**
 * Flags controlling security validation during decoding.
 * All flags default to secure behavior (reject invalid data).
 */
typedef struct {
    /**
     * If true (default), reject strings containing NUL (U+0000) characters.
     * NUL characters are a common source of security vulnerabilities.
     */
    bool rejectNUL;

    /**
     * If true (default), reject strings containing invalid UTF-8 sequences.
     * Invalid UTF-8 includes: malformed sequences, surrogates (U+D800-U+DFFF),
     * overlong encodings, and codepoints above U+10FFFF.
     */
    bool rejectInvalidUTF8;

    /**
     * If true (default), reject objects with duplicate keys.
     * Duplicate keys are a security risk and explicitly forbidden by the spec.
     */
    bool rejectDuplicateKeys;
} KSBONJSONDecodeFlags;

/**
 * Returns default decode flags with all security checks enabled.
 */
static inline KSBONJSONDecodeFlags ksbonjson_defaultDecodeFlags(void)
{
    KSBONJSONDecodeFlags flags = {
        .rejectNUL = true,
        .rejectInvalidUTF8 = true,
        .rejectDuplicateKeys = true,
    };
    return flags;
}


// ============================================================================
// Position Map Types (NEW - High Performance API)
// ============================================================================

/**
 * Value types stored in the position map.
 */
typedef enum {
    KSBONJSON_TYPE_NULL = 0,
    KSBONJSON_TYPE_FALSE,
    KSBONJSON_TYPE_TRUE,
    KSBONJSON_TYPE_INT,        // Stored as int64 (small int or multi-byte signed)
    KSBONJSON_TYPE_UINT,       // Stored as uint64 (multi-byte unsigned)
    KSBONJSON_TYPE_FLOAT,      // Stored as double
    KSBONJSON_TYPE_BIGNUMBER,  // Big number (requires special handling)
    KSBONJSON_TYPE_STRING,     // String with offset and length
    KSBONJSON_TYPE_ARRAY,      // Array container
    KSBONJSON_TYPE_OBJECT,     // Object container
} KSBONJSONValueType;

/**
 * A decoded value in the position map.
 *
 * This union holds the decoded value directly for primitives,
 * or offset/length for strings and containers.
 */
typedef struct {
    KSBONJSONValueType type;
    union {
        int64_t intValue;       // For INT type
        uint64_t uintValue;     // For UINT type
        double floatValue;      // For FLOAT type
        struct {
            uint32_t offset;    // Byte offset in input buffer
            uint32_t length;    // Length in bytes
        } string;
        struct {
            uint32_t firstChild; // Index of first child in map
            uint32_t count;      // Number of children
        } container;
        struct {
            uint64_t significand;
            int32_t exponent;
            int32_t sign;
        } bigNumber;
    } data;
} KSBONJSONMapEntry;

/**
 * Position map decode context.
 *
 * This builds a map of all values during scanning, allowing
 * random access without re-parsing.
 */
typedef struct {
    // Input buffer (not owned - caller must keep alive)
    const uint8_t* input;
    size_t inputLength;

    // Map entries (caller-provided buffer)
    KSBONJSONMapEntry* entries;
    size_t entriesCapacity;
    size_t entriesCount;

    // Root entry index (usually 0)
    size_t rootIndex;

    // Parsing position
    size_t position;

    // Container stack for parsing
    int containerDepth;
    size_t containerStack[KSBONJSON_MAX_CONTAINER_DEPTH];

    // Security validation flags
    KSBONJSONDecodeFlags flags;
} KSBONJSONMapContext;

/**
 * Initialize position map decoding with security flags.
 *
 * @param ctx The context to initialize
 * @param input The BONJSON input buffer (must remain valid)
 * @param inputLength Length of input in bytes
 * @param entries Caller-provided entry buffer
 * @param entriesCapacity Size of entry buffer
 * @param flags Security validation flags
 */
KSBONJSON_PUBLIC void ksbonjson_map_beginWithFlags(
    KSBONJSONMapContext* ctx,
    const uint8_t* input,
    size_t inputLength,
    KSBONJSONMapEntry* entries,
    size_t entriesCapacity,
    KSBONJSONDecodeFlags flags);

/**
 * Initialize position map decoding with default (secure) flags.
 *
 * @param ctx The context to initialize
 * @param input The BONJSON input buffer (must remain valid)
 * @param inputLength Length of input in bytes
 * @param entries Caller-provided entry buffer
 * @param entriesCapacity Size of entry buffer
 */
KSBONJSON_PUBLIC void ksbonjson_map_begin(
    KSBONJSONMapContext* ctx,
    const uint8_t* input,
    size_t inputLength,
    KSBONJSONMapEntry* entries,
    size_t entriesCapacity);

/**
 * Scan the input and build the position map.
 * Returns KSBONJSON_DECODE_OK on success, error code on failure.
 */
KSBONJSON_PUBLIC ksbonjson_decodeStatus ksbonjson_map_scan(KSBONJSONMapContext* ctx);

/**
 * Get the root entry index.
 */
KSBONJSON_PUBLIC size_t ksbonjson_map_root(KSBONJSONMapContext* ctx);

/**
 * Get an entry by index.
 */
KSBONJSON_PUBLIC const KSBONJSONMapEntry* ksbonjson_map_get(KSBONJSONMapContext* ctx, size_t index);

/**
 * Get the number of entries in the map.
 */
KSBONJSON_PUBLIC size_t ksbonjson_map_count(KSBONJSONMapContext* ctx);

/**
 * Get a string value's data pointer and length.
 * Returns NULL if not a string type.
 */
KSBONJSON_PUBLIC const char* ksbonjson_map_getString(
    KSBONJSONMapContext* ctx,
    size_t index,
    size_t* outLength);

/**
 * Get the child at a given position in a container.
 * For arrays: childIndex is the array index (0-based)
 * For objects: childIndex is the key-value pair index * 2 (key) or *2+1 (value)
 * Returns the entry index, or SIZE_MAX if out of bounds.
 */
KSBONJSON_PUBLIC size_t ksbonjson_map_getChild(
    KSBONJSONMapContext* ctx,
    size_t containerIndex,
    size_t childIndex);

/**
 * Find a key in an object and return the value's entry index.
 * Returns SIZE_MAX if not found.
 */
KSBONJSON_PUBLIC size_t ksbonjson_map_findKey(
    KSBONJSONMapContext* ctx,
    size_t objectIndex,
    const char* key,
    size_t keyLength);

/**
 * Estimate the number of entries needed to decode the input.
 * This provides a reasonable upper bound for buffer sizing.
 */
KSBONJSON_PUBLIC size_t ksbonjson_map_estimateEntries(size_t inputLength);

/**
 * Batch decode an array of int64 values.
 * Returns the number of values decoded, or 0 if arrayIndex is not an array.
 * Stops at maxCount or end of array, whichever comes first.
 * Non-integer values are converted: floats truncated, bools become 0/1.
 */
KSBONJSON_PUBLIC size_t ksbonjson_map_decodeInt64Array(
    KSBONJSONMapContext* ctx,
    size_t arrayIndex,
    int64_t* outBuffer,
    size_t maxCount);

/**
 * Batch decode an array of uint64 values.
 * Returns the number of values decoded, or 0 if arrayIndex is not an array.
 */
KSBONJSON_PUBLIC size_t ksbonjson_map_decodeUInt64Array(
    KSBONJSONMapContext* ctx,
    size_t arrayIndex,
    uint64_t* outBuffer,
    size_t maxCount);

/**
 * Batch decode an array of double values.
 * Returns the number of values decoded, or 0 if arrayIndex is not an array.
 * Integer values are converted to double.
 */
KSBONJSON_PUBLIC size_t ksbonjson_map_decodeDoubleArray(
    KSBONJSONMapContext* ctx,
    size_t arrayIndex,
    double* outBuffer,
    size_t maxCount);

/**
 * Batch decode an array of bool values.
 * Returns the number of values decoded, or 0 if arrayIndex is not an array.
 */
KSBONJSON_PUBLIC size_t ksbonjson_map_decodeBoolArray(
    KSBONJSONMapContext* ctx,
    size_t arrayIndex,
    bool* outBuffer,
    size_t maxCount);

/**
 * String reference for batch string decoding.
 * Contains offset and length into the original input buffer.
 */
typedef struct {
    uint32_t offset;  // Byte offset in input buffer
    uint32_t length;  // Length in bytes
} KSBONJSONStringRef;

/**
 * Batch decode an array of string references.
 * Returns the number of strings decoded, or 0 if arrayIndex is not an array.
 * Non-string elements get offset=0, length=0.
 * The caller can then create strings from the input buffer using these offsets.
 */
KSBONJSON_PUBLIC size_t ksbonjson_map_decodeStringArray(
    KSBONJSONMapContext* ctx,
    size_t arrayIndex,
    KSBONJSONStringRef* outBuffer,
    size_t maxCount);


// ============================================================================
// Callback-Based Decoder (Original API - Preserved for Compatibility)
// ============================================================================

typedef struct KSBONJSONDecodeCallbacks
{
    ksbonjson_decodeStatus (*onBoolean)(bool value, void* userData);
    ksbonjson_decodeStatus (*onUnsignedInteger)(uint64_t value, void* userData);
    ksbonjson_decodeStatus (*onSignedInteger)(int64_t value, void* userData);
    ksbonjson_decodeStatus (*onFloat)(double value, void* userData);
    ksbonjson_decodeStatus (*onBigNumber)(KSBigNumber value, void* userData);
    ksbonjson_decodeStatus (*onNull)(void* userData);
    ksbonjson_decodeStatus (*onString)(const char* KSBONJSON_RESTRICT value,
                                       size_t length,
                                       void* KSBONJSON_RESTRICT userData);
    ksbonjson_decodeStatus (*onStringChunk)(const char* KSBONJSON_RESTRICT value,
                                            size_t length,
                                            bool isLastChunk,
                                            void* KSBONJSON_RESTRICT userData);
    ksbonjson_decodeStatus (*onBeginObject)(void* userData);
    ksbonjson_decodeStatus (*onBeginArray)(void* userData);
    ksbonjson_decodeStatus (*onEndContainer)(void* userData);
    ksbonjson_decodeStatus (*onEndData)(void* userData);
} KSBONJSONDecodeCallbacks;

KSBONJSON_PUBLIC ksbonjson_decodeStatus ksbonjson_decode(
    const uint8_t* KSBONJSON_RESTRICT document,
    size_t documentLength,
    const KSBONJSONDecodeCallbacks* KSBONJSON_RESTRICT callbacks,
    void* KSBONJSON_RESTRICT userData,
    size_t* KSBONJSON_RESTRICT decodedOffset);

KSBONJSON_PUBLIC const char* ksbonjson_describeDecodeStatus(ksbonjson_decodeStatus status) __attribute__((const));


#ifdef __cplusplus
}
#endif

#endif // KSBONJSONDecoder_h
