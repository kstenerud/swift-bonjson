//
//  KSBONJSONEncoder.c
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

// ABOUTME: BONJSON encoder implementation for both buffer-based and
// ABOUTME: callback-based APIs. Phase 2 delimiter-terminated format.

#include "KSBONJSONEncoder.h"
#include "KSBONJSONCommon.h"
#include <math.h>
#include <string.h>
#include "KSBONJSONSimd.h"
#ifdef _MSC_VER
#include <intrin.h>
#endif

#pragma GCC diagnostic ignored "-Wdeclaration-after-statement"


// ============================================================================
// Types
// ============================================================================

union num32_bits
{
    float f32;
    uint32_t u32;
};

union num64_bits
{
    uint8_t  b[8];
    uint64_t u64;
    double   f64;
};


// ============================================================================
// Buffer-Based Encoder Implementation
// ============================================================================

#define BUF_REMAINING(ctx) ((ctx)->capacity - (ctx)->position)
#define BUF_PTR(ctx) ((ctx)->buffer + (ctx)->position)

static inline KSBONJSONContainerState* getBufferContainer(KSBONJSONBufferEncodeContext* const ctx)
{
    return &ctx->containers[ctx->containerDepth];
}

static inline bool bufferWouldExceedDocumentSize(KSBONJSONBufferEncodeContext* ctx, size_t length)
{
    size_t maxSize = ctx->flags.maxDocumentSize < SIZE_MAX ? ctx->flags.maxDocumentSize : KSBONJSON_DEFAULT_MAX_DOCUMENT_SIZE;
    return (ctx->position + length) > maxSize;
}

static inline void bufferWriteBytes(KSBONJSONBufferEncodeContext* ctx,
                                    const uint8_t* data,
                                    size_t length)
{
    memcpy(ctx->buffer + ctx->position, data, length);
    ctx->position += length;
}

static inline void bufferWriteByte(KSBONJSONBufferEncodeContext* ctx, uint8_t byte)
{
    ctx->buffer[ctx->position++] = byte;
}

void ksbonjson_encodeToBuffer_beginWithFlags(KSBONJSONBufferEncodeContext* ctx,
                                              uint8_t* buffer,
                                              size_t capacity,
                                              KSBONJSONEncodeFlags flags)
{
    memset(ctx, 0, sizeof(*ctx));
    ctx->buffer = buffer;
    ctx->capacity = capacity;
    ctx->position = 0;
    ctx->containerDepth = 0;
    ctx->flags = flags;
}

void ksbonjson_encodeToBuffer_begin(KSBONJSONBufferEncodeContext* ctx,
                                    uint8_t* buffer,
                                    size_t capacity)
{
    ksbonjson_encodeToBuffer_beginWithFlags(ctx, buffer, capacity, ksbonjson_defaultEncodeFlags());
}

void ksbonjson_encodeToBuffer_setBuffer(KSBONJSONBufferEncodeContext* ctx,
                                        uint8_t* buffer,
                                        size_t capacity)
{
    ctx->buffer = buffer;
    ctx->capacity = capacity;
}

ssize_t ksbonjson_encodeToBuffer_end(KSBONJSONBufferEncodeContext* ctx)
{
    unlikely_if(ctx->containerDepth > 0)
    {
        return -KSBONJSON_ENCODE_CONTAINERS_ARE_STILL_OPEN;
    }
    return (ssize_t)ctx->position;
}

int ksbonjson_encodeToBuffer_getDepth(KSBONJSONBufferEncodeContext* ctx)
{
    return ctx->containerDepth;
}

bool ksbonjson_encodeToBuffer_isInObject(KSBONJSONBufferEncodeContext* ctx)
{
    if (ctx->containerDepth <= 0) return false;
    return ctx->containers[ctx->containerDepth].isObject;
}

static inline void incrementContainerCount(KSBONJSONBufferEncodeContext* ctx)
{
    if (ctx->containerDepth > 0)
    {
        ctx->containerElementCounts[ctx->containerDepth]++;
    }
}

// Encode a type code + little-endian value bytes in one write
static inline void bufferWriteNumeric(KSBONJSONBufferEncodeContext* ctx,
                                      uint8_t typeCode,
                                      uint64_t valueBits,
                                      size_t byteCount)
{
    union num64_bits bits[2];
    bits[0].b[7] = typeCode;
    bits[1].u64 = ksbonjson_toLittleEndian(valueBits);
    bufferWriteBytes(ctx, &bits[0].b[7], byteCount + 1);
}

ssize_t ksbonjson_encodeToBuffer_null(KSBONJSONBufferEncodeContext* ctx)
{
    KSBONJSONContainerState* const container = getBufferContainer(ctx);
    unlikely_if(container->isObject & container->isExpectingName)
    {
        return -KSBONJSON_ENCODE_EXPECTED_OBJECT_NAME;
    }
    unlikely_if(bufferWouldExceedDocumentSize(ctx, 1))
    {
        return -KSBONJSON_ENCODE_MAX_DOCUMENT_SIZE_EXCEEDED;
    }
    container->isExpectingName = true;
    incrementContainerCount(ctx);

    bufferWriteByte(ctx, TYPE_NULL);
    return 1;
}

