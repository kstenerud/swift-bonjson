//
//  KSBONJSONCodec.c
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

#include "KSBONJSONDecoder.h"
#include "KSBONJSONCommon.h"
#include <string.h> // For memcpy() and strnlen()
#include <math.h>   // For pow()
#ifdef _MSC_VER
#include <intrin.h>
#endif

#pragma GCC diagnostic ignored "-Wdeclaration-after-statement"


// ============================================================================
// UTF-8 Validation
// ============================================================================

/**
 * Validate a UTF-8 string, checking for the requested issues:
 * - If rejectInvalidUTF8: Well-formed sequences, no overlong, no surrogates, no >U+10FFFF
 * - If rejectNUL: No NUL characters
 *
 * @param data The UTF-8 data to validate
 * @param length Length of data in bytes
 * @param rejectNUL If true, NUL characters cause validation failure
 * @param rejectInvalidUTF8 If true, invalid UTF-8 sequences cause validation failure
 * @return KSBONJSON_DECODE_OK if valid, error code otherwise
 */
static ksbonjson_decodeStatus validateString(const uint8_t* data, size_t length, bool rejectNUL, bool rejectInvalidUTF8)
{
    // Fast path: if only checking NUL, just scan for 0x00
    if (rejectNUL && !rejectInvalidUTF8)
    {
        for (size_t i = 0; i < length; i++)
        {
            unlikely_if(data[i] == 0x00)
            {
                return KSBONJSON_DECODE_NUL_CHARACTER;
            }
        }
        return KSBONJSON_DECODE_OK;
    }

    // Full UTF-8 validation (with optional NUL check)
    const uint8_t* end = data + length;

    while (data < end)
    {
        uint8_t b0 = *data;

        // ASCII (0x00-0x7F)
        if (b0 < 0x80)
        {
            // Check for NUL
            unlikely_if(rejectNUL && b0 == 0x00)
            {
                return KSBONJSON_DECODE_NUL_CHARACTER;
            }
            data++;
            continue;
        }

        // Invalid: continuation byte without leading byte (0x80-0xBF)
        unlikely_if(b0 < 0xC0)
        {
            return KSBONJSON_DECODE_INVALID_UTF8;
        }

        // Invalid: 0xC0 and 0xC1 are overlong encodings of ASCII
        unlikely_if(b0 < 0xC2)
        {
            return KSBONJSON_DECODE_INVALID_UTF8;
        }

        // 2-byte sequence (0xC2-0xDF)
        if (b0 < 0xE0)
        {
            unlikely_if(data + 1 >= end)
            {
                return KSBONJSON_DECODE_INVALID_UTF8;
            }
            uint8_t b1 = data[1];
            // Check continuation byte
            unlikely_if((b1 & 0xC0) != 0x80)
            {
                return KSBONJSON_DECODE_INVALID_UTF8;
            }
            data += 2;
            continue;
        }

        // 3-byte sequence (0xE0-0xEF)
        if (b0 < 0xF0)
        {
            unlikely_if(data + 2 >= end)
            {
                return KSBONJSON_DECODE_INVALID_UTF8;
            }
            uint8_t b1 = data[1];
            uint8_t b2 = data[2];
            // Check continuation bytes
            unlikely_if((b1 & 0xC0) != 0x80 || (b2 & 0xC0) != 0x80)
            {
                return KSBONJSON_DECODE_INVALID_UTF8;
            }
            // Check for overlong encoding (codepoint < 0x800)
            unlikely_if(b0 == 0xE0 && b1 < 0xA0)
            {
                return KSBONJSON_DECODE_INVALID_UTF8;
            }
            // Check for surrogates (U+D800-U+DFFF)
            // Encoded as 0xED 0xA0-0xBF 0x80-0xBF
            unlikely_if(b0 == 0xED && b1 >= 0xA0)
            {
                return KSBONJSON_DECODE_INVALID_UTF8;
            }
            data += 3;
            continue;
        }

        // 4-byte sequence (0xF0-0xF4)
        if (b0 < 0xF5)
        {
            unlikely_if(data + 3 >= end)
            {
                return KSBONJSON_DECODE_INVALID_UTF8;
            }
            uint8_t b1 = data[1];
            uint8_t b2 = data[2];
            uint8_t b3 = data[3];
            // Check continuation bytes
            unlikely_if((b1 & 0xC0) != 0x80 || (b2 & 0xC0) != 0x80 || (b3 & 0xC0) != 0x80)
            {
                return KSBONJSON_DECODE_INVALID_UTF8;
            }
            // Check for overlong encoding (codepoint < 0x10000)
            unlikely_if(b0 == 0xF0 && b1 < 0x90)
            {
                return KSBONJSON_DECODE_INVALID_UTF8;
            }
            // Check for codepoint > U+10FFFF
            unlikely_if(b0 == 0xF4 && b1 > 0x8F)
            {
                return KSBONJSON_DECODE_INVALID_UTF8;
            }
            data += 4;
            continue;
        }

        // Invalid: bytes 0xF5-0xFF are not valid UTF-8 leading bytes
        return KSBONJSON_DECODE_INVALID_UTF8;
    }

    return KSBONJSON_DECODE_OK;
}


// ============================================================================
// Types
// ============================================================================

union number_bits
{
    uint8_t  b[8];
    uint32_t u32;
    uint64_t u64;
    int64_t  i64;
    float    f32;
    double   f64;
};

#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wpadded"
typedef struct
{
    uint8_t isObject: 1;
    uint8_t isExpectingName: 1;
    uint8_t isChunkingString: 1;
    uint64_t remainingInChunk;  // Remaining elements (array) or pairs (object) in current chunk
    bool moreChunksFollow;      // Whether another chunk follows after current
} ContainerState;

typedef struct
{
    const uint8_t* bufferCurrent;
    const uint8_t* const bufferEnd;
    const KSBONJSONDecodeCallbacks* const callbacks;
    void* const userData;
    int containerDepth;
    ContainerState containers[KSBONJSON_MAX_CONTAINER_DEPTH];
} DecodeContext;
#pragma GCC diagnostic pop


// ============================================================================
// Macros
// ============================================================================

#define PROPAGATE_ERROR(CONTEXT, CALL) \
    do \
    { \
        const ksbonjson_decodeStatus propagatedResult = CALL; \
        unlikely_if(propagatedResult != KSBONJSON_DECODE_OK) \
        { \
            return propagatedResult; \
        } \
    } \
    while(0)

#define SHOULD_HAVE_ROOM_FOR_BYTES(BYTE_COUNT) \
    unlikely_if(ctx->bufferCurrent + (BYTE_COUNT) > ctx->bufferEnd) \
        return KSBONJSON_DECODE_INCOMPLETE

#define SHOULD_NOT_CONTAIN_NUL_CHARS(STRING, LENGTH) \
    unlikely_if(strnlen((const char*)(STRING), LENGTH) != (LENGTH)) \
        return KSBONJSON_DECODE_NUL_CHARACTER


// ============================================================================
// Utility
// ============================================================================

static uint64_t fromLittleEndian(uint64_t v)
{
#if KSBONJSON_IS_LITTLE_ENDIAN
    return v;
#else
    // Most compilers optimize this to a byte-swap instruction
    return (v>>56) | ((v&0x00ff000000000000ULL)>>40) | ((v&0x0000ff0000000000ULL)>>24) |
           ((v&0x000000ff00000000ULL)>> 8) | ((v&0x00000000ff000000ULL)<< 8) |
           (v<<56) | ((v&0x000000000000ff00ULL)<<40) | ((v&0x0000000000ff0000ULL)<<24);
#endif
}

/**
 * Get a length field's total byte count from its header.
 * Note: Undefined for header value 0xff.
 */
static size_t decodeLengthFieldTotalByteCount(uint8_t header)
{
    // Invert header: length field uses trailing 1s terminated by 0
    header = (uint8_t)~header;

#if HAS_BUILTIN(__builtin_ctz)
    return (size_t)__builtin_ctz(header) + 1;
#elif defined(_MSC_VER)
    unsigned long tz = 0;
    _BitScanForward(&tz, header);
    return tz + 1;
#else
    // Isolate lowest 1-bit
    header &= -header;

    // Calculate log2
    uint8_t result = (header & 0xAA) != 0;
    result |= ((header & 0xCC) != 0) << 1;
    result |= ((header & 0xF0) != 0) << 2;

    // Add 1
    return result + 1;
#endif
}

static ksbonjson_decodeStatus decodeLengthPayload(DecodeContext* const ctx, uint64_t *payloadBuffer)
{
    SHOULD_HAVE_ROOM_FOR_BYTES(1);
    const uint8_t header = *ctx->bufferCurrent;
    unlikely_if(header == 0xff)
    {
        ctx->bufferCurrent++;
        SHOULD_HAVE_ROOM_FOR_BYTES(8);
        union number_bits bits;
        memcpy(bits.b, ctx->bufferCurrent, 8);
        ctx->bufferCurrent += 8;
        *payloadBuffer = fromLittleEndian(bits.u64);
        return KSBONJSON_DECODE_OK;
    }

    const size_t count = decodeLengthFieldTotalByteCount(header);
    SHOULD_HAVE_ROOM_FOR_BYTES(count);
    union number_bits bits = {0};
    memcpy(bits.b, ctx->bufferCurrent, count);
    ctx->bufferCurrent += count;
    *payloadBuffer = fromLittleEndian(bits.u64 >> count);
    return KSBONJSON_DECODE_OK;
}

