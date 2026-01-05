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

#include "KSBONJSONEncoder.h"
#include "KSBONJSONCommon.h"
#include <string.h>
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
// Utility Functions (shared by both APIs)
// ============================================================================

static uint64_t toLittleEndian(uint64_t v)
{
#if KSBONJSON_IS_LITTLE_ENDIAN
    return v;
#else
    return (v>>56) | ((v&0x00ff000000000000ULL)>>40) | ((v&0x0000ff0000000000ULL)>>24) |
           ((v&0x000000ff00000000ULL)>> 8) | ((v&0x00000000ff000000ULL)<< 8) |
           (v<<56) | ((v&0x000000000000ff00ULL)<<40) | ((v&0x0000000000ff0000ULL)<<24);
#endif
}

#if !HAS_BUILTIN(__builtin_clrsbll)
static uint64_t absoluteValue64(int64_t value)
{
    const int64_t mask = value >> (sizeof(value) * 8 - 1);
    return (uint64_t)((value + mask) ^ mask);
}
#endif

static size_t leadingZeroBitsMax63(uint64_t value)
{
    value |= 1;
#if HAS_BUILTIN(__builtin_clzll)
    return (size_t)__builtin_clzll(value);
#elif defined(_MSC_VER)
    unsigned long first1 = 0;
    _BitScanReverse64(&first1, value);
    return 63 - first1;
#else
    value |= value >> 1;
    value |= value >> 2;
    value |= value >> 4;
    value |= value >> 8;
    value |= value >> 16;
    value |= value >> 32;
    value = ~value;
    value &= -value;
    const union num32_bits u = { .f32 = (float)value };
    uint64_t sigBitCount = ((u.u32>>23) - 0x7f) & 0xff;
    sigBitCount = ((sigBitCount&0x7f) ^ (sigBitCount>>7)) | ((sigBitCount&0x80)>>1);
    return 64 - sigBitCount;
#endif
}

static size_t requiredUnsignedIntegerBytesMin1(uint64_t value)
{
    return (63 - leadingZeroBitsMax63(value)) / 8 + 1;
}

static size_t calcLengthExtraByteCountNeeded(uint64_t length)
{
    return (63 - leadingZeroBitsMax63(length)) / 7;
}

static size_t requiredUnsignedIntegerBytesMin0(uint64_t value)
{
    return requiredUnsignedIntegerBytesMin1(value) - !value;
}

static size_t requiredSignedIntegerBytesMin1(int64_t value)
{
#if HAS_BUILTIN(__builtin_clrsbll)
    return (63 - (size_t)__builtin_clrsbll(value | 1)) / 8 + 1;
#else
    const size_t leadingZeroBitCount = leadingZeroBitsMax63(absoluteValue64(value));
    const size_t byteCountToRemove = leadingZeroBitCount / 8;
    const int64_t highBytesRemoved = value << byteCountToRemove*8;
    const size_t signDidChange = ((value ^ highBytesRemoved) >> 63) & 1;
    return 8 - byteCountToRemove + signDidChange;
#endif
}

static size_t requiredSignedIntegerBytesMin0(int64_t value)
{
    return requiredSignedIntegerBytesMin1(value) - !value;
}

static void encodeIntegerIntoBytes(uint64_t value, uint8_t* bytes, size_t byteCount)
{
    value = toLittleEndian(value);
    memcpy(bytes, &value, byteCount);
}

// Encode a length field into the bits array, returning total byte count
static size_t encodeLengthField(uint64_t length,
                                uint8_t anotherChunkFollows,
                                union num64_bits bits[2])
{
    uint64_t payload = (length << 1) | anotherChunkFollows;

    unlikely_if(payload > 0x008fffffffffffff)
    {
        bits[0].b[0] = 7;
        bits[0].b[7] = 0;
        bits[1].u64 = toLittleEndian(payload);
        return 9;
    }

    const size_t extraByteCount = calcLengthExtraByteCountNeeded(payload);
    payload <<= 1;
    payload |= 1;
    payload <<= extraByteCount;

    bits[0].b[0] = 8;
    bits[1].u64 = toLittleEndian(payload);
    return extraByteCount + 1;
}


// ============================================================================
// Buffer-Based Encoder Implementation (NEW - High Performance API)
// ============================================================================

// Internal macros for buffer-based encoding
#define BUF_REMAINING(ctx) ((ctx)->capacity - (ctx)->position)
#define BUF_PTR(ctx) ((ctx)->buffer + (ctx)->position)