ssize_t ksbonjson_encodeToBuffer_bool(KSBONJSONBufferEncodeContext* ctx, bool value)
{
    KSBONJSONContainerState* const container = getBufferContainer(ctx);
    unlikely_if(container->isObject & container->isExpectingName)
    {
        return -KSBONJSON_ENCODE_EXPECTED_OBJECT_NAME;
    }
    unlikely_if(bufferWouldExceedDocumentSize(ctx, 1))
    {
        return -KSBONJSON_ENCODE_MAX_DOCUMENT_SIZE_EXCEEDED;
    }
    container->isExpectingName = true;
    incrementContainerCount(ctx);

    bufferWriteByte(ctx, value ? TYPE_TRUE : TYPE_FALSE);
    return 1;
}

ssize_t ksbonjson_encodeToBuffer_int(KSBONJSONBufferEncodeContext* ctx, int64_t value)
{
    KSBONJSONContainerState* const container = getBufferContainer(ctx);
    unlikely_if(container->isObject & container->isExpectingName)
    {
        return -KSBONJSON_ENCODE_EXPECTED_OBJECT_NAME;
    }
    unlikely_if(bufferWouldExceedDocumentSize(ctx, 9))
    {
        return -KSBONJSON_ENCODE_MAX_DOCUMENT_SIZE_EXCEEDED;
    }
    container->isExpectingName = true;
    incrementContainerCount(ctx);

    if (value >= SMALLINT_MIN && value <= SMALLINT_MAX)
    {
        bufferWriteByte(ctx, (uint8_t)(value + SMALLINT_BIAS));
        return 1;
    }

    // Round to CPU-native size
    size_t byteCount;
    uint8_t typeCode;

    if (value > 0)
    {
        size_t unsignedBytes = ksbonjson_roundToNativeSize(ksbonjson_uintBytesMin1((uint64_t)value));
        size_t signedBytes = ksbonjson_roundToNativeSize(ksbonjson_sintBytesMin1(value));

        if (unsignedBytes < signedBytes)
        {
            byteCount = unsignedBytes;
            typeCode = (uint8_t)(TYPE_UINT8 + ksbonjson_nativeSizeIndex[byteCount]);
        }
        else
        {
            byteCount = signedBytes;
            // If MSB is set in the signed encoding, we need unsigned type to avoid sign extension
            uint8_t msb = (uint8_t)(value >> (byteCount * 8 - 1));
            uint8_t base = msb ? TYPE_UINT8 : TYPE_SINT8;
            typeCode = (uint8_t)(base + ksbonjson_nativeSizeIndex[byteCount]);
        }
    }
    else
    {
        byteCount = ksbonjson_roundToNativeSize(ksbonjson_sintBytesMin1(value));
        typeCode = (uint8_t)(TYPE_SINT8 + ksbonjson_nativeSizeIndex[byteCount]);
    }

    bufferWriteNumeric(ctx, typeCode, (uint64_t)value, byteCount);
    return (ssize_t)(byteCount + 1);
}

ssize_t ksbonjson_encodeToBuffer_uint(KSBONJSONBufferEncodeContext* ctx, uint64_t value)
{
    KSBONJSONContainerState* const container = getBufferContainer(ctx);
    unlikely_if(container->isObject & container->isExpectingName)
    {
        return -KSBONJSON_ENCODE_EXPECTED_OBJECT_NAME;
    }
    unlikely_if(bufferWouldExceedDocumentSize(ctx, 9))
    {
        return -KSBONJSON_ENCODE_MAX_DOCUMENT_SIZE_EXCEEDED;
    }
    container->isExpectingName = true;
    incrementContainerCount(ctx);

    if (value <= (uint64_t)SMALLINT_MAX)
    {
        bufferWriteByte(ctx, (uint8_t)(value + SMALLINT_BIAS));
        return 1;
    }

    size_t byteCount = ksbonjson_roundToNativeSize(ksbonjson_uintBytesMin1(value));

    // Prefer signed if MSB is clear (same byte count, better interop)
    uint8_t msb = (uint8_t)(value >> (byteCount * 8 - 1));
    uint8_t base = msb ? TYPE_UINT8 : TYPE_SINT8;
    uint8_t typeCode = (uint8_t)(base + ksbonjson_nativeSizeIndex[byteCount]);

    bufferWriteNumeric(ctx, typeCode, value, byteCount);
    return (ssize_t)(byteCount + 1);
}