/**
 * Decode a primitive numeric type of the specified size.
 * @param ctx The context
 * @param byteCount Size of the number in bytes. Do NOT set size > 8 as it isn't sanity checked!
 * @param initValue 0 for floats or positive ints, -1 for negative ints.
 */
static union number_bits decodePrimitiveNumeric(DecodeContext* const ctx,
                                                const size_t byteCount,
                                                const int64_t initValue)
{
    union number_bits bits = {.u64 = (uint64_t)initValue};
    const uint8_t* buf = ctx->bufferCurrent;
    ctx->bufferCurrent += byteCount;
    memcpy(bits.b, buf, byteCount);
    bits.u64 = fromLittleEndian(bits.u64);
    return bits;
}

static int8_t fillWithBit7(uint8_t value)
{
    return (int8_t)value >> 7;
}

static int8_t fillWithBit0(uint8_t value)
{
    return (int8_t)(value<<7) >> 7;
}

static uint64_t decodeUnsignedInt(DecodeContext* const ctx, const size_t size)
{
    return decodePrimitiveNumeric(ctx, size, 0).u64;
}

static int64_t decodeSignedInt(DecodeContext* const ctx, const size_t size)
{
    return decodePrimitiveNumeric(ctx, size, fillWithBit7(ctx->bufferCurrent[size-1])).i64;
}

static float decodeFloat16(DecodeContext* const ctx)
{
    union number_bits value = decodePrimitiveNumeric(ctx, 2, 0);
    value.u32 <<= 16;
    return value.f32;
}

static float decodeFloat32(DecodeContext* const ctx)
{
    return decodePrimitiveNumeric(ctx, 4, 0).f32;
}

static double decodeFloat64(DecodeContext* const ctx)
{
    return decodePrimitiveNumeric(ctx, 8, 0).f64;
}

static ksbonjson_decodeStatus reportFloat(DecodeContext* const ctx, const double value)
{
    const union number_bits bits = {.f64 = value};
    unlikely_if((bits.u64 & 0x7ff0000000000000ULL) == 0x7ff0000000000000ULL)
    {
        // When all exponent bits are set, it signifies an infinite or NaN value
        return KSBONJSON_DECODE_INVALID_DATA;
    }
    return ctx->callbacks->onFloat(value, ctx->userData);
}

static ksbonjson_decodeStatus decodeAndReportUnsignedInteger(DecodeContext* const ctx, const uint8_t typeCode)
{
    // Byte count is in lower 3 bits + 1 (0xd0-0xd7 -> 1-8 bytes)
    const size_t size = (size_t)(typeCode & 0x07) + 1;
    SHOULD_HAVE_ROOM_FOR_BYTES(size);
    return ctx->callbacks->onUnsignedInteger(decodeUnsignedInt(ctx, size), ctx->userData);
}

static ksbonjson_decodeStatus decodeAndReportSignedInteger(DecodeContext* const ctx, const uint8_t typeCode)
{
    // Byte count is in lower 3 bits + 1 (0xd8-0xdf -> 1-8 bytes)
    const size_t size = (size_t)(typeCode & 0x07) + 1;
    SHOULD_HAVE_ROOM_FOR_BYTES(size);
    return ctx->callbacks->onSignedInteger(decodeSignedInt(ctx, size), ctx->userData);
}

static ksbonjson_decodeStatus decodeAndReportFloat16(DecodeContext* const ctx)
{
    SHOULD_HAVE_ROOM_FOR_BYTES(2);
    return reportFloat(ctx, (double)decodeFloat16(ctx));
}

static ksbonjson_decodeStatus decodeAndReportFloat32(DecodeContext* const ctx)
{
    SHOULD_HAVE_ROOM_FOR_BYTES(4);
    return reportFloat(ctx, (double)decodeFloat32(ctx));
}

static ksbonjson_decodeStatus decodeAndReportFloat64(DecodeContext* const ctx)
{
    SHOULD_HAVE_ROOM_FOR_BYTES(8);
    return reportFloat(ctx, decodeFloat64(ctx));
}

static ksbonjson_decodeStatus decodeAndReportBigNumber(DecodeContext* const ctx)
{
    SHOULD_HAVE_ROOM_FOR_BYTES(1);
    const uint8_t header = *ctx->bufferCurrent++;

    //   Header Byte
    // ───────────────
    // S S S S S E E N
    // ╰─┴─┼─┴─╯ ╰─┤ ╰─> Significand sign (0 = positive, 1 = negative)
    //     │       ╰───> Exponent Length (0-3 bytes)
    //     ╰───────────> Significand Length (0-31 bytes)

    const int sign = fillWithBit0((uint8_t)header);
    const size_t exponentLength = (header >> 1) & 3;
    const size_t significandLength = header >> 3;

    unlikely_if(significandLength > 8)
    {
        return KSBONJSON_DECODE_VALUE_OUT_OF_RANGE;
    }
    unlikely_if(significandLength == 0)
    {
        unlikely_if(exponentLength != 0)
        {
            // Special BigNumber encodings: Inf or NaN
            return KSBONJSON_DECODE_INVALID_DATA;
        }
        return ctx->callbacks->onBigNumber(ksbonjson_newBigNumber(sign, 0, 0), ctx->userData);
    }

    SHOULD_HAVE_ROOM_FOR_BYTES(significandLength + exponentLength);
    const int32_t exponent = (int32_t)decodeSignedInt(ctx, exponentLength);
    const uint64_t significand = decodeUnsignedInt(ctx, significandLength);

    return ctx->callbacks->onBigNumber(ksbonjson_newBigNumber(sign, significand, exponent), ctx->userData);
}

static ksbonjson_decodeStatus decodeAndReportShortString(DecodeContext* const ctx, const uint8_t typeCode)
{
    // Short string length is in the lower nibble (0xe0-0xef -> length 0-15)
    const size_t length = (size_t)(typeCode & 0x0f);
    SHOULD_HAVE_ROOM_FOR_BYTES(length);
    const uint8_t* const begin = ctx->bufferCurrent;
    ctx->bufferCurrent += length;
    SHOULD_NOT_CONTAIN_NUL_CHARS(begin, length);
    return ctx->callbacks->onString((const char*)begin, length, ctx->userData);
}

static ksbonjson_decodeStatus decodeAndReportLongString(DecodeContext* const ctx)
{
    uint64_t lengthPayload;
    PROPAGATE_ERROR(ctx, decodeLengthPayload(ctx, &lengthPayload));
    uint64_t length = lengthPayload >> 1;
    bool moreChunksFollow = (bool)(lengthPayload&1);
    SHOULD_HAVE_ROOM_FOR_BYTES(length);

    const uint8_t* pos = ctx->bufferCurrent;
    ctx->bufferCurrent += length;
    SHOULD_NOT_CONTAIN_NUL_CHARS(pos, length);

    likely_if(!moreChunksFollow)
    {
        return ctx->callbacks->onString((const char*)pos, length, ctx->userData);
    }

    PROPAGATE_ERROR(ctx, ctx->callbacks->onStringChunk((const char*)pos, length, moreChunksFollow, ctx->userData));

    while(moreChunksFollow)
    {
        PROPAGATE_ERROR(ctx, decodeLengthPayload(ctx, &lengthPayload));
        length = lengthPayload >> 1;
        moreChunksFollow = (bool)(lengthPayload&1);
        SHOULD_HAVE_ROOM_FOR_BYTES(length);
        pos = ctx->bufferCurrent;
        ctx->bufferCurrent += length;
        SHOULD_NOT_CONTAIN_NUL_CHARS(pos, length);
        PROPAGATE_ERROR(ctx, ctx->callbacks->onStringChunk((const char*)pos, length, moreChunksFollow, ctx->userData));
    }

    return KSBONJSON_DECODE_OK;
}

// Read a chunk header for the callback decoder
static ksbonjson_decodeStatus readChunkHeader(DecodeContext* const ctx, uint64_t* outCount, bool* outMoreChunks)
{
    uint64_t payload;
    PROPAGATE_ERROR(ctx, decodeLengthPayload(ctx, &payload));
    *outCount = payload >> 1;
    *outMoreChunks = (payload & 1) != 0;

    // Empty chunk with continuation is invalid (DOS protection)
    unlikely_if(*outCount == 0 && *outMoreChunks)
    {
        return KSBONJSON_DECODE_EMPTY_CHUNK_CONTINUATION;
    }

    return KSBONJSON_DECODE_OK;
}

