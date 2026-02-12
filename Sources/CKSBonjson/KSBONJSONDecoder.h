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

// ABOUTME: Public API for position-map and callback-based BONJSON decoding.
// ABOUTME: Phase 3 format with typed arrays and records.

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
#   define KSBONJSON_MAX_CONTAINER_DEPTH 512
#endif
#ifndef KSBONJSON_DEFAULT_MAX_STRING_LENGTH
#   define KSBONJSON_DEFAULT_MAX_STRING_LENGTH 10000000
#endif
#ifndef KSBONJSON_DEFAULT_MAX_CONTAINER_SIZE
#   define KSBONJSON_DEFAULT_MAX_CONTAINER_SIZE 1000000
#endif
#ifndef KSBONJSON_DEFAULT_MAX_DOCUMENT_SIZE
#   define KSBONJSON_DEFAULT_MAX_DOCUMENT_SIZE 2000000000
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
    KSBONJSON_DECODE_TRAILING_BYTES = 14,
    KSBONJSON_DECODE_MAX_DEPTH_EXCEEDED = 16,
    KSBONJSON_DECODE_MAX_STRING_LENGTH_EXCEEDED = 17,
    KSBONJSON_DECODE_MAX_CONTAINER_SIZE_EXCEEDED = 18,
    KSBONJSON_DECODE_MAX_DOCUMENT_SIZE_EXCEEDED = 19,
    KSBONJSON_DECODE_COULD_NOT_PROCESS_DATA = 100,
} ksbonjson_decodeStatus;


// ============================================================================
// Security Configuration Flags
// ============================================================================

typedef struct {
    bool rejectNUL;
    bool rejectInvalidUTF8;
    bool rejectDuplicateKeys;
    bool rejectTrailingBytes;
    bool rejectNaNInfinity;

    size_t maxDepth;
    size_t maxStringLength;
    size_t maxContainerSize;
    size_t maxDocumentSize;
} KSBONJSONDecodeFlags;

static inline KSBONJSONDecodeFlags ksbonjson_defaultDecodeFlags(void)
{
    KSBONJSONDecodeFlags flags = {
        .rejectNUL = true,
        .rejectInvalidUTF8 = true,
        .rejectDuplicateKeys = true,
        .rejectTrailingBytes = true,
        .rejectNaNInfinity = true,
        .maxDepth = SIZE_MAX,
        .maxStringLength = SIZE_MAX,
        .maxContainerSize = SIZE_MAX,
        .maxDocumentSize = SIZE_MAX,
    };
    return flags;
}


// ============================================================================
// Position Map Types
// ============================================================================

typedef enum {
    KSBONJSON_TYPE_NULL = 0,
    KSBONJSON_TYPE_FALSE,
    KSBONJSON_TYPE_TRUE,
    KSBONJSON_TYPE_INT,
    KSBONJSON_TYPE_UINT,
    KSBONJSON_TYPE_FLOAT,
    KSBONJSON_TYPE_BIGNUMBER,
    KSBONJSON_TYPE_STRING,
    KSBONJSON_TYPE_ARRAY,
    KSBONJSON_TYPE_OBJECT,
} KSBONJSONValueType;

typedef struct {
    KSBONJSONValueType type;
    uint32_t subtreeSize; // Total entries in subtree (1 for primitives, 1+children for containers)
    union {
        int64_t intValue;
        uint64_t uintValue;
        double floatValue;
        struct {
            uint32_t offset;
            uint32_t length;
        } string;
        struct {
            uint32_t firstChild;
            uint32_t count;
        } container;
        struct {
            uint64_t significand;
            int32_t exponent;
            int32_t sign;
        } bigNumber;
    } data;
} KSBONJSONMapEntry;

#define KSBONJSON_MAX_RECORD_DEFS 256

typedef struct {
    size_t firstKeyIndex;
    uint32_t keyCount;
} KSBONJSONRecordDef;

typedef struct {
    const uint8_t* input;
    size_t inputLength;
    KSBONJSONMapEntry* entries;
    size_t entriesCapacity;
    size_t entriesCount;
    size_t rootIndex;
    size_t position;
    int containerDepth;
    size_t containerStack[KSBONJSON_MAX_CONTAINER_DEPTH];
    KSBONJSONDecodeFlags flags;
    KSBONJSONRecordDef recordDefs[KSBONJSON_MAX_RECORD_DEFS];
    size_t recordDefCount;
} KSBONJSONMapContext;

KSBONJSON_PUBLIC void ksbonjson_map_beginWithFlags(
    KSBONJSONMapContext* ctx,
    const uint8_t* input,
    size_t inputLength,
    KSBONJSONMapEntry* entries,
    size_t entriesCapacity,
    KSBONJSONDecodeFlags flags);

KSBONJSON_PUBLIC void ksbonjson_map_begin(
    KSBONJSONMapContext* ctx,
    const uint8_t* input,
    size_t inputLength,
    KSBONJSONMapEntry* entries,
    size_t entriesCapacity);

KSBONJSON_PUBLIC ksbonjson_decodeStatus ksbonjson_map_scan(KSBONJSONMapContext* ctx);
KSBONJSON_PUBLIC size_t ksbonjson_map_root(KSBONJSONMapContext* ctx);
KSBONJSON_PUBLIC const KSBONJSONMapEntry* ksbonjson_map_get(KSBONJSONMapContext* ctx, size_t index);
KSBONJSON_PUBLIC size_t ksbonjson_map_count(KSBONJSONMapContext* ctx);

KSBONJSON_PUBLIC const char* ksbonjson_map_getString(
    KSBONJSONMapContext* ctx,
    size_t index,
    size_t* outLength);

KSBONJSON_PUBLIC size_t ksbonjson_map_getChild(
    KSBONJSONMapContext* ctx,
    size_t containerIndex,
    size_t childIndex);

KSBONJSON_PUBLIC size_t ksbonjson_map_findKey(
    KSBONJSONMapContext* ctx,
    size_t objectIndex,
    const char* key,
    size_t keyLength);

KSBONJSON_PUBLIC size_t ksbonjson_map_estimateEntries(size_t inputLength);

// Batch decode functions
KSBONJSON_PUBLIC size_t ksbonjson_map_decodeInt64Array(
    KSBONJSONMapContext* ctx, size_t arrayIndex, int64_t* outBuffer, size_t maxCount);

KSBONJSON_PUBLIC size_t ksbonjson_map_decodeUInt64Array(
    KSBONJSONMapContext* ctx, size_t arrayIndex, uint64_t* outBuffer, size_t maxCount);

KSBONJSON_PUBLIC size_t ksbonjson_map_decodeDoubleArray(
    KSBONJSONMapContext* ctx, size_t arrayIndex, double* outBuffer, size_t maxCount);

KSBONJSON_PUBLIC size_t ksbonjson_map_decodeBoolArray(
    KSBONJSONMapContext* ctx, size_t arrayIndex, bool* outBuffer, size_t maxCount);

typedef struct {
    uint32_t offset;
    uint32_t length;
} KSBONJSONStringRef;

KSBONJSON_PUBLIC size_t ksbonjson_map_decodeStringArray(
    KSBONJSONMapContext* ctx, size_t arrayIndex, KSBONJSONStringRef* outBuffer, size_t maxCount);


// ============================================================================
// Callback-Based Decoder (Legacy API)
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