ssize_t ksbonjson_encodeToBuffer_float(KSBONJSONBufferEncodeContext* ctx, double value)
{
    const int64_t asInt = (int64_t)value;

#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wfloat-equal"
    // Encode as integer if exact and not negative zero
    if ((double)asInt == value && !signbit(value))
    {
        return ksbonjson_encodeToBuffer_int(ctx, asInt);
    }
#pragma GCC diagnostic pop

    KSBONJSONContainerState* const container = getBufferContainer(ctx);
    unlikely_if(container->isObject & container->isExpectingName)
    {
        return -KSBONJSON_ENCODE_EXPECTED_OBJECT_NAME;
    }
    unlikely_if(bufferWouldExceedDocumentSize(ctx, 9))
    {
        return -KSBONJSON_ENCODE_MAX_DOCUMENT_SIZE_EXCEEDED;
    }

    union num64_bits b64 = {.f64 = value};
    unlikely_if(ctx->flags.rejectNonFiniteFloat && (b64.u64 & 0x7ff0000000000000ULL) == 0x7ff0000000000000ULL)
    {
        return -KSBONJSON_ENCODE_INVALID_DATA;
    }

    container->isExpectingName = true;
    incrementContainerCount(ctx);

    // Try float32
    const union num32_bits b32 = { .f32 = (float)value };
    union num64_bits compare = { .f64 = (double)b32.f32 };

#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wfloat-equal"
    if (compare.f64 == value)
#pragma GCC diagnostic pop
    {
        // float32 is lossless
        bufferWriteNumeric(ctx, TYPE_FLOAT32, b32.u32, 4);
        return 5;
    }

    // float64
    bufferWriteNumeric(ctx, TYPE_FLOAT64, b64.u64, 8);
    return 9;
}

ssize_t ksbonjson_encodeToBuffer_bigNumber(KSBONJSONBufferEncodeContext* ctx, KSBigNumber value)
{
    KSBONJSONContainerState* const container = getBufferContainer(ctx);
    unlikely_if(container->isObject & container->isExpectingName)
    {
        return -KSBONJSON_ENCODE_EXPECTED_OBJECT_NAME;
    }
    // Max bignum: type(1) + exp zigzag LEB128(10) + signed_length zigzag LEB128(10) + magnitude(8) = 29
    unlikely_if(bufferWouldExceedDocumentSize(ctx, 29))
    {
        return -KSBONJSON_ENCODE_MAX_DOCUMENT_SIZE_EXCEEDED;
    }

    container->isExpectingName = true;
    incrementContainerCount(ctx);

    bufferWriteByte(ctx, TYPE_BIG_NUMBER);
    size_t totalBytes = 1;

    // Exponent as zigzag LEB128
    size_t expBytes = ksbonjson_writeZigzagLEB128(ctx->buffer + ctx->position, (int64_t)value.exponent);
    ctx->position += expBytes;
    totalBytes += expBytes;

    if (value.significand == 0)
    {
        // Zero significand: signed_length = 0, no magnitude bytes
        ctx->buffer[ctx->position] = 0x00;
        ctx->position += 1;
        totalBytes += 1;
    }
    else
    {
        // Convert significand to LE bytes and find normalized length
        uint8_t magnitude[8];
        uint64_t sig = value.significand;
        size_t byteCount = 0;
        while (sig != 0)
        {
            magnitude[byteCount++] = (uint8_t)(sig & 0xFF);
            sig >>= 8;
        }

        // Write signed_length as zigzag LEB128
        int64_t signedLength = (int64_t)byteCount;
        if (value.significandSign < 0) signedLength = -signedLength;
        size_t lenBytes = ksbonjson_writeZigzagLEB128(ctx->buffer + ctx->position, signedLength);
        ctx->position += lenBytes;
        totalBytes += lenBytes;

        // Write raw LE magnitude bytes
        memcpy(ctx->buffer + ctx->position, magnitude, byteCount);
        ctx->position += byteCount;
        totalBytes += byteCount;
    }

    return (ssize_t)totalBytes;
}

ssize_t ksbonjson_encodeToBuffer_string(KSBONJSONBufferEncodeContext* ctx,
                                        const char* value,
                                        size_t length)
{
    KSBONJSONContainerState* const container = getBufferContainer(ctx);
    unlikely_if(!value)
    {
        return -KSBONJSON_ENCODE_NULL_POINTER;
    }

    size_t maxLen = ctx->flags.maxStringLength < SIZE_MAX ? ctx->flags.maxStringLength : KSBONJSON_DEFAULT_MAX_STRING_LENGTH;
    unlikely_if(length > maxLen)
    {
        return -KSBONJSON_ENCODE_MAX_STRING_LENGTH_EXCEEDED;
    }

    size_t maxEncodedSize = length <= 15 ? (1 + length) : (2 + length);
    unlikely_if(bufferWouldExceedDocumentSize(ctx, maxEncodedSize))
    {
        return -KSBONJSON_ENCODE_MAX_DOCUMENT_SIZE_EXCEEDED;
    }

    if (ctx->flags.rejectNUL)
    {
        unlikely_if(ksbonjson_simd_containsByte((const uint8_t*)value, length, 0x00))
        {
            return -KSBONJSON_ENCODE_NUL_CHARACTER;
        }
    }

    container->isExpectingName = !container->isExpectingName;
    if (!container->isObject || container->isExpectingName)
    {
        incrementContainerCount(ctx);
    }

    if (length <= 15)
    {
        bufferWriteByte(ctx, (uint8_t)(TYPE_STRING0 + length));
        bufferWriteBytes(ctx, (const uint8_t*)value, length);
        return (ssize_t)(1 + length);
    }

    // Long string: FF + data + FF
    bufferWriteByte(ctx, TYPE_STRING_LONG);
    bufferWriteBytes(ctx, (const uint8_t*)value, length);
    bufferWriteByte(ctx, TYPE_STRING_LONG);
    return (ssize_t)(2 + length);
}