static ksbonjson_decodeStatus beginArray(DecodeContext* const ctx)
{
    unlikely_if(ctx->containerDepth > KSBONJSON_MAX_CONTAINER_DEPTH)
    {
        return KSBONJSON_DECODE_CONTAINER_DEPTH_EXCEEDED;
    }

    // Read first chunk header
    uint64_t count;
    bool moreChunks;
    PROPAGATE_ERROR(ctx, readChunkHeader(ctx, &count, &moreChunks));

    ctx->containerDepth++;
    ctx->containers[ctx->containerDepth] = (ContainerState){
        .isObject = false,
        .isExpectingName = false,
        .remainingInChunk = count,
        .moreChunksFollow = moreChunks,
    };

    return ctx->callbacks->onBeginArray(ctx->userData);
}

static ksbonjson_decodeStatus beginObject(DecodeContext* const ctx)
{
    unlikely_if(ctx->containerDepth > KSBONJSON_MAX_CONTAINER_DEPTH)
    {
        return KSBONJSON_DECODE_CONTAINER_DEPTH_EXCEEDED;
    }

    // Read first chunk header (count = number of key-value pairs)
    uint64_t count;
    bool moreChunks;
    PROPAGATE_ERROR(ctx, readChunkHeader(ctx, &count, &moreChunks));

    ctx->containerDepth++;
    ctx->containers[ctx->containerDepth] = (ContainerState)
                                            {
                                                .isObject = true,
                                                .isExpectingName = true,
                                                .remainingInChunk = count,
                                                .moreChunksFollow = moreChunks,
                                            };

    return ctx->callbacks->onBeginObject(ctx->userData);
}

static ksbonjson_decodeStatus endContainer(DecodeContext* const ctx)
{
    unlikely_if(ctx->containerDepth <= 0)
    {
        return KSBONJSON_DECODE_UNBALANCED_CONTAINERS;
    }
    ContainerState* const container = &ctx->containers[ctx->containerDepth];
    unlikely_if((container->isObject & !container->isExpectingName))
    {
        return KSBONJSON_DECODE_EXPECTED_OBJECT_VALUE;
    }

    ctx->containerDepth--;
    return ctx->callbacks->onEndContainer(ctx->userData);
}

// Check if container needs more elements, read next chunk if needed, or end container if done
static ksbonjson_decodeStatus checkContainerState(DecodeContext* const ctx)
{
    if (ctx->containerDepth <= 0)
    {
        return KSBONJSON_DECODE_OK;
    }

    ContainerState* const container = &ctx->containers[ctx->containerDepth];

    // Check if we've finished all elements in the current chunk
    while (container->remainingInChunk == 0)
    {
        if (container->moreChunksFollow)
        {
            // Read next chunk header
            uint64_t count;
            bool moreChunks;
            PROPAGATE_ERROR(ctx, readChunkHeader(ctx, &count, &moreChunks));
            container->remainingInChunk = count;
            container->moreChunksFollow = moreChunks;
        }
        else
        {
            // No more chunks - container is complete
            return endContainer(ctx);
        }
    }

    return KSBONJSON_DECODE_OK;
}

static ksbonjson_decodeStatus decodeObjectName(DecodeContext* const ctx, const uint8_t typeCode)
{
    // Short string: 0xe0-0xef (mask-based detection)
    if ((typeCode & TYPE_MASK_SHORT_STRING) == TYPE_SHORT_STRING_BASE)
    {
        return decodeAndReportShortString(ctx, typeCode);
    }
    // Long string: 0xf0
    if (typeCode == TYPE_STRING)
    {
        return decodeAndReportLongString(ctx);
    }
    return KSBONJSON_DECODE_EXPECTED_OBJECT_NAME;
}

static ksbonjson_decodeStatus decodeValue(DecodeContext* const ctx, const uint8_t typeCode)
{
    // Small integers: 0x00-0xc8 (most common case)
    if (typeCode <= TYPE_SMALLINT_MAX)
    {
        return ctx->callbacks->onSignedInteger((int64_t)typeCode - SMALLINT_BIAS, ctx->userData);
    }

    // Short strings: 0xe0-0xef (mask-based detection)
    if ((typeCode & TYPE_MASK_SHORT_STRING) == TYPE_SHORT_STRING_BASE)
    {
        return decodeAndReportShortString(ctx, typeCode);
    }

    // Unsigned integers: 0xd0-0xd7 (mask-based detection)
    if ((typeCode & TYPE_MASK_INT) == TYPE_UINT_BASE)
    {
        return decodeAndReportUnsignedInteger(ctx, typeCode);
    }

    // Signed integers: 0xd8-0xdf (mask-based detection)
    if ((typeCode & TYPE_MASK_INT) == TYPE_SINT_BASE)
    {
        return decodeAndReportSignedInteger(ctx, typeCode);
    }

    // Remaining types: 0xf0-0xf9 (individual checks)
    switch (typeCode)
    {
        case TYPE_STRING:
            return decodeAndReportLongString(ctx);
        case TYPE_BIG_NUMBER:
            return decodeAndReportBigNumber(ctx);
        case TYPE_FLOAT16:
            return decodeAndReportFloat16(ctx);
        case TYPE_FLOAT32:
            return decodeAndReportFloat32(ctx);
        case TYPE_FLOAT64:
            return decodeAndReportFloat64(ctx);
        case TYPE_NULL:
            return ctx->callbacks->onNull(ctx->userData);
        case TYPE_FALSE:
            return ctx->callbacks->onBoolean(false, ctx->userData);
        case TYPE_TRUE:
            return ctx->callbacks->onBoolean(true, ctx->userData);
        case TYPE_ARRAY:
            return beginArray(ctx);
        case TYPE_OBJECT:
            return beginObject(ctx);
        default:
            // Reserved type codes: 0xc9-0xcf, 0xfa-0xff
            return KSBONJSON_DECODE_INVALID_DATA;
    }
}

static ksbonjson_decodeStatus decodeDocument(DecodeContext* const ctx)
{
    static ksbonjson_decodeStatus (*decodeFuncs[2])(DecodeContext*, const uint8_t) =
    {
        decodeValue, decodeObjectName,
    };

    while(ctx->bufferCurrent < ctx->bufferEnd || ctx->containerDepth > 0)
    {
        // Check if current container is done (may read new chunk or end container)
        PROPAGATE_ERROR(ctx, checkContainerState(ctx));

        // If no more containers and no more data, we're done
        if (ctx->containerDepth <= 0 && ctx->bufferCurrent >= ctx->bufferEnd)
        {
            break;
        }

        SHOULD_HAVE_ROOM_FOR_BYTES(1);
        ContainerState* const container = &ctx->containers[ctx->containerDepth];
        const uint8_t typeCode = *ctx->bufferCurrent++;
        PROPAGATE_ERROR(ctx, decodeFuncs[container->isObject & container->isExpectingName](ctx, typeCode));

        // Update container state
        if (ctx->containerDepth > 0)
        {
            ContainerState* const updatedContainer = &ctx->containers[ctx->containerDepth];
            updatedContainer->isExpectingName = !updatedContainer->isExpectingName;

            // Decrement remaining count:
            // - For arrays: decrement after each element
            // - For objects: decrement after each complete pair (when expecting name again)
            if (!updatedContainer->isObject)
            {
                // Array: decrement after each element
                if (updatedContainer->remainingInChunk > 0)
                {
                    updatedContainer->remainingInChunk--;
                }
            }
            else if (updatedContainer->isExpectingName)
            {
                // Object: just finished a value, so pair is complete
                if (updatedContainer->remainingInChunk > 0)
                {
                    updatedContainer->remainingInChunk--;
                }
            }
        }
    }

    unlikely_if(ctx->containerDepth > 0)
    {
        return KSBONJSON_DECODE_UNCLOSED_CONTAINERS;
    }
    return ctx->callbacks->onEndData(ctx->userData);
}


// ============================================================================
// API
// ============================================================================

ksbonjson_decodeStatus ksbonjson_decode(const uint8_t* const document,
                                        const size_t documentLength,
                                        const KSBONJSONDecodeCallbacks* const callbacks,
                                        void* const userData,
                                        size_t* const decodedOffset)
{
    DecodeContext ctx =
        {
            .bufferCurrent = document,
            .bufferEnd = document + documentLength,
            .callbacks = callbacks,
            .userData = userData,
        };

    const ksbonjson_decodeStatus result = decodeDocument(&ctx);
    *decodedOffset = (size_t)(ctx.bufferCurrent - document);
    return result;
}