static inline KSBONJSONContainerState* getBufferContainer(KSBONJSONBufferEncodeContext* const ctx)
{
    return &ctx->containers[ctx->containerDepth];
}

// Write bytes directly to buffer - assumes capacity has been checked!
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
    unlikely_if(ctx->containers[ctx->containerDepth].isChunkingString)
    {
        return -KSBONJSON_ENCODE_CHUNKING_STRING;
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

ssize_t ksbonjson_encodeToBuffer_null(KSBONJSONBufferEncodeContext* ctx)
{
    KSBONJSONContainerState* const container = getBufferContainer(ctx);
    unlikely_if((container->isObject & container->isExpectingName) | container->isChunkingString)
    {
        return container->isChunkingString ? -KSBONJSON_ENCODE_CHUNKING_STRING : -KSBONJSON_ENCODE_EXPECTED_OBJECT_NAME;
    }
    container->isExpectingName = true;

    bufferWriteByte(ctx, TYPE_NULL);
    return 1;
}

ssize_t ksbonjson_encodeToBuffer_bool(KSBONJSONBufferEncodeContext* ctx, bool value)
{
    KSBONJSONContainerState* const container = getBufferContainer(ctx);
    unlikely_if((container->isObject & container->isExpectingName) | container->isChunkingString)
    {
        return container->isChunkingString ? -KSBONJSON_ENCODE_CHUNKING_STRING : -KSBONJSON_ENCODE_EXPECTED_OBJECT_NAME;
    }
    container->isExpectingName = true;

    bufferWriteByte(ctx, value ? TYPE_TRUE : TYPE_FALSE);
    return 1;
}

ssize_t ksbonjson_encodeToBuffer_int(KSBONJSONBufferEncodeContext* ctx, int64_t value)
{
    KSBONJSONContainerState* const container = getBufferContainer(ctx);
    unlikely_if((container->isObject & container->isExpectingName) | container->isChunkingString)
    {
        return container->isChunkingString ? -KSBONJSON_ENCODE_CHUNKING_STRING : -KSBONJSON_ENCODE_EXPECTED_OBJECT_NAME;
    }
    container->isExpectingName = true;

    // Small int optimization
    if ((uint64_t)(value - SMALLINT_NEGATIVE_EDGE) <= (SMALLINT_POSITIVE_EDGE - SMALLINT_NEGATIVE_EDGE))
    {
        bufferWriteByte(ctx, (uint8_t)value);
        return 1;
    }

    size_t byteCount = requiredSignedIntegerBytesMin1(value);

    // If it's positive and fits in less bytes as unsigned, save as type unsigned.
    const uint64_t maskOutIfNegative = (uint64_t)~(value >> 63);
    const uint64_t highByteIs0 = !(value >> (8 * (byteCount - 1)));
    const uint64_t isPositiveAndHighByteIs0 = maskOutIfNegative & highByteIs0;

    byteCount -= isPositiveAndHighByteIs0;
    const uint8_t typeCode = (uint8_t)(TYPE_SINT8 + byteCount - 1 - 8 * isPositiveAndHighByteIs0);

    // Write type code + value bytes
    union num64_bits bits[2];
    bits[0].b[7] = typeCode;
    bits[1].u64 = toLittleEndian((uint64_t)value);
    bufferWriteBytes(ctx, &bits[0].b[7], byteCount + 1);

    return (ssize_t)(byteCount + 1);
}

ssize_t ksbonjson_encodeToBuffer_uint(KSBONJSONBufferEncodeContext* ctx, uint64_t value)
{
    KSBONJSONContainerState* const container = getBufferContainer(ctx);
    unlikely_if((container->isObject & container->isExpectingName) | container->isChunkingString)
    {
        return container->isChunkingString ? -KSBONJSON_ENCODE_CHUNKING_STRING : -KSBONJSON_ENCODE_EXPECTED_OBJECT_NAME;
    }
    container->isExpectingName = true;

    if (value <= SMALLINT_POSITIVE_EDGE)
    {
        bufferWriteByte(ctx, (uint8_t)value);
        return 1;
    }

    const size_t byteCount = requiredUnsignedIntegerBytesMin1(value);

    // Save as signed if MSB is cleared (prefer signed over unsigned)
    const uint8_t isMSBSet = (uint8_t)(value >> (byteCount * 8 - 1));
    const uint8_t typeCode = (uint8_t)(TYPE_SINT8 - isMSBSet * 8 + byteCount - 1);

    union num64_bits bits[2];
    bits[0].b[7] = typeCode;
    bits[1].u64 = toLittleEndian(value);
    bufferWriteBytes(ctx, &bits[0].b[7], byteCount + 1);

    return (ssize_t)(byteCount + 1);
}

ssize_t ksbonjson_encodeToBuffer_float(KSBONJSONBufferEncodeContext* ctx, double value)
{
    const int64_t asInt = (int64_t)value;

#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wfloat-equal"
    if ((double)asInt == value)
    {
        return ksbonjson_encodeToBuffer_int(ctx, asInt);
    }
#pragma GCC diagnostic pop

    KSBONJSONContainerState* const container = getBufferContainer(ctx);
    unlikely_if((container->isObject & container->isExpectingName) | container->isChunkingString)
    {
        return container->isChunkingString ? -KSBONJSON_ENCODE_CHUNKING_STRING : -KSBONJSON_ENCODE_EXPECTED_OBJECT_NAME;
    }

    union num64_bits b64 = {.f64 = value};
    unlikely_if((b64.u64 & 0x7ff0000000000000ULL) == 0x7ff0000000000000ULL)
    {
        return -KSBONJSON_ENCODE_INVALID_DATA;
    }

    container->isExpectingName = true;

    // Choose optimal float size
    const union num32_bits b32 = { .f32 = (float)value };
    const union num32_bits b16 = { .u32 = b32.u32 & ~0xffffu };
    union num64_bits compare = { .f64 = (double)b16.f32 };
    const unsigned isF16 = !(compare.u64 ^ b64.u64);
    compare.f64 = (double)b32.f32;
    const unsigned isF32 = !(compare.u64 ^ b64.u64) & !isF16;
    const unsigned isF64 = !isF32 & !isF16;

    const uint8_t typeCode = (uint8_t)(TYPE_FLOAT16 + isF32 + isF64 * 2);
    const unsigned byteCount = 2 + 2 * isF32 + 6 * isF64;

    const uint64_t mask = (isF16 * 0xffff) | (isF32 * 0xffffffff);
    const uint32_t as16Or32Bit = b32.u32 >> (16 * isF16);
    b64.u64 = (b64.u64 & (~mask)) | (as16Or32Bit & mask);

    union num64_bits bits[2];
    bits[0].b[7] = typeCode;
    bits[1].u64 = toLittleEndian(b64.u64);
    bufferWriteBytes(ctx, &bits[0].b[7], byteCount + 1);

    return (ssize_t)(byteCount + 1);
}

ssize_t ksbonjson_encodeToBuffer_bigNumber(KSBONJSONBufferEncodeContext* ctx, KSBigNumber value)
{
    KSBONJSONContainerState* const container = getBufferContainer(ctx);
    unlikely_if((container->isObject & container->isExpectingName) | container->isChunkingString)
    {
        return container->isChunkingString ? -KSBONJSON_ENCODE_CHUNKING_STRING : -KSBONJSON_ENCODE_EXPECTED_OBJECT_NAME;
    }

    unlikely_if(value.exponent < -0x800000 || value.exponent > 0x7fffff)
    {
        return -KSBONJSON_ENCODE_INVALID_DATA;
    }

    container->isExpectingName = true;

    const size_t exponentByteCount = requiredSignedIntegerBytesMin0(value.exponent);
    const size_t significandByteCount = requiredUnsignedIntegerBytesMin0(value.significand);

    union num64_bits bits[2];
    bits[1].u64 = toLittleEndian(value.significand);
    encodeIntegerIntoBytes((uint64_t)value.exponent, bits[0].b + 8 - exponentByteCount, exponentByteCount);
    bits[0].b[8 - exponentByteCount - 1] = (uint8_t)(
        ((value.significandSign >> 31) & 1) |
        (exponentByteCount << 1) |
        (significandByteCount << 3)
    );
    bits[0].b[8 - exponentByteCount - 2] = TYPE_BIG_NUMBER;

    size_t totalBytes = significandByteCount + exponentByteCount + 2;
    bufferWriteBytes(ctx, bits[0].b + 8 - exponentByteCount - 2, totalBytes);

    return (ssize_t)totalBytes;
}

ssize_t ksbonjson_encodeToBuffer_string(KSBONJSONBufferEncodeContext* ctx,
                                        const char* value,
                                        size_t length)
{
    KSBONJSONContainerState* const container = getBufferContainer(ctx);
    unlikely_if(!value || container->isChunkingString)
    {
        return container->isChunkingString ? -KSBONJSON_ENCODE_CHUNKING_STRING : -KSBONJSON_ENCODE_NULL_POINTER;
    }

    // Check for NUL characters if required
    if (ctx->flags.rejectNUL)
    {
        for (size_t i = 0; i < length; i++)
        {
            unlikely_if(value[i] == '\0')
            {
                return -KSBONJSON_ENCODE_NUL_CHARACTER;
            }
        }
    }

    // String can be a name or value, so flip expectation
    container->isExpectingName = !container->isExpectingName;

    if (length <= 15)
    {
        bufferWriteByte(ctx, (uint8_t)(TYPE_STRING0 + length));
        bufferWriteBytes(ctx, (const uint8_t*)value, length);
        return (ssize_t)(1 + length);
    }

    // Long string: type + length field + string data
    union num64_bits bits[2];
    size_t lengthFieldBytes = encodeLengthField(length, 0, bits) + 1;
    uint8_t* ptr = bits[0].b + bits[0].b[0] - 1;
    *ptr = TYPE_STRING;

    bufferWriteBytes(ctx, ptr, lengthFieldBytes);
    bufferWriteBytes(ctx, (const uint8_t*)value, length);

    return (ssize_t)(lengthFieldBytes + length);
}

ssize_t ksbonjson_encodeToBuffer_beginObject(KSBONJSONBufferEncodeContext* ctx)
{
    KSBONJSONContainerState* const container = getBufferContainer(ctx);
    unlikely_if((container->isObject & container->isExpectingName) | container->isChunkingString)
    {
        return container->isChunkingString ? -KSBONJSON_ENCODE_CHUNKING_STRING : -KSBONJSON_ENCODE_EXPECTED_OBJECT_NAME;
    }
    container->isExpectingName = true;

    ctx->containerDepth++;
    ctx->containers[ctx->containerDepth] = (KSBONJSONContainerState){
        .isObject = true,
        .isExpectingName = true,
    };

    bufferWriteByte(ctx, TYPE_OBJECT);
    return 1;
}

ssize_t ksbonjson_encodeToBuffer_beginArray(KSBONJSONBufferEncodeContext* ctx)
{
    KSBONJSONContainerState* const container = getBufferContainer(ctx);
    unlikely_if((container->isObject & container->isExpectingName) | container->isChunkingString)
    {
        return container->isChunkingString ? -KSBONJSON_ENCODE_CHUNKING_STRING : -KSBONJSON_ENCODE_EXPECTED_OBJECT_NAME;
    }
    container->isExpectingName = true;

    ctx->containerDepth++;
    ctx->containers[ctx->containerDepth] = (KSBONJSONContainerState){0};

    bufferWriteByte(ctx, TYPE_ARRAY);
    return 1;
}

ssize_t ksbonjson_encodeToBuffer_endContainer(KSBONJSONBufferEncodeContext* ctx)
{
    KSBONJSONContainerState* const container = getBufferContainer(ctx);
    unlikely_if((container->isObject & !container->isExpectingName) | container->isChunkingString)
    {
        return container->isChunkingString ? -KSBONJSON_ENCODE_CHUNKING_STRING : -KSBONJSON_ENCODE_EXPECTED_OBJECT_VALUE;
    }

    unlikely_if(ctx->containerDepth <= 0)
    {
        return -KSBONJSON_ENCODE_CLOSED_TOO_MANY_CONTAINERS;
    }

    ctx->containerDepth--;
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

// Batch encoding - optimized for arrays of primitives


// Internal: encode a single int64 without container state checks (for batch use)
static inline size_t encodeInt64Fast(KSBONJSONBufferEncodeContext* ctx, int64_t value)
{
    // Small int optimization
    if ((uint64_t)(value - SMALLINT_NEGATIVE_EDGE) <= (SMALLINT_POSITIVE_EDGE - SMALLINT_NEGATIVE_EDGE))
    {
        bufferWriteByte(ctx, (uint8_t)value);
        return 1;
    }

    size_t byteCount = requiredSignedIntegerBytesMin1(value);

    // If it's positive and fits in less bytes as unsigned, save as type unsigned.
    const uint64_t maskOutIfNegative = (uint64_t)~(value >> 63);
    const uint64_t highByteIs0 = !(value >> (8 * (byteCount - 1)));
    const uint64_t isPositiveAndHighByteIs0 = maskOutIfNegative & highByteIs0;

    byteCount -= isPositiveAndHighByteIs0;
    const uint8_t typeCode = (uint8_t)(TYPE_SINT8 + byteCount - 1 - 8 * isPositiveAndHighByteIs0);

    // Write type code + value bytes
    union num64_bits bits[2];
    bits[0].b[7] = typeCode;
    bits[1].u64 = toLittleEndian((uint64_t)value);
    bufferWriteBytes(ctx, &bits[0].b[7], byteCount + 1);

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
        // Value can be represented exactly as integer - use int encoding
        return encodeInt64Fast(ctx, asInt);
    }

    // Use float encoding
    bufferWriteByte(ctx, TYPE_FLOAT64);
    union num64_bits bits;
    bits.f64 = value;
    bits.u64 = toLittleEndian(bits.u64);
    bufferWriteBytes(ctx, bits.b, 8);
    return 9;
}

ssize_t ksbonjson_encodeToBuffer_int64Array(
    KSBONJSONBufferEncodeContext* ctx,
    const int64_t* values,
    size_t count)
{
    KSBONJSONContainerState* const container = getBufferContainer(ctx);
    unlikely_if((container->isObject & container->isExpectingName) | container->isChunkingString)
    {
        return container->isChunkingString ? -KSBONJSON_ENCODE_CHUNKING_STRING : -KSBONJSON_ENCODE_EXPECTED_OBJECT_NAME;
    }
    container->isExpectingName = true;

    size_t totalBytes = 0;

    // Begin array
    ctx->containerDepth++;
    ctx->containers[ctx->containerDepth] = (KSBONJSONContainerState){0};
    bufferWriteByte(ctx, TYPE_ARRAY);
    totalBytes++;

    // Encode all values in tight loop (no per-element state checks)
    for (size_t i = 0; i < count; i++)
    {
        totalBytes += encodeInt64Fast(ctx, values[i]);
    }

    // End array
    ctx->containerDepth--;
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
    unlikely_if((container->isObject & container->isExpectingName) | container->isChunkingString)
    {
        return container->isChunkingString ? -KSBONJSON_ENCODE_CHUNKING_STRING : -KSBONJSON_ENCODE_EXPECTED_OBJECT_NAME;
    }
    container->isExpectingName = true;

    size_t totalBytes = 0;

    // Begin array
    ctx->containerDepth++;
    ctx->containers[ctx->containerDepth] = (KSBONJSONContainerState){0};
    bufferWriteByte(ctx, TYPE_ARRAY);
    totalBytes++;

    // Encode all values in tight loop (no per-element state checks)
    for (size_t i = 0; i < count; i++)
    {
        totalBytes += encodeDoubleFast(ctx, values[i]);
    }

    // End array
    ctx->containerDepth--;
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

    // Long string: type + length field + string data
    union num64_bits bits[2];
    size_t lengthFieldBytes = encodeLengthField(length, 0, bits) + 1;
    uint8_t* ptr = bits[0].b + bits[0].b[0] - 1;
    *ptr = TYPE_STRING;

    bufferWriteBytes(ctx, ptr, lengthFieldBytes);
    bufferWriteBytes(ctx, (const uint8_t*)value, length);

    return lengthFieldBytes + length;
}

ssize_t ksbonjson_encodeToBuffer_stringArray(
    KSBONJSONBufferEncodeContext* ctx,
    const char* const* strings,
    const size_t* lengths,
    size_t count)
{
    KSBONJSONContainerState* const container = getBufferContainer(ctx);
    unlikely_if((container->isObject & container->isExpectingName) | container->isChunkingString)
    {
        return container->isChunkingString ? -KSBONJSON_ENCODE_CHUNKING_STRING : -KSBONJSON_ENCODE_EXPECTED_OBJECT_NAME;
    }
    container->isExpectingName = true;

    // Check for NUL characters in all strings if required
    if (ctx->flags.rejectNUL)
    {
        for (size_t i = 0; i < count; i++)
        {
            const char* str = strings[i];
            size_t len = lengths[i];
            for (size_t j = 0; j < len; j++)
            {
                unlikely_if(str[j] == '\0')
                {
                    return -KSBONJSON_ENCODE_NUL_CHARACTER;
                }
            }
        }
    }

    size_t totalBytes = 0;

    // Begin array
    ctx->containerDepth++;
    ctx->containers[ctx->containerDepth] = (KSBONJSONContainerState){0};
    bufferWriteByte(ctx, TYPE_ARRAY);
    totalBytes++;

    // Encode all strings in tight loop (no per-element state checks)
    for (size_t i = 0; i < count; i++)
    {
        totalBytes += encodeStringFast(ctx, strings[i], lengths[i]);
    }

    // End array
    ctx->containerDepth--;
    bufferWriteByte(ctx, TYPE_END);
    totalBytes++;

    return (ssize_t)totalBytes;
}


// ============================================================================
// Callback-Based Encoder Implementation (Original API)
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

#define SHOULD_NOT_BE_NULL_OR_CHUNKING_STRING(CONTAINER, VALUE) \
    unlikely_if(((!(VALUE)) | (CONTAINER)->isChunkingString)) \
        return (CONTAINER)->isChunkingString ? KSBONJSON_ENCODE_CHUNKING_STRING : KSBONJSON_ENCODE_NULL_POINTER

#define SHOULD_NOT_BE_EXPECTING_OBJECT_NAME_OR_CHUNKING_STRING(CONTAINER) \
    unlikely_if((((CONTAINER)->isObject & (CONTAINER)->isExpectingName) | (CONTAINER)->isChunkingString)) \
        return (CONTAINER)->isChunkingString ? KSBONJSON_ENCODE_CHUNKING_STRING : KSBONJSON_ENCODE_EXPECTED_OBJECT_NAME

#define SHOULD_NOT_BE_EXPECTING_OBJECT_VALUE_OR_CHUNKING_STRING(CONTAINER) \
    unlikely_if((((CONTAINER)->isObject & !(CONTAINER)->isExpectingName) | (CONTAINER)->isChunkingString)) \
        return (CONTAINER)->isChunkingString ? KSBONJSON_ENCODE_CHUNKING_STRING : KSBONJSON_ENCODE_EXPECTED_OBJECT_VALUE

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

static ksbonjson_encodeStatus beginContainer(KSBONJSONEncodeContext* const ctx,
                                             const uint8_t typeCode,
                                             const KSBONJSONContainerState containerState)
{
    KSBONJSONContainerState* const container = getContainer(ctx);
    SHOULD_NOT_BE_EXPECTING_OBJECT_NAME_OR_CHUNKING_STRING(container);
    container->isExpectingName = true;

    ctx->containerDepth++;
    ctx->containers[ctx->containerDepth] = containerState;

    return addEncodedByte(ctx, typeCode);
}

static ksbonjson_encodeStatus encodePrimitiveNumeric(KSBONJSONEncodeContext* const ctx,
                                                     const uint8_t typeCode,
                                                     const uint64_t valueBits,
                                                     size_t byteCount)
{
    union num64_bits bits[2];
    bits[0].b[7] = typeCode;
    bits[1].u64 = toLittleEndian(valueBits);
    return addEncodedBytes(ctx, &bits[0].b[7], byteCount + 1);
}

static ksbonjson_encodeStatus encodeSmallInt(KSBONJSONEncodeContext* const ctx, int64_t value)
{
    return addEncodedByte(ctx, (uint8_t)value);
}

static ksbonjson_encodeStatus encodeLength(KSBONJSONEncodeContext* const ctx,
                                           uint64_t length,
                                           uint8_t anotherChunkFollows)
{
    unlikely_if(length > 0x7fffffffffffffff)
    {
        return KSBONJSON_ENCODE_TOO_BIG;
    }

    union num64_bits bits[2];
    size_t byteCount = encodeLengthField(length, anotherChunkFollows, bits);
    return addEncodedBytes(ctx, bits[0].b + bits[0].b[0], byteCount);
}

static ksbonjson_encodeStatus encodeTypeAndLength(KSBONJSONEncodeContext* const ctx,
                                                  uint8_t typeCode,
                                                  uint64_t length,
                                                  uint8_t anotherChunkFollows)
{
    unlikely_if(length > 0x7fffffffffffffff)
    {
        return KSBONJSON_ENCODE_TOO_BIG;
    }

    union num64_bits bits[2];
    size_t byteCount = encodeLengthField(length, anotherChunkFollows, bits) + 1;
    uint8_t* ptr = bits[0].b + bits[0].b[0] - 1;
    *ptr = typeCode;
    return addEncodedBytes(ctx, ptr, byteCount);
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
    unlikely_if(ctx->containers[ctx->containerDepth].isChunkingString)
    {
        return KSBONJSON_ENCODE_CHUNKING_STRING;
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
    SHOULD_NOT_BE_EXPECTING_OBJECT_NAME_OR_CHUNKING_STRING(container);
    container->isExpectingName = true;
    return addEncodedByte(ctx, value ? TYPE_TRUE : TYPE_FALSE);
}

ksbonjson_encodeStatus ksbonjson_addUnsignedInteger(KSBONJSONEncodeContext* const ctx, const uint64_t value)
{
    KSBONJSONContainerState* const container = getContainer(ctx);
    SHOULD_NOT_BE_EXPECTING_OBJECT_NAME_OR_CHUNKING_STRING(container);
    container->isExpectingName = true;

    if(value <= SMALLINT_POSITIVE_EDGE)
    {
        return encodeSmallInt(ctx, (int64_t)value);
    }

    const size_t byteCount = requiredUnsignedIntegerBytesMin1(value);
    const uint8_t isMSBSet = (uint8_t)(value >> (byteCount * 8 - 1));
    const uint8_t typeCode = (uint8_t)(TYPE_SINT8 - isMSBSet * 8);

    return encodePrimitiveNumeric(ctx, (uint8_t)(typeCode + byteCount - 1), value, byteCount);
}

ksbonjson_encodeStatus ksbonjson_addSignedInteger(KSBONJSONEncodeContext* const ctx, const int64_t value)
{
    KSBONJSONContainerState* const container = getContainer(ctx);
    SHOULD_NOT_BE_EXPECTING_OBJECT_NAME_OR_CHUNKING_STRING(container);
    container->isExpectingName = true;

    if( (uint64_t)(value-SMALLINT_NEGATIVE_EDGE) <= (SMALLINT_POSITIVE_EDGE-SMALLINT_NEGATIVE_EDGE) )
    {
        return encodeSmallInt(ctx, value);
    }

    size_t byteCount = requiredSignedIntegerBytesMin1(value);

    const uint64_t maskOutIfNegative = (uint64_t)~(value>>63);
    const uint64_t highByteIs0 = !(value>>(8*(byteCount-1)));
    const uint64_t isPositiveAndHighByteIs0 = maskOutIfNegative & highByteIs0;

    byteCount -= isPositiveAndHighByteIs0;
    const uint8_t typeCode = (uint8_t)(TYPE_SINT8 + byteCount - 1 - 8*isPositiveAndHighByteIs0);

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
    SHOULD_NOT_BE_EXPECTING_OBJECT_NAME_OR_CHUNKING_STRING(container);

    union num64_bits b64 = {.f64 = value};
    unlikely_if((b64.u64 & 0x7ff0000000000000ULL) == 0x7ff0000000000000ULL)
    {
        return KSBONJSON_ENCODE_INVALID_DATA;
    }

    container->isExpectingName = true;

    const union num32_bits b32 = { .f32 = (float)value };
    const union num32_bits b16 = { .u32 = b32.u32 & ~0xffffu };
    union num64_bits compare = { .f64 = (double)b16.f32 };
    const unsigned isF16 = !(compare.u64 ^ b64.u64);
    compare.f64 = (double)b32.f32;
    const unsigned isF32 = !(compare.u64 ^ b64.u64) & !isF16;
    const unsigned isF64 = !isF32 & !isF16;

    const uint8_t typeCode = (uint8_t)(TYPE_FLOAT16 + isF32 + isF64*2);
    const unsigned byteCount = 2 + 2*isF32 + 6*isF64;

    const uint64_t mask = (isF16*0xffff) | (isF32*0xffffffff);
    const uint32_t as16Or32Bit = b32.u32 >> (16*isF16);
    b64.u64 = (b64.u64&(~mask)) | (as16Or32Bit & mask);

    return encodePrimitiveNumeric(ctx, typeCode, b64.u64, byteCount);
}

ksbonjson_encodeStatus ksbonjson_addBigNumber(KSBONJSONEncodeContext* const ctx, const KSBigNumber value)
{
    KSBONJSONContainerState* const container = getContainer(ctx);
    SHOULD_NOT_BE_EXPECTING_OBJECT_NAME_OR_CHUNKING_STRING(container);

    unlikely_if(value.exponent < -0x800000 || value.exponent > 0x7fffff)
    {
        return KSBONJSON_ENCODE_INVALID_DATA;
    }

    const size_t exponentByteCount = requiredSignedIntegerBytesMin0(value.exponent);
    const size_t significandByteCount = requiredUnsignedIntegerBytesMin0(value.significand);

    union num64_bits bits[2];
    bits[1].u64 = toLittleEndian(value.significand);
    encodeIntegerIntoBytes((uint64_t)value.exponent, bits[0].b+8-exponentByteCount, exponentByteCount);
    bits[0].b[8-exponentByteCount-1] = (uint8_t)
        (
            ((value.significandSign >> 31) & 1) |
            (exponentByteCount << 1) |
            (significandByteCount << 3)
        );
    bits[0].b[8-exponentByteCount-2] = TYPE_BIG_NUMBER;

    return addEncodedBytes(ctx, bits[0].b+8-exponentByteCount-2, significandByteCount + exponentByteCount + 2);
}

ksbonjson_encodeStatus ksbonjson_addNull(KSBONJSONEncodeContext* const ctx)
{
    KSBONJSONContainerState* const container = getContainer(ctx);
    SHOULD_NOT_BE_EXPECTING_OBJECT_NAME_OR_CHUNKING_STRING(container);
    container->isExpectingName = true;
    return addEncodedByte(ctx, TYPE_NULL);
}

ksbonjson_encodeStatus ksbonjson_addString(KSBONJSONEncodeContext* const ctx,
                                           const char* const value,
                                           const size_t valueLength)
{
    KSBONJSONContainerState* const container = getContainer(ctx);
    SHOULD_NOT_BE_NULL_OR_CHUNKING_STRING(container, value);

    container->isExpectingName = !container->isExpectingName;

    if(valueLength <= 15)
    {
        uint8_t buffer[16];
        buffer[0] = (uint8_t)(TYPE_STRING0 + valueLength);
        memcpy(buffer+1, (const uint8_t*)value, valueLength);
        return addEncodedBytes(ctx, buffer, valueLength+1);
    }

    PROPAGATE_ERROR(encodeTypeAndLength(ctx, TYPE_STRING, valueLength, 0));
    return addEncodedBytes(ctx, (const uint8_t*)value, valueLength);
}

ksbonjson_encodeStatus ksbonjson_chunkString(KSBONJSONEncodeContext* const ctx,
                                             const char* const chunk,
                                             const size_t chunkLength,
                                             const bool isLastChunk)
{
    KSBONJSONContainerState* const container = getContainer(ctx);
    SHOULD_NOT_BE_NULL(chunk);

    if(container->isChunkingString)
    {
        PROPAGATE_ERROR(encodeLength(ctx, chunkLength, !isLastChunk));
    }
    else
    {
        PROPAGATE_ERROR(encodeTypeAndLength(ctx, TYPE_STRING, chunkLength, !isLastChunk));
    }

    container->isChunkingString = !isLastChunk;

    if(isLastChunk)
    {
        container->isExpectingName = !container->isExpectingName;
    }

    return addEncodedBytes(ctx, (const uint8_t*)chunk, chunkLength);
}

ksbonjson_encodeStatus ksbonjson_addBONJSONDocument(KSBONJSONEncodeContext* const ctx,
                                                    const uint8_t* const bonjsonDocument,
                                                    const size_t documentLength)
{
    KSBONJSONContainerState* const container = getContainer(ctx);
    SHOULD_NOT_BE_EXPECTING_OBJECT_NAME_OR_CHUNKING_STRING(container);
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
    SHOULD_NOT_BE_EXPECTING_OBJECT_VALUE_OR_CHUNKING_STRING(container);

    unlikely_if(ctx->containerDepth <= 0)
    {
        return KSBONJSON_ENCODE_CLOSED_TOO_MANY_CONTAINERS;
    }

    ctx->containerDepth--;
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
        case KSBONJSON_ENCODE_CHUNKING_STRING:
            return "Attempted to add a discrete value while chunking a string";
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
        case KSBONJSON_ENCODE_COULD_NOT_ADD_DATA:
            return "addEncodedBytes() failed to process the passed in data";
        default:
            return "(unknown status - was it a user-defined status code?)";
    }
}