ssize_t ksbonjson_encodeToBuffer_beginObject(KSBONJSONBufferEncodeContext* ctx)
{
    KSBONJSONContainerState* const container = getBufferContainer(ctx);
    unlikely_if(container->isObject & container->isExpectingName)
    {
        return -KSBONJSON_ENCODE_EXPECTED_OBJECT_NAME;
    }
    unlikely_if(bufferWouldExceedDocumentSize(ctx, 1))
    {
        return -KSBONJSON_ENCODE_MAX_DOCUMENT_SIZE_EXCEEDED;
    }

    size_t maxDepth = ctx->flags.maxDepth < SIZE_MAX ? ctx->flags.maxDepth : KSBONJSON_MAX_CONTAINER_DEPTH;
    unlikely_if((size_t)(ctx->containerDepth + 1) > maxDepth)
    {
        return -KSBONJSON_ENCODE_MAX_DEPTH_EXCEEDED;
    }

    container->isExpectingName = true;
    incrementContainerCount(ctx);

    ctx->containerDepth++;
    ctx->containers[ctx->containerDepth] = (KSBONJSONContainerState){
        .isObject = true,
        .isExpectingName = true,
    };
    ctx->containerElementCounts[ctx->containerDepth] = 0;

    bufferWriteByte(ctx, TYPE_OBJECT);
    return 1;
}

ssize_t ksbonjson_encodeToBuffer_beginArray(KSBONJSONBufferEncodeContext* ctx)
{
    KSBONJSONContainerState* const container = getBufferContainer(ctx);
    unlikely_if(container->isObject & container->isExpectingName)
    {
        return -KSBONJSON_ENCODE_EXPECTED_OBJECT_NAME;
    }
    unlikely_if(bufferWouldExceedDocumentSize(ctx, 1))
    {
        return -KSBONJSON_ENCODE_MAX_DOCUMENT_SIZE_EXCEEDED;
    }

    size_t maxDepth = ctx->flags.maxDepth < SIZE_MAX ? ctx->flags.maxDepth : KSBONJSON_MAX_CONTAINER_DEPTH;
    unlikely_if((size_t)(ctx->containerDepth + 1) > maxDepth)
    {
        return -KSBONJSON_ENCODE_MAX_DEPTH_EXCEEDED;
    }

    container->isExpectingName = true;
    incrementContainerCount(ctx);

    ctx->containerDepth++;
    ctx->containers[ctx->containerDepth] = (KSBONJSONContainerState){0};
    ctx->containerElementCounts[ctx->containerDepth] = 0;

    bufferWriteByte(ctx, TYPE_ARRAY);
    return 1;
}

ssize_t ksbonjson_encodeToBuffer_endContainer(KSBONJSONBufferEncodeContext* ctx)
{
    KSBONJSONContainerState* const container = getBufferContainer(ctx);
    unlikely_if(container->isObject & !container->isExpectingName)
    {
        return -KSBONJSON_ENCODE_EXPECTED_OBJECT_VALUE;
    }

    unlikely_if(ctx->containerDepth <= 0)
    {
        return -KSBONJSON_ENCODE_CLOSED_TOO_MANY_CONTAINERS;
    }

    unlikely_if(bufferWouldExceedDocumentSize(ctx, 1))
    {
        return -KSBONJSON_ENCODE_MAX_DOCUMENT_SIZE_EXCEEDED;
    }

    ctx->containerDepth--;

    // Write end marker
    bufferWriteByte(ctx, TYPE_END);
    return 1;
}

ssize_t ksbonjson_encodeToBuffer_endAllContainers(KSBONJSONBufferEncodeContext* ctx)
{
    ssize_t totalBytes = 0;
    while (ctx->containerDepth > 0)
    {
        ssize_t result = ksbonjson_encodeToBuffer_endContainer(ctx);
        if (result < 0) return result;
        totalBytes += result;
    }
    return totalBytes;
}


// ============================================================================
// Batch encoding (optimized for arrays of primitives)
// ============================================================================