const char* ksbonjson_describeDecodeStatus(const ksbonjson_decodeStatus status)
{
    switch(status)
    {
        case KSBONJSON_DECODE_OK:
            return "Successful completion";
        case KSBONJSON_DECODE_INCOMPLETE:
            return "Incomplete data (document was truncated?)";
        case KSBONJSON_DECODE_UNCLOSED_CONTAINERS:
            return "Not all containers have been closed yet (likely the document has been truncated)";
        case KSBONJSON_DECODE_CONTAINER_DEPTH_EXCEEDED:
            return "The document had too much container depth";
        case KSBONJSON_DECODE_UNBALANCED_CONTAINERS:
            return "Tried to close too many containers";
        case KSBONJSON_DECODE_EXPECTED_OBJECT_NAME:
            return "Expected to find a string for an object element name";
        case KSBONJSON_DECODE_EXPECTED_OBJECT_VALUE:
            return "Got an end container while expecting an object element value";
        case KSBONJSON_DECODE_COULD_NOT_PROCESS_DATA:
            return "A callback failed to process the passed in data";
        case KSBONJSON_DECODE_INVALID_DATA:
            return "Encountered invalid data";
        case KSBONJSON_DECODE_DUPLICATE_OBJECT_NAME:
            return "This name already exists in the current object";
        case KSBONJSON_DECODE_NUL_CHARACTER:
            return "A string value contained a NUL character";
        case KSBONJSON_DECODE_VALUE_OUT_OF_RANGE:
            return "The value is out of range and cannot be stored without data loss";
        case KSBONJSON_DECODE_MAP_FULL:
            return "The position map entry buffer is full";
        case KSBONJSON_DECODE_INVALID_UTF8:
            return "A string contained invalid UTF-8 (malformed sequence, surrogate, or overlong encoding)";
        case KSBONJSON_DECODE_TOO_MANY_KEYS:
            return "Object has more keys than the duplicate detection limit (256)";
        case KSBONJSON_DECODE_TRAILING_BYTES:
            return "Document has trailing bytes after the root value";
        case KSBONJSON_DECODE_NON_CANONICAL_LENGTH:
            return "Length field uses non-canonical encoding (more bytes than necessary)";
        case KSBONJSON_DECODE_MAX_DEPTH_EXCEEDED:
            return "Maximum container depth exceeded";
        case KSBONJSON_DECODE_MAX_STRING_LENGTH_EXCEEDED:
            return "Maximum string length exceeded";
        case KSBONJSON_DECODE_MAX_CONTAINER_SIZE_EXCEEDED:
            return "Maximum container size exceeded";
        case KSBONJSON_DECODE_MAX_DOCUMENT_SIZE_EXCEEDED:
            return "Maximum document size exceeded";
        case KSBONJSON_DECODE_MAX_CHUNKS_EXCEEDED:
            return "Maximum number of string chunks exceeded";
        case KSBONJSON_DECODE_EMPTY_CHUNK_CONTINUATION:
            return "Empty chunk with continuation bit set is invalid";
        default:
            return "(unknown status - was it a user-defined status code?)";
    }
}


// ============================================================================
// Position Map API Implementation
// ============================================================================

// Helper macros for position map scanning
#define MAP_SHOULD_HAVE_ROOM_FOR_BYTES(BYTE_COUNT) \
    unlikely_if(ctx->position + (BYTE_COUNT) > ctx->inputLength) \
        return KSBONJSON_DECODE_INCOMPLETE

#define MAP_SHOULD_HAVE_ENTRY_SPACE() \
    unlikely_if(ctx->entriesCount >= ctx->entriesCapacity) \
        return KSBONJSON_DECODE_MAP_FULL

// Helper to add an entry and return its index
static inline size_t mapAddEntry(KSBONJSONMapContext* ctx, KSBONJSONMapEntry entry)
{
    size_t index = ctx->entriesCount;
    ctx->entries[index] = entry;
    ctx->entriesCount++;
    return index;
}

// Maximum payload that fits in N bytes: (1 << (7*N)) - 1
// Precomputed for common sizes to avoid overflow
static const uint64_t maxPayloadForBytes[] = {
    0,                     // 0 bytes: not applicable
    0x7FULL,              // 1 byte: 127
    0x3FFFULL,            // 2 bytes: 16383
    0x1FFFFFULL,          // 3 bytes: 2097151
    0x0FFFFFFFULL,        // 4 bytes: 268435455
    0x07FFFFFFFFULL,      // 5 bytes
    0x03FFFFFFFFFFULL,    // 6 bytes
    0x01FFFFFFFFFFFFULL,  // 7 bytes
    0x00FFFFFFFFFFFFFFULL // 8 bytes
};

// Decode a length payload for the position map
static ksbonjson_decodeStatus mapDecodeLengthPayload(KSBONJSONMapContext* ctx, uint64_t* payloadBuffer)
{
    MAP_SHOULD_HAVE_ROOM_FOR_BYTES(1);
    const uint8_t header = ctx->input[ctx->position];

    unlikely_if(header == 0xff)
    {
        ctx->position++;
        MAP_SHOULD_HAVE_ROOM_FOR_BYTES(8);
        union number_bits bits;
        memcpy(bits.b, ctx->input + ctx->position, 8);
        ctx->position += 8;
        uint64_t payload = fromLittleEndian(bits.u64);
        *payloadBuffer = payload;

        // Check for non-canonical: 9-byte encoding only if payload > max for 8 bytes
        unlikely_if(ctx->flags.rejectNonCanonicalLengths && payload <= maxPayloadForBytes[8])
        {
            return KSBONJSON_DECODE_NON_CANONICAL_LENGTH;
        }
        return KSBONJSON_DECODE_OK;
    }

    const size_t count = decodeLengthFieldTotalByteCount(header);
    MAP_SHOULD_HAVE_ROOM_FOR_BYTES(count);
    union number_bits bits = {0};
    memcpy(bits.b, ctx->input + ctx->position, count);
    ctx->position += count;
    uint64_t payload = fromLittleEndian(bits.u64 >> count);
    *payloadBuffer = payload;

    // Check for non-canonical length: could the payload fit in fewer bytes?
    unlikely_if(ctx->flags.rejectNonCanonicalLengths && count > 1 && payload <= maxPayloadForBytes[count - 1])
    {
        return KSBONJSON_DECODE_NON_CANONICAL_LENGTH;
    }

    return KSBONJSON_DECODE_OK;
}

// Decode unsigned int for position map (similar to existing but uses map context)
static uint64_t mapDecodeUnsignedInt(KSBONJSONMapContext* ctx, size_t byteCount)
{
    union number_bits bits = {.u64 = 0};
    memcpy(bits.b, ctx->input + ctx->position, byteCount);
    ctx->position += byteCount;
    return fromLittleEndian(bits.u64);
}

// Decode signed int for position map
static int64_t mapDecodeSignedInt(KSBONJSONMapContext* ctx, size_t byteCount)
{
    int64_t initValue = fillWithBit7(ctx->input[ctx->position + byteCount - 1]);
    union number_bits bits = {.u64 = (uint64_t)initValue};
    memcpy(bits.b, ctx->input + ctx->position, byteCount);
    ctx->position += byteCount;
    return (int64_t)fromLittleEndian(bits.u64);
}

// Decode float16 for position map
static double mapDecodeFloat16(KSBONJSONMapContext* ctx)
{
    union number_bits bits = {.u64 = 0};
    memcpy(bits.b, ctx->input + ctx->position, 2);
    ctx->position += 2;
    bits.u64 = fromLittleEndian(bits.u64);
    bits.u32 <<= 16;
    return (double)bits.f32;
}

// Decode float32 for position map
static double mapDecodeFloat32(KSBONJSONMapContext* ctx)
{
    union number_bits bits = {.u64 = 0};
    memcpy(bits.b, ctx->input + ctx->position, 4);
    ctx->position += 4;
    bits.u64 = fromLittleEndian(bits.u64);
    return (double)bits.f32;
}

// Decode float64 for position map
static double mapDecodeFloat64(KSBONJSONMapContext* ctx)
{
    union number_bits bits = {.u64 = 0};
    memcpy(bits.b, ctx->input + ctx->position, 8);
    ctx->position += 8;
    return bits.f64;
}

// Forward declaration for recursive scanning
static ksbonjson_decodeStatus mapScanValue(KSBONJSONMapContext* ctx, size_t* outIndex);

// Scan a short string (length encoded in type code)
static ksbonjson_decodeStatus mapScanShortString(KSBONJSONMapContext* ctx, uint8_t typeCode, size_t* outIndex)
{
    MAP_SHOULD_HAVE_ENTRY_SPACE();

    // Short string length is in the lower nibble (0xe0-0xef -> length 0-15)
    size_t length = (size_t)(typeCode & 0x0f);
    size_t offset = ctx->position;

    // Check max string length (SIZE_MAX means use spec default)
    size_t maxStrLen = ctx->flags.maxStringLength < SIZE_MAX ? ctx->flags.maxStringLength : KSBONJSON_DEFAULT_MAX_STRING_LENGTH;
    unlikely_if(length > maxStrLen)
    {
        return KSBONJSON_DECODE_MAX_STRING_LENGTH_EXCEEDED;
    }

    MAP_SHOULD_HAVE_ROOM_FOR_BYTES(length);

    // Validate string if required
    if (ctx->flags.rejectInvalidUTF8 || ctx->flags.rejectNUL)
    {
        ksbonjson_decodeStatus status = validateString(ctx->input + offset, length,
                                                        ctx->flags.rejectNUL,
                                                        ctx->flags.rejectInvalidUTF8);
        unlikely_if(status != KSBONJSON_DECODE_OK)
        {
            return status;
        }
    }

    ctx->position += length;

    KSBONJSONMapEntry entry = {
        .type = KSBONJSON_TYPE_STRING,
        .data.string = {
            .offset = (uint32_t)offset,
            .length = (uint32_t)length
        }
    };
    *outIndex = mapAddEntry(ctx, entry);
    return KSBONJSON_DECODE_OK;
}

