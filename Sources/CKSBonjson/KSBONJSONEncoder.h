//
//  KSBONJSONEncoder.h
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

#ifndef KSBONJSONEncoder_h
#define KSBONJSONEncoder_h

#include <stdbool.h>
#include <stdint.h>
#include <sys/types.h>


#ifdef __cplusplus
extern "C" {
#endif


// ============================================================================
// Compile-time Configuration
// ============================================================================

/**
 * Maximum depth of objects / arrays before the library will abort processing.
 */
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
// Encoder Status Codes
// ============================================================================

typedef enum
{
    KSBONJSON_ENCODE_OK = 0,
    KSBONJSON_ENCODE_EXPECTED_OBJECT_NAME = 1,
    KSBONJSON_ENCODE_EXPECTED_OBJECT_VALUE = 2,
    KSBONJSON_ENCODE_CHUNKING_STRING = 3,
    KSBONJSON_ENCODE_NULL_POINTER = 4,
    KSBONJSON_ENCODE_CLOSED_TOO_MANY_CONTAINERS = 5,
    KSBONJSON_ENCODE_CONTAINERS_ARE_STILL_OPEN = 6,
    KSBONJSON_ENCODE_INVALID_DATA = 7,
    KSBONJSON_ENCODE_TOO_BIG = 8,
    KSBONJSON_ENCODE_BUFFER_TOO_SMALL = 9,
    KSBONJSON_ENCODE_COULD_NOT_ADD_DATA = 100,
} ksbonjson_encodeStatus;


// ============================================================================
// Buffer-Based Encoder (NEW - High Performance API)
// ============================================================================

/**
 * Container state tracking for the encoder.
 */
typedef struct {
    uint8_t isObject: 1;
    uint8_t isExpectingName: 1;
    uint8_t isChunkingString: 1;
} KSBONJSONContainerState;

/**
 * Buffer-based encoding context.
 *
 * This context writes directly to a user-provided buffer, eliminating
 * callback overhead. Swift can access the buffer pointer and position
 * directly for optimal performance.
 *
 * Usage:
 * 1. Allocate a buffer in Swift
 * 2. Call ksbonjson_encodeToBuffer_begin() with the buffer
 * 3. Call encoding functions - they return bytes written or negative error
 * 4. Check position against capacity before each call, grow buffer if needed
 * 5. Call ksbonjson_encodeToBuffer_end() to finalize
 */
typedef struct {
    // Buffer management - Swift can read these directly
    uint8_t* buffer;          // Pointer to output buffer (owned by caller)
    size_t capacity;          // Total buffer capacity
    size_t position;          // Current write position (bytes written so far)

    // Container tracking
    int containerDepth;
    KSBONJSONContainerState containers[KSBONJSON_MAX_CONTAINER_DEPTH];
} KSBONJSONBufferEncodeContext;

/**
 * Initialize buffer-based encoding.
 *
 * @param ctx The encoding context to initialize
 * @param buffer The output buffer (caller-owned)
 * @param capacity The buffer's capacity in bytes
 */
KSBONJSON_PUBLIC void ksbonjson_encodeToBuffer_begin(
    KSBONJSONBufferEncodeContext* ctx,
    uint8_t* buffer,
    size_t capacity);

/**
 * Update the buffer pointer and capacity (call after growing the buffer).
 *
 * @param ctx The encoding context
 * @param buffer The new buffer pointer
 * @param capacity The new capacity
 */
KSBONJSON_PUBLIC void ksbonjson_encodeToBuffer_setBuffer(
    KSBONJSONBufferEncodeContext* ctx,
    uint8_t* buffer,
    size_t capacity);

/**
 * End buffer-based encoding.
 * Returns the final position (total bytes written) or negative error code.
 */
KSBONJSON_PUBLIC ssize_t ksbonjson_encodeToBuffer_end(KSBONJSONBufferEncodeContext* ctx);

/**
 * Calculate the maximum bytes needed to encode a value of the given type.
 * Use this to ensure buffer capacity before encoding.
 */
KSBONJSON_PUBLIC size_t ksbonjson_maxEncodedSize_null(void);
KSBONJSON_PUBLIC size_t ksbonjson_maxEncodedSize_bool(void);
KSBONJSON_PUBLIC size_t ksbonjson_maxEncodedSize_int(void);
KSBONJSON_PUBLIC size_t ksbonjson_maxEncodedSize_float(void);
KSBONJSON_PUBLIC size_t ksbonjson_maxEncodedSize_string(size_t stringLength);
KSBONJSON_PUBLIC size_t ksbonjson_maxEncodedSize_containerBegin(void);
KSBONJSON_PUBLIC size_t ksbonjson_maxEncodedSize_containerEnd(void);

// Encoding functions - return bytes written (positive) or error code (negative)
// All functions assume sufficient buffer capacity - caller must check first!

KSBONJSON_PUBLIC ssize_t ksbonjson_encodeToBuffer_null(KSBONJSONBufferEncodeContext* ctx);

KSBONJSON_PUBLIC ssize_t ksbonjson_encodeToBuffer_bool(KSBONJSONBufferEncodeContext* ctx, bool value);

KSBONJSON_PUBLIC ssize_t ksbonjson_encodeToBuffer_int(KSBONJSONBufferEncodeContext* ctx, int64_t value);

KSBONJSON_PUBLIC ssize_t ksbonjson_encodeToBuffer_uint(KSBONJSONBufferEncodeContext* ctx, uint64_t value);

KSBONJSON_PUBLIC ssize_t ksbonjson_encodeToBuffer_float(KSBONJSONBufferEncodeContext* ctx, double value);

KSBONJSON_PUBLIC ssize_t ksbonjson_encodeToBuffer_bigNumber(KSBONJSONBufferEncodeContext* ctx, KSBigNumber value);

KSBONJSON_PUBLIC ssize_t ksbonjson_encodeToBuffer_string(
    KSBONJSONBufferEncodeContext* ctx,
    const char* value,
    size_t length);

KSBONJSON_PUBLIC ssize_t ksbonjson_encodeToBuffer_beginObject(KSBONJSONBufferEncodeContext* ctx);

KSBONJSON_PUBLIC ssize_t ksbonjson_encodeToBuffer_beginArray(KSBONJSONBufferEncodeContext* ctx);

KSBONJSON_PUBLIC ssize_t ksbonjson_encodeToBuffer_endContainer(KSBONJSONBufferEncodeContext* ctx);

/**
 * End all open containers.
 * Returns total bytes written for all container ends, or negative error.
 */
KSBONJSON_PUBLIC ssize_t ksbonjson_encodeToBuffer_endAllContainers(KSBONJSONBufferEncodeContext* ctx);

/**
 * Get the current container depth.
 */
KSBONJSON_PUBLIC int ksbonjson_encodeToBuffer_getDepth(KSBONJSONBufferEncodeContext* ctx);

/**
 * Check if currently inside an object (vs array or top-level).
 */
KSBONJSON_PUBLIC bool ksbonjson_encodeToBuffer_isInObject(KSBONJSONBufferEncodeContext* ctx);

// Batch encoding functions for primitive arrays - much faster than encoding one at a time

/**
 * Encode an array of int64 values.
 * This is much faster than encoding elements one at a time.
 *
 * @param ctx The encoding context
 * @param values Pointer to array of int64 values
 * @param count Number of values to encode
 * @return Total bytes written (positive) or error code (negative)
 */
KSBONJSON_PUBLIC ssize_t ksbonjson_encodeToBuffer_int64Array(
    KSBONJSONBufferEncodeContext* ctx,
    const int64_t* values,
    size_t count);

/**
 * Encode an array of double values.
 * This is much faster than encoding elements one at a time.
 *
 * @param ctx The encoding context
 * @param values Pointer to array of double values
 * @param count Number of values to encode
 * @return Total bytes written (positive) or error code (negative)
 */
KSBONJSON_PUBLIC ssize_t ksbonjson_encodeToBuffer_doubleArray(
    KSBONJSONBufferEncodeContext* ctx,
    const double* values,
    size_t count);

/**
 * Calculate maximum bytes needed for an int64 array.
 */
KSBONJSON_PUBLIC size_t ksbonjson_maxEncodedSize_int64Array(size_t count);

/**
 * Calculate maximum bytes needed for a double array.
 */
KSBONJSON_PUBLIC size_t ksbonjson_maxEncodedSize_doubleArray(size_t count);

/**
 * Encode an array of strings.
 * This is much faster than encoding elements one at a time.
 *
 * @param ctx The encoding context
 * @param strings Array of string pointers (UTF-8 encoded)
 * @param lengths Array of string lengths (one per string)
 * @param count Number of strings to encode
 * @return Total bytes written (positive) or error code (negative)
 */
KSBONJSON_PUBLIC ssize_t ksbonjson_encodeToBuffer_stringArray(
    KSBONJSONBufferEncodeContext* ctx,
    const char* const* strings,
    const size_t* lengths,
    size_t count);

/**
 * Calculate maximum bytes needed for a string array.
 * Note: This requires the total length of all strings.
 */
KSBONJSON_PUBLIC size_t ksbonjson_maxEncodedSize_stringArray(size_t count, size_t totalStringLength);


// ============================================================================
// Callback-Based Encoder (Original API - Preserved for Compatibility)
// ============================================================================

typedef ksbonjson_encodeStatus (*KSBONJSONAddEncodedDataFunc)(
    const uint8_t* KSBONJSON_RESTRICT data,
    size_t dataLength,
    void* KSBONJSON_RESTRICT userData);

typedef struct
{
    KSBONJSONAddEncodedDataFunc addEncodedData;
    void* userData;
    int containerDepth;
    KSBONJSONContainerState containers[KSBONJSON_MAX_CONTAINER_DEPTH];
} KSBONJSONEncodeContext;

KSBONJSON_PUBLIC void ksbonjson_beginEncode(KSBONJSONEncodeContext* context,
                                            KSBONJSONAddEncodedDataFunc addEncodedData,
                                            void* userData);

KSBONJSON_PUBLIC ksbonjson_encodeStatus ksbonjson_endEncode(KSBONJSONEncodeContext* context);

KSBONJSON_PUBLIC ksbonjson_encodeStatus ksbonjson_terminateDocument(KSBONJSONEncodeContext* context);

KSBONJSON_PUBLIC ksbonjson_encodeStatus ksbonjson_addBoolean(KSBONJSONEncodeContext* context, bool value);

KSBONJSON_PUBLIC ksbonjson_encodeStatus ksbonjson_addUnsignedInteger(KSBONJSONEncodeContext* context, uint64_t value);

KSBONJSON_PUBLIC ksbonjson_encodeStatus ksbonjson_addSignedInteger(KSBONJSONEncodeContext* context, int64_t value);

KSBONJSON_PUBLIC ksbonjson_encodeStatus ksbonjson_addFloat(KSBONJSONEncodeContext* context, double value);

KSBONJSON_PUBLIC ksbonjson_encodeStatus ksbonjson_addBigNumber(KSBONJSONEncodeContext* context, KSBigNumber value);

KSBONJSON_PUBLIC ksbonjson_encodeStatus ksbonjson_addNull(KSBONJSONEncodeContext* context);

KSBONJSON_PUBLIC ksbonjson_encodeStatus ksbonjson_addString(KSBONJSONEncodeContext* KSBONJSON_RESTRICT context,
                                                            const char* KSBONJSON_RESTRICT value,
                                                            size_t valueLength);

KSBONJSON_PUBLIC ksbonjson_encodeStatus ksbonjson_chunkString(KSBONJSONEncodeContext* KSBONJSON_RESTRICT context,
                                                              const char* KSBONJSON_RESTRICT chunk,
                                                              size_t chunkLength,
                                                              bool isLastChunk);

KSBONJSON_PUBLIC ksbonjson_encodeStatus ksbonjson_addBONJSONDocument(KSBONJSONEncodeContext* KSBONJSON_RESTRICT context,
                                                                     const uint8_t* KSBONJSON_RESTRICT bonjsonDocument,
                                                                     size_t documentLength);

KSBONJSON_PUBLIC ksbonjson_encodeStatus ksbonjson_beginObject(KSBONJSONEncodeContext* context);

KSBONJSON_PUBLIC ksbonjson_encodeStatus ksbonjson_beginArray(KSBONJSONEncodeContext* context);

KSBONJSON_PUBLIC ksbonjson_encodeStatus ksbonjson_endContainer(KSBONJSONEncodeContext* context);

KSBONJSON_PUBLIC const char* ksbonjson_describeEncodeStatus(ksbonjson_encodeStatus status) __attribute__((const));


#ifdef __cplusplus
}
#endif

#endif /* KSBONJSONEncoder_h */