// Internal: encode a single int64 without container state checks (for batch use)
static inline size_t encodeInt64Fast(KSBONJSONBufferEncodeContext* ctx, int64_t value)
{
    if (value >= SMALLINT_MIN && value <= SMALLINT_MAX)
    {
        bufferWriteByte(ctx, (uint8_t)(value + SMALLINT_BIAS));
        return 1;
    }

    size_t byteCount;
    uint8_t typeCode;

    if (value > 0)
    {
        size_t unsignedBytes = ksbonjson_roundToNativeSize(ksbonjson_uintBytesMin1((uint64_t)value));
        size_t signedBytes = ksbonjson_roundToNativeSize(ksbonjson_sintBytesMin1(value));

        if (unsignedBytes < signedBytes)
        {
            byteCount = unsignedBytes;
            typeCode = (uint8_t)(TYPE_UINT8 + ksbonjson_nativeSizeIndex[byteCount]);
        }
        else
        {
            byteCount = signedBytes;
            uint8_t msb = (uint8_t)(value >> (byteCount * 8 - 1));
            uint8_t base = msb ? TYPE_UINT8 : TYPE_SINT8;
            typeCode = (uint8_t)(base + ksbonjson_nativeSizeIndex[byteCount]);
        }
    }
    else
    {
        byteCount = ksbonjson_roundToNativeSize(ksbonjson_sintBytesMin1(value));
        typeCode = (uint8_t)(TYPE_SINT8 + ksbonjson_nativeSizeIndex[byteCount]);
    }

    bufferWriteNumeric(ctx, typeCode, (uint64_t)value, byteCount);
    return byteCount + 1;
}

// Internal: encode a single double without container state checks (for batch use)
static inline size_t encodeDoubleFast(KSBONJSONBufferEncodeContext* ctx, double value)
{
    const int64_t asInt = (int64_t)value;

#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wfloat-equal"
    if ((double)asInt == value)
    {
#pragma GCC diagnostic pop
        return encodeInt64Fast(ctx, asInt);
    }

    bufferWriteByte(ctx, TYPE_FLOAT64);
    union num64_bits bits;
    bits.f64 = value;
    bits.u64 = ksbonjson_toLittleEndian(bits.u64);
    bufferWriteBytes(ctx, bits.b, 8);
    return 9;
}

ssize_t ksbonjson_encodeToBuffer_int64Array(
    KSBONJSONBufferEncodeContext* ctx,
    const int64_t* values,
    size_t count)
{
    KSBONJSONContainerState* const container = getBufferContainer(ctx);
    unlikely_if(container->isObject & container->isExpectingName)
    {
        return -KSBONJSON_ENCODE_EXPECTED_OBJECT_NAME;
    }
    container->isExpectingName = true;
    incrementContainerCount(ctx);

    size_t totalBytes = 0;

    // Begin array
    bufferWriteByte(ctx, TYPE_ARRAY);
    totalBytes++;

    // Encode all values
    for (size_t i = 0; i < count; i++)
    {
        totalBytes += encodeInt64Fast(ctx, values[i]);
    }

    // End array
    bufferWriteByte(ctx, TYPE_END);
    totalBytes++;

    return (ssize_t)totalBytes;
}

ssize_t ksbonjson_encodeToBuffer_doubleArray(
    KSBONJSONBufferEncodeContext* ctx,
    const double* values,
    size_t count)
{
    KSBONJSONContainerState* const container = getBufferContainer(ctx);
    unlikely_if(container->isObject & container->isExpectingName)
    {
        return -KSBONJSON_ENCODE_EXPECTED_OBJECT_NAME;
    }
    container->isExpectingName = true;
    incrementContainerCount(ctx);

    size_t totalBytes = 0;

    bufferWriteByte(ctx, TYPE_ARRAY);
    totalBytes++;

    for (size_t i = 0; i < count; i++)
    {
        totalBytes += encodeDoubleFast(ctx, values[i]);
    }

    bufferWriteByte(ctx, TYPE_END);
    totalBytes++;

    return (ssize_t)totalBytes;
}

// Internal: encode a single string without container state checks (for batch use)
static inline size_t encodeStringFast(KSBONJSONBufferEncodeContext* ctx,
                                      const char* value,
                                      size_t length)
{
    if (length <= 15)
    {
        bufferWriteByte(ctx, (uint8_t)(TYPE_STRING0 + length));
        bufferWriteBytes(ctx, (const uint8_t*)value, length);
        return 1 + length;
    }

    // Long string: FF + data + FF
    bufferWriteByte(ctx, TYPE_STRING_LONG);
    bufferWriteBytes(ctx, (const uint8_t*)value, length);
    bufferWriteByte(ctx, TYPE_STRING_LONG);
    return 2 + length;
}

ssize_t ksbonjson_encodeToBuffer_stringArray(
    KSBONJSONBufferEncodeContext* ctx,
    const char* const* strings,
    const size_t* lengths,
    size_t count)
{
    KSBONJSONContainerState* const container = getBufferContainer(ctx);
    unlikely_if(container->isObject & container->isExpectingName)
    {
        return -KSBONJSON_ENCODE_EXPECTED_OBJECT_NAME;
    }
    container->isExpectingName = true;
    incrementContainerCount(ctx);

    if (ctx->flags.rejectNUL)
    {
        for (size_t i = 0; i < count; i++)
        {
            unlikely_if(ksbonjson_simd_containsByte((const uint8_t*)strings[i], lengths[i], 0x00))
            {
                return -KSBONJSON_ENCODE_NUL_CHARACTER;
            }
        }
    }

    size_t totalBytes = 0;

    bufferWriteByte(ctx, TYPE_ARRAY);
    totalBytes++;

    for (size_t i = 0; i < count; i++)
    {
        totalBytes += encodeStringFast(ctx, strings[i], lengths[i]);
    }

    bufferWriteByte(ctx, TYPE_END);
    totalBytes++;

    return (ssize_t)totalBytes;
}