// Flag bit to indicate a chunked string that needs re-assembly
// This is set in the high bit of the offset field
#define CHUNKED_STRING_FLAG 0x80000000u

// Scan a long string (length in payload)
static ksbonjson_decodeStatus mapScanLongString(KSBONJSONMapContext* ctx, size_t* outIndex)
{
    MAP_SHOULD_HAVE_ENTRY_SPACE();

    // Store position before first length payload for potential re-assembly
    size_t startOffset = ctx->position;
    size_t firstDataOffset = 0;
    size_t totalLength = 0;
    bool isChunked = false;
    bool firstChunk = true;
    size_t chunkCount = 0;

    bool moreChunksFollow = true;
    while (moreChunksFollow)
    {
        chunkCount++;

        // Check max chunks (SIZE_MAX means use spec default)
        size_t maxChunks = ctx->flags.maxChunks < SIZE_MAX ? ctx->flags.maxChunks : KSBONJSON_DEFAULT_MAX_CHUNKS;
        unlikely_if(chunkCount > maxChunks)
        {
            return KSBONJSON_DECODE_MAX_CHUNKS_EXCEEDED;
        }

        uint64_t lengthPayload;
        ksbonjson_decodeStatus status = mapDecodeLengthPayload(ctx, &lengthPayload);
        unlikely_if(status != KSBONJSON_DECODE_OK) return status;

        uint64_t chunkLength = lengthPayload >> 1;
        moreChunksFollow = (bool)(lengthPayload & 1);

        if (firstChunk)
        {
            firstDataOffset = ctx->position;
            firstChunk = false;
            if (moreChunksFollow)
            {
                isChunked = true;
            }
        }

        MAP_SHOULD_HAVE_ROOM_FOR_BYTES(chunkLength);

        // NUL checking can be done per-chunk (NUL is always invalid)
        // UTF-8 validation must wait for the final assembled string
        if (ctx->flags.rejectNUL)
        {
            status = validateString(ctx->input + ctx->position, (size_t)chunkLength,
                                    true, false);
            unlikely_if(status != KSBONJSON_DECODE_OK)
            {
                return status;
            }
        }

        totalLength += (size_t)chunkLength;
        ctx->position += (size_t)chunkLength;

        // Check max string length after accumulating total length (SIZE_MAX means use spec default)
        size_t maxStrLen2 = ctx->flags.maxStringLength < SIZE_MAX ? ctx->flags.maxStringLength : KSBONJSON_DEFAULT_MAX_STRING_LENGTH;
        unlikely_if(totalLength > maxStrLen2)
        {
            return KSBONJSON_DECODE_MAX_STRING_LENGTH_EXCEEDED;
        }
    }

    KSBONJSONMapEntry entry;
    entry.type = KSBONJSON_TYPE_STRING;

    if (isChunked)
    {
        // For chunked strings, store the start offset (before first length payload)
        // with the CHUNKED_STRING_FLAG set, and the raw byte count including all
        // length fields. Swift will re-parse this to assemble the string.
        // NOTE: UTF-8 validation for chunked strings must be done by Swift after
        // assembly, since individual chunks may not contain complete UTF-8 sequences.
        size_t rawByteCount = ctx->position - startOffset;
        entry.data.string.offset = (uint32_t)(startOffset | CHUNKED_STRING_FLAG);
        entry.data.string.length = (uint32_t)rawByteCount;
    }
    else
    {
        // Single chunk - validate UTF-8 here since string is complete
        if (ctx->flags.rejectInvalidUTF8)
        {
            ksbonjson_decodeStatus status = validateString(ctx->input + firstDataOffset, totalLength,
                                                           false, true);
            unlikely_if(status != KSBONJSON_DECODE_OK)
            {
                return status;
            }
        }
        entry.data.string.offset = (uint32_t)firstDataOffset;
        entry.data.string.length = (uint32_t)totalLength;
    }

    *outIndex = mapAddEntry(ctx, entry);
    return KSBONJSON_DECODE_OK;
}

// Scan an unsigned integer
static ksbonjson_decodeStatus mapScanUnsignedInt(KSBONJSONMapContext* ctx, uint8_t typeCode, size_t* outIndex)
{
    MAP_SHOULD_HAVE_ENTRY_SPACE();

    // Byte count is in lower 3 bits + 1 (0xd0-0xd7 -> 1-8 bytes)
    size_t byteCount = (size_t)(typeCode & 0x07) + 1;
    MAP_SHOULD_HAVE_ROOM_FOR_BYTES(byteCount);

    uint64_t value = mapDecodeUnsignedInt(ctx, byteCount);

    KSBONJSONMapEntry entry = {
        .type = KSBONJSON_TYPE_UINT,
        .data.uintValue = value
    };
    *outIndex = mapAddEntry(ctx, entry);
    return KSBONJSON_DECODE_OK;
}

// Scan a signed integer
static ksbonjson_decodeStatus mapScanSignedInt(KSBONJSONMapContext* ctx, uint8_t typeCode, size_t* outIndex)
{
    MAP_SHOULD_HAVE_ENTRY_SPACE();

    // Byte count is in lower 3 bits + 1 (0xd8-0xdf -> 1-8 bytes)
    size_t byteCount = (size_t)(typeCode & 0x07) + 1;
    MAP_SHOULD_HAVE_ROOM_FOR_BYTES(byteCount);

    int64_t value = mapDecodeSignedInt(ctx, byteCount);

    KSBONJSONMapEntry entry = {
        .type = KSBONJSON_TYPE_INT,
        .data.intValue = value
    };
    *outIndex = mapAddEntry(ctx, entry);
    return KSBONJSON_DECODE_OK;
}

// Scan a float16
static ksbonjson_decodeStatus mapScanFloat16(KSBONJSONMapContext* ctx, size_t* outIndex)
{
    MAP_SHOULD_HAVE_ENTRY_SPACE();
    MAP_SHOULD_HAVE_ROOM_FOR_BYTES(2);

    double value = mapDecodeFloat16(ctx);

    KSBONJSONMapEntry entry = {
        .type = KSBONJSON_TYPE_FLOAT,
        .data.floatValue = value
    };
    *outIndex = mapAddEntry(ctx, entry);
    return KSBONJSON_DECODE_OK;
}

// Scan a float32
static ksbonjson_decodeStatus mapScanFloat32(KSBONJSONMapContext* ctx, size_t* outIndex)
{
    MAP_SHOULD_HAVE_ENTRY_SPACE();
    MAP_SHOULD_HAVE_ROOM_FOR_BYTES(4);

    double value = mapDecodeFloat32(ctx);

    KSBONJSONMapEntry entry = {
        .type = KSBONJSON_TYPE_FLOAT,
        .data.floatValue = value
    };
    *outIndex = mapAddEntry(ctx, entry);
    return KSBONJSON_DECODE_OK;
}

// Scan a float64
static ksbonjson_decodeStatus mapScanFloat64(KSBONJSONMapContext* ctx, size_t* outIndex)
{
    MAP_SHOULD_HAVE_ENTRY_SPACE();
    MAP_SHOULD_HAVE_ROOM_FOR_BYTES(8);

    double value = mapDecodeFloat64(ctx);

    KSBONJSONMapEntry entry = {
        .type = KSBONJSON_TYPE_FLOAT,
        .data.floatValue = value
    };
    *outIndex = mapAddEntry(ctx, entry);
    return KSBONJSON_DECODE_OK;
}

// Scan a big number
static ksbonjson_decodeStatus mapScanBigNumber(KSBONJSONMapContext* ctx, size_t* outIndex)
{
    MAP_SHOULD_HAVE_ENTRY_SPACE();
    MAP_SHOULD_HAVE_ROOM_FOR_BYTES(1);

    const uint8_t header = ctx->input[ctx->position++];

    const int sign = fillWithBit0(header);
    const size_t exponentLength = (header >> 1) & 3;
    const size_t significandLength = header >> 3;

    unlikely_if(significandLength > 8)
    {
        return KSBONJSON_DECODE_VALUE_OUT_OF_RANGE;
    }

    // Special BigNumber encodings (NaN/Infinity): significandLength == 0 with non-zero exponentLength
    // exponentLength encodes the special value type: 1=Infinity (sign determines +/-), 3=NaN
    const uint8_t specialType = (significandLength == 0 && exponentLength != 0) ? (uint8_t)exponentLength : 0;
    unlikely_if(specialType != 0 && ctx->flags.rejectNaNInfinity)
    {
        return KSBONJSON_DECODE_INVALID_DATA;
    }

    int32_t exponent = 0;
    uint64_t significand = 0;

    if (significandLength > 0)
    {
        MAP_SHOULD_HAVE_ROOM_FOR_BYTES(exponentLength + significandLength);
        exponent = (int32_t)mapDecodeSignedInt(ctx, exponentLength);
        significand = mapDecodeUnsignedInt(ctx, significandLength);
    }

    KSBONJSONMapEntry entry = {
        .type = KSBONJSON_TYPE_BIGNUMBER,
        .data.bigNumber = {
            .significand = significand,
            .exponent = exponent,
            .sign = sign,
            .specialType = specialType
        }
    };
    *outIndex = mapAddEntry(ctx, entry);
    return KSBONJSON_DECODE_OK;
}