// ============================================================================
// Callback-Based Encoder Implementation (Legacy API)
// ============================================================================

#define PROPAGATE_ERROR(CALL) \
    do \
    { \
        const ksbonjson_encodeStatus propagatedResult = CALL; \
        unlikely_if(propagatedResult != KSBONJSON_ENCODE_OK) \
        { \
            return propagatedResult; \
        } \
    } \
    while(0)

#define SHOULD_NOT_BE_NULL(VALUE) \
    unlikely_if((VALUE) == 0) \
        return KSBONJSON_ENCODE_NULL_POINTER

#define SHOULD_NOT_BE_EXPECTING_OBJECT_NAME(CONTAINER) \
    unlikely_if((CONTAINER)->isObject & (CONTAINER)->isExpectingName) \
        return KSBONJSON_ENCODE_EXPECTED_OBJECT_NAME

#define SHOULD_NOT_BE_EXPECTING_OBJECT_VALUE(CONTAINER) \
    unlikely_if((CONTAINER)->isObject & !(CONTAINER)->isExpectingName) \
        return KSBONJSON_ENCODE_EXPECTED_OBJECT_VALUE

static KSBONJSONContainerState* getContainer(KSBONJSONEncodeContext* const ctx)
{
    return &ctx->containers[ctx->containerDepth];
}

static ksbonjson_encodeStatus addEncodedBytes(KSBONJSONEncodeContext* const ctx,
                                              const uint8_t* const data,
                                              const size_t length)
{
    return ctx->addEncodedData(data, length, ctx->userData);
}

static ksbonjson_encodeStatus addEncodedByte(KSBONJSONEncodeContext* const ctx, const uint8_t value)
{
    return addEncodedBytes(ctx, &value, 1);
}

static ksbonjson_encodeStatus encodePrimitiveNumeric(KSBONJSONEncodeContext* const ctx,
                                                     const uint8_t typeCode,
                                                     const uint64_t valueBits,
                                                     size_t byteCount)
{
    union num64_bits bits[2];
    bits[0].b[7] = typeCode;
    bits[1].u64 = ksbonjson_toLittleEndian(valueBits);
    return addEncodedBytes(ctx, &bits[0].b[7], byteCount + 1);
}

static ksbonjson_encodeStatus encodeSmallInt(KSBONJSONEncodeContext* const ctx, int64_t value)
{
    return addEncodedByte(ctx, (uint8_t)(value + SMALLINT_BIAS));
}

static ksbonjson_encodeStatus beginContainer(KSBONJSONEncodeContext* const ctx,
                                             const uint8_t typeCode,
                                             const KSBONJSONContainerState containerState)
{
    KSBONJSONContainerState* const container = getContainer(ctx);
    SHOULD_NOT_BE_EXPECTING_OBJECT_NAME(container);

    container->isExpectingName = true;

    ctx->containerDepth++;
    ctx->containers[ctx->containerDepth] = containerState;

    return addEncodedByte(ctx, typeCode);
}

void ksbonjson_beginEncode(KSBONJSONEncodeContext* const ctx,
                           const KSBONJSONAddEncodedDataFunc addEncodedBytesFunc,
                           void* const userData)
{
    *ctx = (KSBONJSONEncodeContext){0};
    ctx->addEncodedData = addEncodedBytesFunc;
    ctx->userData = userData;
}

ksbonjson_encodeStatus ksbonjson_endEncode(KSBONJSONEncodeContext* const ctx)
{
    unlikely_if(ctx->containerDepth > 0)
    {
        return KSBONJSON_ENCODE_CONTAINERS_ARE_STILL_OPEN;
    }
    return KSBONJSON_ENCODE_OK;
}

ksbonjson_encodeStatus ksbonjson_terminateDocument(KSBONJSONEncodeContext* const ctx)
{
    while(ctx->containerDepth > 0)
    {
        PROPAGATE_ERROR(ksbonjson_endContainer(ctx));
    }
    return KSBONJSON_ENCODE_OK;
}

ksbonjson_encodeStatus ksbonjson_addBoolean(KSBONJSONEncodeContext* const ctx, const bool value)
{
    KSBONJSONContainerState* const container = getContainer(ctx);
    SHOULD_NOT_BE_EXPECTING_OBJECT_NAME(container);
    container->isExpectingName = true;
    return addEncodedByte(ctx, value ? TYPE_TRUE : TYPE_FALSE);
}

ksbonjson_encodeStatus ksbonjson_addUnsignedInteger(KSBONJSONEncodeContext* const ctx, const uint64_t value)
{
    KSBONJSONContainerState* const container = getContainer(ctx);
    SHOULD_NOT_BE_EXPECTING_OBJECT_NAME(container);
    container->isExpectingName = true;

    if(value <= (uint64_t)SMALLINT_MAX)
    {
        return encodeSmallInt(ctx, (int64_t)value);
    }

    size_t byteCount = ksbonjson_roundToNativeSize(ksbonjson_uintBytesMin1(value));
    uint8_t msb = (uint8_t)(value >> (byteCount * 8 - 1));
    uint8_t base = msb ? TYPE_UINT8 : TYPE_SINT8;
    uint8_t typeCode = (uint8_t)(base + ksbonjson_nativeSizeIndex[byteCount]);

    return encodePrimitiveNumeric(ctx, typeCode, value, byteCount);
}

ksbonjson_encodeStatus ksbonjson_addSignedInteger(KSBONJSONEncodeContext* const ctx, const int64_t value)
{
    KSBONJSONContainerState* const container = getContainer(ctx);
    SHOULD_NOT_BE_EXPECTING_OBJECT_NAME(container);
    container->isExpectingName = true;

    if(value >= SMALLINT_MIN && value <= SMALLINT_MAX)
    {
        return encodeSmallInt(ctx, value);
    }

    size_t byteCount;
    uint8_t typeCode;

    if (value > 0)
    {
        size_t unsignedBytes = ksbonjson_roundToNativeSize(ksbonjson_uintBytesMin1((uint64_t)value));
        size_t signedBytes = ksbonjson_roundToNativeSize(ksbonjson_sintBytesMin1(value));

        if (unsignedBytes < signedBytes)
        {
            byteCount = unsignedBytes;
            typeCode = (uint8_t)(TYPE_UINT8 + ksbonjson_nativeSizeIndex[byteCount]);
        }
        else
        {
            byteCount = signedBytes;
            uint8_t msb = (uint8_t)(value >> (byteCount * 8 - 1));
            uint8_t base = msb ? TYPE_UINT8 : TYPE_SINT8;
            typeCode = (uint8_t)(base + ksbonjson_nativeSizeIndex[byteCount]);
        }
    }
    else
    {
        byteCount = ksbonjson_roundToNativeSize(ksbonjson_sintBytesMin1(value));
        typeCode = (uint8_t)(TYPE_SINT8 + ksbonjson_nativeSizeIndex[byteCount]);
    }

    return encodePrimitiveNumeric(ctx, typeCode, (uint64_t)value, byteCount);
}

ksbonjson_encodeStatus ksbonjson_addFloat(KSBONJSONEncodeContext* const ctx, const double value)
{
    const int64_t asInt = (int64_t)value;

#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wfloat-equal"
    if((double)asInt == value)
    {
        return ksbonjson_addSignedInteger(ctx, asInt);
    }
#pragma GCC diagnostic pop

    KSBONJSONContainerState* const container = getContainer(ctx);
    SHOULD_NOT_BE_EXPECTING_OBJECT_NAME(container);

    union num64_bits b64 = {.f64 = value};
    unlikely_if((b64.u64 & 0x7ff0000000000000ULL) == 0x7ff0000000000000ULL)
    {
        return KSBONJSON_ENCODE_INVALID_DATA;
    }

    container->isExpectingName = true;

    // Try float32
    const union num32_bits b32 = { .f32 = (float)value };
    union num64_bits compare = { .f64 = (double)b32.f32 };

#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wfloat-equal"
    if (compare.f64 == value)
#pragma GCC diagnostic pop
    {
        return encodePrimitiveNumeric(ctx, TYPE_FLOAT32, b32.u32, 4);
    }

    return encodePrimitiveNumeric(ctx, TYPE_FLOAT64, b64.u64, 8);
}

ksbonjson_encodeStatus ksbonjson_addBigNumber(KSBONJSONEncodeContext* const ctx, const KSBigNumber value)
{
    KSBONJSONContainerState* const container = getContainer(ctx);
    SHOULD_NOT_BE_EXPECTING_OBJECT_NAME(container);

    container->isExpectingName = true;

    // BigNumber: type_code + zigzag_leb128(exponent) + zigzag_leb128(signed_length) + magnitude
    uint8_t buf[29]; // 1 + 10 + 10 + 8 max
    buf[0] = TYPE_BIG_NUMBER;
    size_t pos = 1;

    pos += ksbonjson_writeZigzagLEB128(buf + pos, (int64_t)value.exponent);

    if (value.significand == 0)
    {
        buf[pos++] = 0x00; // signed_length = 0, no magnitude bytes
    }
    else
    {
        // Convert significand to LE bytes and find normalized length
        uint8_t magnitude[8];
        uint64_t sig = value.significand;
        size_t byteCount = 0;
        while (sig != 0)
        {
            magnitude[byteCount++] = (uint8_t)(sig & 0xFF);
            sig >>= 8;
        }

        // Write signed_length as zigzag LEB128
        int64_t signedLength = (int64_t)byteCount;
        if (value.significandSign < 0) signedLength = -signedLength;
        pos += ksbonjson_writeZigzagLEB128(buf + pos, signedLength);

        // Write raw LE magnitude bytes
        memcpy(buf + pos, magnitude, byteCount);
        pos += byteCount;
    }

    return addEncodedBytes(ctx, buf, pos);
}