// Scan an array container (chunked format)
static ksbonjson_decodeStatus mapScanArray(KSBONJSONMapContext* ctx, size_t* outIndex)
{
    MAP_SHOULD_HAVE_ENTRY_SPACE();

    // Check max depth (SIZE_MAX means use compile-time default)
    size_t maxDepth = ctx->flags.maxDepth < SIZE_MAX ? ctx->flags.maxDepth : KSBONJSON_MAX_CONTAINER_DEPTH;
    unlikely_if((size_t)ctx->containerDepth >= maxDepth)
    {
        return KSBONJSON_DECODE_MAX_DEPTH_EXCEEDED;
    }

    // Reserve slot for array entry (we'll update it after scanning children)
    size_t arrayIndex = ctx->entriesCount;
    ctx->entries[arrayIndex] = (KSBONJSONMapEntry){
        .type = KSBONJSON_TYPE_ARRAY,
        .data.container = { .firstChild = 0, .count = 0 }
    };
    ctx->entriesCount++;

    // Push container onto stack
    ctx->containerStack[ctx->containerDepth] = arrayIndex;
    ctx->containerDepth++;

    // The first child will be the next entry
    size_t firstChild = ctx->entriesCount;
    uint32_t totalCount = 0;
    size_t maxContSize = ctx->flags.maxContainerSize < SIZE_MAX ? ctx->flags.maxContainerSize : KSBONJSON_DEFAULT_MAX_CONTAINER_SIZE;

    // Read chunks until continuation bit is 0
    bool moreChunks = true;
    while (moreChunks)
    {
        // Read chunk header (length field with count and continuation bit)
        uint64_t payload;
        ksbonjson_decodeStatus status = mapDecodeLengthPayload(ctx, &payload);
        unlikely_if(status != KSBONJSON_DECODE_OK) return status;

        uint64_t chunkCount = payload >> 1;
        moreChunks = (payload & 1) != 0;

        // Empty chunk with continuation is invalid (DOS protection)
        unlikely_if(chunkCount == 0 && moreChunks)
        {
            return KSBONJSON_DECODE_EMPTY_CHUNK_CONTINUATION;
        }

        // Read 'chunkCount' elements from this chunk
        for (uint64_t i = 0; i < chunkCount; i++)
        {
            size_t childIndex;
            status = mapScanValue(ctx, &childIndex);
            unlikely_if(status != KSBONJSON_DECODE_OK) return status;
            totalCount++;

            unlikely_if(totalCount > maxContSize)
            {
                return KSBONJSON_DECODE_MAX_CONTAINER_SIZE_EXCEEDED;
            }
        }
    }

    // Update the array entry with child info
    ctx->entries[arrayIndex].data.container.firstChild = (uint32_t)firstChild;
    ctx->entries[arrayIndex].data.container.count = totalCount;

    // Pop container
    ctx->containerDepth--;

    *outIndex = arrayIndex;
    return KSBONJSON_DECODE_OK;
}

// Scan an object name (must be a string)
static ksbonjson_decodeStatus mapScanObjectName(KSBONJSONMapContext* ctx, size_t* outIndex)
{
    MAP_SHOULD_HAVE_ROOM_FOR_BYTES(1);
    uint8_t typeCode = ctx->input[ctx->position++];

    // Short string: 0xe0-0xef (mask-based detection)
    if ((typeCode & TYPE_MASK_SHORT_STRING) == TYPE_SHORT_STRING_BASE)
    {
        return mapScanShortString(ctx, typeCode, outIndex);
    }
    // Long string: 0xf0
    if (typeCode == TYPE_STRING)
    {
        return mapScanLongString(ctx, outIndex);
    }
    return KSBONJSON_DECODE_EXPECTED_OBJECT_NAME;
}

/**
 * Compare two string entries for equality.
 * Returns true if the strings are identical.
 */
static inline bool stringsEqual(
    KSBONJSONMapContext* ctx,
    const KSBONJSONMapEntry* a,
    const KSBONJSONMapEntry* b)
{
    if (a->data.string.length != b->data.string.length)
    {
        return false;
    }
    return memcmp(
        ctx->input + a->data.string.offset,
        ctx->input + b->data.string.offset,
        a->data.string.length
    ) == 0;
}

// Maximum number of keys we can track for duplicate detection per object.
// Objects with more keys than this will cause an error if duplicate detection is enabled.
#define MAX_TRACKED_KEYS 256

// Scan an object container
static ksbonjson_decodeStatus mapScanObject(KSBONJSONMapContext* ctx, size_t* outIndex)
{
    MAP_SHOULD_HAVE_ENTRY_SPACE();

    // Check max depth (SIZE_MAX means use compile-time default)
    size_t maxDepth = ctx->flags.maxDepth < SIZE_MAX ? ctx->flags.maxDepth : KSBONJSON_MAX_CONTAINER_DEPTH;
    unlikely_if((size_t)ctx->containerDepth >= maxDepth)
    {
        return KSBONJSON_DECODE_MAX_DEPTH_EXCEEDED;
    }

    // Reserve slot for object entry
    size_t objectIndex = ctx->entriesCount;
    ctx->entries[objectIndex] = (KSBONJSONMapEntry){
        .type = KSBONJSON_TYPE_OBJECT,
        .data.container = { .firstChild = 0, .count = 0 }
    };
    ctx->entriesCount++;

    // Push container onto stack
    ctx->containerStack[ctx->containerDepth] = objectIndex;
    ctx->containerDepth++;

    // The first child will be the next entry
    size_t firstChild = ctx->entriesCount;
    uint32_t entryCount = 0; // counts individual entries (keys + values)
    bool checkDuplicates = ctx->flags.rejectDuplicateKeys;
    size_t maxContSize = ctx->flags.maxContainerSize < SIZE_MAX ? ctx->flags.maxContainerSize : KSBONJSON_DEFAULT_MAX_CONTAINER_SIZE;

    // Track key indices for duplicate detection
    size_t keyIndices[MAX_TRACKED_KEYS];
    size_t keyCount = 0;

    // Read chunks until continuation bit is 0
    // Note: chunk count for objects is the number of key-value PAIRS
    bool moreChunks = true;
    while (moreChunks)
    {
        // Read chunk header (length field with count and continuation bit)
        uint64_t payload;
        ksbonjson_decodeStatus status = mapDecodeLengthPayload(ctx, &payload);
        unlikely_if(status != KSBONJSON_DECODE_OK) return status;

        uint64_t pairCount = payload >> 1;  // Number of key-value pairs in this chunk
        moreChunks = (payload & 1) != 0;

        // Empty chunk with continuation is invalid (DOS protection)
        unlikely_if(pairCount == 0 && moreChunks)
        {
            return KSBONJSON_DECODE_EMPTY_CHUNK_CONTINUATION;
        }

        // Read 'pairCount' key-value pairs from this chunk
        for (uint64_t i = 0; i < pairCount; i++)
        {
            // Scan key (must be string)
            size_t keyIndex;
            status = mapScanObjectName(ctx, &keyIndex);
            unlikely_if(status != KSBONJSON_DECODE_OK) return status;

            // Check for duplicate keys if required
            if (checkDuplicates)
            {
                // Error if object has more keys than we can track
                unlikely_if(keyCount >= MAX_TRACKED_KEYS)
                {
                    return KSBONJSON_DECODE_TOO_MANY_KEYS;
                }

                const KSBONJSONMapEntry* newKey = &ctx->entries[keyIndex];
                // Check against all previous keys in this object
                for (size_t j = 0; j < keyCount; j++)
                {
                    const KSBONJSONMapEntry* existingKey = &ctx->entries[keyIndices[j]];
                    unlikely_if(stringsEqual(ctx, newKey, existingKey))
                    {
                        return KSBONJSON_DECODE_DUPLICATE_OBJECT_NAME;
                    }
                }
                keyIndices[keyCount++] = keyIndex;
            }

            // Scan value
            size_t valueIndex;
            status = mapScanValue(ctx, &valueIndex);
            unlikely_if(status != KSBONJSON_DECODE_OK) return status;

            entryCount += 2; // key + value

            // Check max container size (entryCount/2 = number of key-value pairs)
            unlikely_if((entryCount / 2) > maxContSize)
            {
                return KSBONJSON_DECODE_MAX_CONTAINER_SIZE_EXCEEDED;
            }
        }
    }

    // Update the object entry with child info
    ctx->entries[objectIndex].data.container.firstChild = (uint32_t)firstChild;
    ctx->entries[objectIndex].data.container.count = entryCount;

    // Pop container
    ctx->containerDepth--;

    *outIndex = objectIndex;
    return KSBONJSON_DECODE_OK;
}