ksbonjson_encodeStatus ksbonjson_addNull(KSBONJSONEncodeContext* const ctx)
{
    KSBONJSONContainerState* const container = getContainer(ctx);
    SHOULD_NOT_BE_EXPECTING_OBJECT_NAME(container);
    container->isExpectingName = true;
    return addEncodedByte(ctx, TYPE_NULL);
}

ksbonjson_encodeStatus ksbonjson_addString(KSBONJSONEncodeContext* const ctx,
                                           const char* const value,
                                           const size_t valueLength)
{
    KSBONJSONContainerState* const container = getContainer(ctx);
    SHOULD_NOT_BE_NULL(value);

    container->isExpectingName = !container->isExpectingName;

    if(valueLength <= 15)
    {
        uint8_t buffer[16];
        buffer[0] = (uint8_t)(TYPE_STRING0 + valueLength);
        memcpy(buffer+1, (const uint8_t*)value, valueLength);
        return addEncodedBytes(ctx, buffer, valueLength+1);
    }

    // Long string: FF + data + FF
    uint8_t marker = TYPE_STRING_LONG;
    PROPAGATE_ERROR(addEncodedByte(ctx, marker));
    PROPAGATE_ERROR(addEncodedBytes(ctx, (const uint8_t*)value, valueLength));
    return addEncodedByte(ctx, marker);
}

ksbonjson_encodeStatus ksbonjson_addBONJSONDocument(KSBONJSONEncodeContext* const ctx,
                                                    const uint8_t* const bonjsonDocument,
                                                    const size_t documentLength)
{
    KSBONJSONContainerState* const container = getContainer(ctx);
    SHOULD_NOT_BE_EXPECTING_OBJECT_NAME(container);
    container->isExpectingName = true;
    return addEncodedBytes(ctx, bonjsonDocument, documentLength);
}

ksbonjson_encodeStatus ksbonjson_beginObject(KSBONJSONEncodeContext* const ctx)
{
    return beginContainer(ctx, TYPE_OBJECT, (KSBONJSONContainerState)
                                            {
                                                .isObject = true,
                                                .isExpectingName = true,
                                            });
}

ksbonjson_encodeStatus ksbonjson_beginArray(KSBONJSONEncodeContext* const ctx)
{
    return beginContainer(ctx, TYPE_ARRAY, (KSBONJSONContainerState){0});
}

ksbonjson_encodeStatus ksbonjson_endContainer(KSBONJSONEncodeContext* const ctx)
{
    KSBONJSONContainerState* const container = getContainer(ctx);
    SHOULD_NOT_BE_EXPECTING_OBJECT_VALUE(container);

    unlikely_if(ctx->containerDepth <= 0)
    {
        return KSBONJSON_ENCODE_CLOSED_TOO_MANY_CONTAINERS;
    }

    ctx->containerDepth--;
    // Write end marker
    return addEncodedByte(ctx, TYPE_END);
}

const char* ksbonjson_describeEncodeStatus(const ksbonjson_encodeStatus status)
{
    switch (status)
    {
        case KSBONJSON_ENCODE_OK:
            return "Successful completion";
        case KSBONJSON_ENCODE_EXPECTED_OBJECT_NAME:
            return "Expected an object element name, but got a non-string";
        case KSBONJSON_ENCODE_EXPECTED_OBJECT_VALUE:
            return "Attempted to close an object while it's expecting a value for the current name";
        case KSBONJSON_ENCODE_NULL_POINTER:
            return "Passed in a NULL pointer";
        case KSBONJSON_ENCODE_CLOSED_TOO_MANY_CONTAINERS:
            return "Attempted to close more containers than there actually are";
        case KSBONJSON_ENCODE_CONTAINERS_ARE_STILL_OPEN:
            return "Attempted to end the encoding while there are still containers open";
        case KSBONJSON_ENCODE_INVALID_DATA:
            return "The object to encode contains invalid data";
        case KSBONJSON_ENCODE_TOO_BIG:
            return "Passed in data was too big or long";
        case KSBONJSON_ENCODE_BUFFER_TOO_SMALL:
            return "Buffer is too small for the encoded data";
        case KSBONJSON_ENCODE_NUL_CHARACTER:
            return "A string value contained a NUL character";
        case KSBONJSON_ENCODE_MAX_DEPTH_EXCEEDED:
            return "Maximum container depth exceeded";
        case KSBONJSON_ENCODE_MAX_STRING_LENGTH_EXCEEDED:
            return "Maximum string length exceeded";
        case KSBONJSON_ENCODE_MAX_CONTAINER_SIZE_EXCEEDED:
            return "Maximum container size exceeded";
        case KSBONJSON_ENCODE_MAX_DOCUMENT_SIZE_EXCEEDED:
            return "Maximum document size exceeded";
        case KSBONJSON_ENCODE_COULD_NOT_ADD_DATA:
            return "addEncodedBytes() failed to process the passed in data";
        default:
            return "(unknown status - was it a user-defined status code?)";
    }
}