// Main value scanner
static ksbonjson_decodeStatus mapScanValue(KSBONJSONMapContext* ctx, size_t* outIndex)
{
    MAP_SHOULD_HAVE_ROOM_FOR_BYTES(1);
    uint8_t typeCode = ctx->input[ctx->position++];

    // Small integers: 0x00-0xc8 (most common case)
    if (typeCode <= TYPE_SMALLINT_MAX)
    {
        MAP_SHOULD_HAVE_ENTRY_SPACE();
        KSBONJSONMapEntry entry = {
            .type = KSBONJSON_TYPE_INT,
            .data.intValue = (int64_t)typeCode - SMALLINT_BIAS
        };
        *outIndex = mapAddEntry(ctx, entry);
        return KSBONJSON_DECODE_OK;
    }

    // Short strings: 0xe0-0xef (mask-based detection)
    if ((typeCode & TYPE_MASK_SHORT_STRING) == TYPE_SHORT_STRING_BASE)
    {
        return mapScanShortString(ctx, typeCode, outIndex);
    }

    // Unsigned integers: 0xd0-0xd7 (mask-based detection)
    if ((typeCode & TYPE_MASK_INT) == TYPE_UINT_BASE)
    {
        return mapScanUnsignedInt(ctx, typeCode, outIndex);
    }

    // Signed integers: 0xd8-0xdf (mask-based detection)
    if ((typeCode & TYPE_MASK_INT) == TYPE_SINT_BASE)
    {
        return mapScanSignedInt(ctx, typeCode, outIndex);
    }

    // Remaining types: 0xf0-0xf9 (individual checks)
    switch (typeCode)
    {
        case TYPE_STRING:
            return mapScanLongString(ctx, outIndex);
        case TYPE_BIG_NUMBER:
            return mapScanBigNumber(ctx, outIndex);
        case TYPE_FLOAT16:
            return mapScanFloat16(ctx, outIndex);
        case TYPE_FLOAT32:
            return mapScanFloat32(ctx, outIndex);
        case TYPE_FLOAT64:
            return mapScanFloat64(ctx, outIndex);
        case TYPE_NULL:
        {
            MAP_SHOULD_HAVE_ENTRY_SPACE();
            KSBONJSONMapEntry entry = { .type = KSBONJSON_TYPE_NULL };
            *outIndex = mapAddEntry(ctx, entry);
            return KSBONJSON_DECODE_OK;
        }
        case TYPE_FALSE:
        {
            MAP_SHOULD_HAVE_ENTRY_SPACE();
            KSBONJSONMapEntry entry = { .type = KSBONJSON_TYPE_FALSE };
            *outIndex = mapAddEntry(ctx, entry);
            return KSBONJSON_DECODE_OK;
        }
        case TYPE_TRUE:
        {
            MAP_SHOULD_HAVE_ENTRY_SPACE();
            KSBONJSONMapEntry entry = { .type = KSBONJSON_TYPE_TRUE };
            *outIndex = mapAddEntry(ctx, entry);
            return KSBONJSON_DECODE_OK;
        }
        case TYPE_ARRAY:
            return mapScanArray(ctx, outIndex);
        case TYPE_OBJECT:
            return mapScanObject(ctx, outIndex);
        default:
            // Reserved type codes: 0xc9-0xcf, 0xfa-0xff
            return KSBONJSON_DECODE_INVALID_DATA;
    }
}


// ============================================================================
// Position Map Public API
// ============================================================================

void ksbonjson_map_beginWithFlags(
    KSBONJSONMapContext* ctx,
    const uint8_t* input,
    size_t inputLength,
    KSBONJSONMapEntry* entries,
    size_t entriesCapacity,
    KSBONJSONDecodeFlags flags)
{
    ctx->input = input;
    ctx->inputLength = inputLength;
    ctx->entries = entries;
    ctx->entriesCapacity = entriesCapacity;
    ctx->entriesCount = 0;
    ctx->rootIndex = 0;
    ctx->position = 0;
    ctx->containerDepth = 0;
    ctx->flags = flags;
}

void ksbonjson_map_begin(
    KSBONJSONMapContext* ctx,
    const uint8_t* input,
    size_t inputLength,
    KSBONJSONMapEntry* entries,
    size_t entriesCapacity)
{
    ksbonjson_map_beginWithFlags(ctx, input, inputLength, entries, entriesCapacity, ksbonjson_defaultDecodeFlags());
}

ksbonjson_decodeStatus ksbonjson_map_scan(KSBONJSONMapContext* ctx)
{
    // Handle empty document
    if (ctx->inputLength == 0)
    {
        return KSBONJSON_DECODE_INCOMPLETE;
    }

    // Check max document size (SIZE_MAX means use spec default)
    size_t maxDocSize = ctx->flags.maxDocumentSize < SIZE_MAX ? ctx->flags.maxDocumentSize : KSBONJSON_DEFAULT_MAX_DOCUMENT_SIZE;
    unlikely_if(ctx->inputLength > maxDocSize)
    {
        return KSBONJSON_DECODE_MAX_DOCUMENT_SIZE_EXCEEDED;
    }

    // Scan the root value
    size_t rootIndex;
    ksbonjson_decodeStatus status = mapScanValue(ctx, &rootIndex);
    if (status != KSBONJSON_DECODE_OK)
    {
        return status;
    }

    ctx->rootIndex = rootIndex;

    // Check for unclosed containers
    unlikely_if(ctx->containerDepth > 0)
    {
        return KSBONJSON_DECODE_UNCLOSED_CONTAINERS;
    }

    // Check for trailing bytes
    unlikely_if(ctx->flags.rejectTrailingBytes && ctx->position < ctx->inputLength)
    {
        return KSBONJSON_DECODE_TRAILING_BYTES;
    }

    return KSBONJSON_DECODE_OK;
}

size_t ksbonjson_map_root(KSBONJSONMapContext* ctx)
{
    return ctx->rootIndex;
}

const KSBONJSONMapEntry* ksbonjson_map_get(KSBONJSONMapContext* ctx, size_t index)
{
    if (index >= ctx->entriesCount)
    {
        return NULL;
    }
    return &ctx->entries[index];
}

size_t ksbonjson_map_count(KSBONJSONMapContext* ctx)
{
    return ctx->entriesCount;
}

const char* ksbonjson_map_getString(
    KSBONJSONMapContext* ctx,
    size_t index,
    size_t* outLength)
{
    if (index >= ctx->entriesCount)
    {
        return NULL;
    }

    const KSBONJSONMapEntry* entry = &ctx->entries[index];
    if (entry->type != KSBONJSON_TYPE_STRING)
    {
        return NULL;
    }

    if (outLength)
    {
        *outLength = entry->data.string.length;
    }
    return (const char*)(ctx->input + entry->data.string.offset);
}

// Helper to compute the size of a subtree rooted at a given index.
// This returns the total number of entries in the subtree (including the root).
static size_t mapSubtreeSize(KSBONJSONMapContext* ctx, size_t index)
{
    if (index >= ctx->entriesCount)
    {
        return 0;
    }

    const KSBONJSONMapEntry* entry = &ctx->entries[index];

    if (entry->type == KSBONJSON_TYPE_ARRAY || entry->type == KSBONJSON_TYPE_OBJECT)
    {
        // For containers, size = 1 (self) + sum of child subtree sizes
        size_t totalSize = 1;
        size_t childPos = entry->data.container.firstChild;
        for (uint32_t i = 0; i < entry->data.container.count; i++)
        {
            size_t childSize = mapSubtreeSize(ctx, childPos);
            totalSize += childSize;
            childPos += childSize;
        }
        return totalSize;
    }
    else
    {
        // Primitives have size 1
        return 1;
    }
}

size_t ksbonjson_map_getChild(
    KSBONJSONMapContext* ctx,
    size_t containerIndex,
    size_t childIndex)
{
    if (containerIndex >= ctx->entriesCount)
    {
        return SIZE_MAX;
    }

    const KSBONJSONMapEntry* entry = &ctx->entries[containerIndex];
    if (entry->type != KSBONJSON_TYPE_ARRAY && entry->type != KSBONJSON_TYPE_OBJECT)
    {
        return SIZE_MAX;
    }

    if (childIndex >= entry->data.container.count)
    {
        return SIZE_MAX;
    }

    // Walk from firstChild, skipping over subtrees until we reach childIndex
    size_t currentIndex = entry->data.container.firstChild;
    for (size_t i = 0; i < childIndex; i++)
    {
        currentIndex += mapSubtreeSize(ctx, currentIndex);
    }

    return currentIndex;
}

size_t ksbonjson_map_findKey(
    KSBONJSONMapContext* ctx,
    size_t objectIndex,
    const char* key,
    size_t keyLength)
{
    if (objectIndex >= ctx->entriesCount)
    {
        return SIZE_MAX;
    }

    const KSBONJSONMapEntry* objEntry = &ctx->entries[objectIndex];
    if (objEntry->type != KSBONJSON_TYPE_OBJECT)
    {
        return SIZE_MAX;
    }

    // Object children are stored as key, value, key, value, ...
    // count is the total number of entries (keys + values)
    size_t pairCount = objEntry->data.container.count / 2;
    size_t currentIndex = objEntry->data.container.firstChild;

    for (size_t i = 0; i < pairCount; i++)
    {
        size_t keyIndex = currentIndex;
        const KSBONJSONMapEntry* keyEntry = &ctx->entries[keyIndex];

        // Advance past the key
        currentIndex += mapSubtreeSize(ctx, keyIndex);
        size_t valueIndex = currentIndex;
        // Advance past the value for next iteration
        currentIndex += mapSubtreeSize(ctx, valueIndex);

        if (keyEntry->type != KSBONJSON_TYPE_STRING)
        {
            continue; // Shouldn't happen in valid BONJSON
        }

        if (keyEntry->data.string.length != keyLength)
        {
            continue;
        }

        const char* entryKey = (const char*)(ctx->input + keyEntry->data.string.offset);
        if (memcmp(entryKey, key, keyLength) == 0)
        {
            return valueIndex;
        }
    }

    return SIZE_MAX;
}

size_t ksbonjson_map_estimateEntries(size_t inputLength)
{
    // Conservative estimate: at minimum 1 byte per value (small ints),
    // so at most inputLength entries. In practice, most values are larger,
    // so inputLength / 2 is a reasonable estimate with some headroom.
    // We use inputLength as a safe upper bound.
    if (inputLength == 0)
    {
        return 1; // At least one entry for empty container
    }
    return inputLength;
}


// ============================================================================
// Batch Decode Functions
// ============================================================================

// Helper to convert any numeric entry to int64
static inline int64_t entryToInt64(const KSBONJSONMapEntry* entry)
{
    switch (entry->type)
    {
        case KSBONJSON_TYPE_INT:
            return entry->data.intValue;
        case KSBONJSON_TYPE_UINT:
            return (int64_t)entry->data.uintValue;
        case KSBONJSON_TYPE_FLOAT:
            return (int64_t)entry->data.floatValue;
        case KSBONJSON_TYPE_TRUE:
            return 1;
        case KSBONJSON_TYPE_FALSE:
        case KSBONJSON_TYPE_NULL:
            return 0;
        default:
            return 0;
    }
}

// Helper to convert any numeric entry to uint64
static inline uint64_t entryToUInt64(const KSBONJSONMapEntry* entry)
{
    switch (entry->type)
    {
        case KSBONJSON_TYPE_UINT:
            return entry->data.uintValue;
        case KSBONJSON_TYPE_INT:
            return (uint64_t)entry->data.intValue;
        case KSBONJSON_TYPE_FLOAT:
            return (uint64_t)entry->data.floatValue;
        case KSBONJSON_TYPE_TRUE:
            return 1;
        case KSBONJSON_TYPE_FALSE:
        case KSBONJSON_TYPE_NULL:
            return 0;
        default:
            return 0;
    }
}

// Helper to convert any numeric entry to double
static inline double entryToDouble(const KSBONJSONMapEntry* entry)
{
    switch (entry->type)
    {
        case KSBONJSON_TYPE_FLOAT:
            return entry->data.floatValue;
        case KSBONJSON_TYPE_INT:
            return (double)entry->data.intValue;
        case KSBONJSON_TYPE_UINT:
            return (double)entry->data.uintValue;
        case KSBONJSON_TYPE_BIGNUMBER:
        {
            double significand = (double)entry->data.bigNumber.significand;
            double result = significand * pow(10.0, (double)entry->data.bigNumber.exponent);
            return entry->data.bigNumber.sign < 0 ? -result : result;
        }
        case KSBONJSON_TYPE_TRUE:
            return 1.0;
        case KSBONJSON_TYPE_FALSE:
        case KSBONJSON_TYPE_NULL:
            return 0.0;
        default:
            return 0.0;
    }
}

// Helper to convert entry to bool
static inline bool entryToBool(const KSBONJSONMapEntry* entry)
{
    switch (entry->type)
    {
        case KSBONJSON_TYPE_TRUE:
            return true;
        case KSBONJSON_TYPE_FALSE:
        case KSBONJSON_TYPE_NULL:
            return false;
        case KSBONJSON_TYPE_INT:
            return entry->data.intValue != 0;
        case KSBONJSON_TYPE_UINT:
            return entry->data.uintValue != 0;
        case KSBONJSON_TYPE_FLOAT:
            return entry->data.floatValue != 0.0;
        default:
            return false;
    }
}

size_t ksbonjson_map_decodeInt64Array(
    KSBONJSONMapContext* ctx,
    size_t arrayIndex,
    int64_t* outBuffer,
    size_t maxCount)
{
    if (arrayIndex >= ctx->entriesCount)
    {
        return 0;
    }

    const KSBONJSONMapEntry* arrayEntry = &ctx->entries[arrayIndex];
    if (arrayEntry->type != KSBONJSON_TYPE_ARRAY)
    {
        return 0;
    }

    uint32_t count = arrayEntry->data.container.count;
    if (count > maxCount)
    {
        count = (uint32_t)maxCount;
    }

    // Fast path: iterate through child entries directly
    size_t childIndex = arrayEntry->data.container.firstChild;
    for (uint32_t i = 0; i < count; i++)
    {
        const KSBONJSONMapEntry* childEntry = &ctx->entries[childIndex];
        outBuffer[i] = entryToInt64(childEntry);
        // Advance to next child (primitives have size 1)
        childIndex++;
    }

    return count;
}

size_t ksbonjson_map_decodeUInt64Array(
    KSBONJSONMapContext* ctx,
    size_t arrayIndex,
    uint64_t* outBuffer,
    size_t maxCount)
{
    if (arrayIndex >= ctx->entriesCount)
    {
        return 0;
    }

    const KSBONJSONMapEntry* arrayEntry = &ctx->entries[arrayIndex];
    if (arrayEntry->type != KSBONJSON_TYPE_ARRAY)
    {
        return 0;
    }

    uint32_t count = arrayEntry->data.container.count;
    if (count > maxCount)
    {
        count = (uint32_t)maxCount;
    }

    size_t childIndex = arrayEntry->data.container.firstChild;
    for (uint32_t i = 0; i < count; i++)
    {
        const KSBONJSONMapEntry* childEntry = &ctx->entries[childIndex];
        outBuffer[i] = entryToUInt64(childEntry);
        childIndex++;
    }

    return count;
}

size_t ksbonjson_map_decodeDoubleArray(
    KSBONJSONMapContext* ctx,
    size_t arrayIndex,
    double* outBuffer,
    size_t maxCount)
{
    if (arrayIndex >= ctx->entriesCount)
    {
        return 0;
    }

    const KSBONJSONMapEntry* arrayEntry = &ctx->entries[arrayIndex];
    if (arrayEntry->type != KSBONJSON_TYPE_ARRAY)
    {
        return 0;
    }

    uint32_t count = arrayEntry->data.container.count;
    if (count > maxCount)
    {
        count = (uint32_t)maxCount;
    }

    size_t childIndex = arrayEntry->data.container.firstChild;
    for (uint32_t i = 0; i < count; i++)
    {
        const KSBONJSONMapEntry* childEntry = &ctx->entries[childIndex];
        outBuffer[i] = entryToDouble(childEntry);
        childIndex++;
    }

    return count;
}

size_t ksbonjson_map_decodeBoolArray(
    KSBONJSONMapContext* ctx,
    size_t arrayIndex,
    bool* outBuffer,
    size_t maxCount)
{
    if (arrayIndex >= ctx->entriesCount)
    {
        return 0;
    }

    const KSBONJSONMapEntry* arrayEntry = &ctx->entries[arrayIndex];
    if (arrayEntry->type != KSBONJSON_TYPE_ARRAY)
    {
        return 0;
    }

    uint32_t count = arrayEntry->data.container.count;
    if (count > maxCount)
    {
        count = (uint32_t)maxCount;
    }

    size_t childIndex = arrayEntry->data.container.firstChild;
    for (uint32_t i = 0; i < count; i++)
    {
        const KSBONJSONMapEntry* childEntry = &ctx->entries[childIndex];
        outBuffer[i] = entryToBool(childEntry);
        childIndex++;
    }

    return count;
}

size_t ksbonjson_map_decodeStringArray(
    KSBONJSONMapContext* ctx,
    size_t arrayIndex,
    KSBONJSONStringRef* outBuffer,
    size_t maxCount)
{
    if (arrayIndex >= ctx->entriesCount)
    {
        return 0;
    }

    const KSBONJSONMapEntry* arrayEntry = &ctx->entries[arrayIndex];
    if (arrayEntry->type != KSBONJSON_TYPE_ARRAY)
    {
        return 0;
    }

    uint32_t count = arrayEntry->data.container.count;
    if (count > maxCount)
    {
        count = (uint32_t)maxCount;
    }

    size_t childIndex = arrayEntry->data.container.firstChild;
    for (uint32_t i = 0; i < count; i++)
    {
        const KSBONJSONMapEntry* childEntry = &ctx->entries[childIndex];
        if (childEntry->type == KSBONJSON_TYPE_STRING)
        {
            outBuffer[i].offset = childEntry->data.string.offset;
            outBuffer[i].length = childEntry->data.string.length;
        }
        else
        {
            // Non-string elements get zero offset/length
            outBuffer[i].offset = 0;
            outBuffer[i].length = 0;
        }
        childIndex++;
    }

    return count;
}
