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

// ABOUTME: BONJSON decoder implementation (Phase 3: delimiter-terminated format).
// ABOUTME: Provides callback-based decoder, position-map scanner, and batch decode.

#include "KSBONJSONDecoder.h"
#include "KSBONJSONCommon.h"
#include <string.h> // For memcpy() and strnlen()
#include <math.h>   // For pow()
#include "KSBONJSONSimd.h"
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
    // Fast path: if only checking NUL, use SIMD scan for 0x00
    if (rejectNUL && !rejectInvalidUTF8)
    {
        unlikely_if(ksbonjson_simd_containsByte(data, length, 0x00))
        {
            return KSBONJSON_DECODE_NUL_CHARACTER;
        }
        return KSBONJSON_DECODE_OK;
    }

    // Full UTF-8 validation (with optional NUL check)

    // SIMD fast path: if entire string is ASCII, only need NUL check
    if (ksbonjson_simd_isAllAscii(data, length))
    {
        if (rejectNUL)
        {
            unlikely_if(ksbonjson_simd_containsByte(data, length, 0x00))
            {
                return KSBONJSON_DECODE_NUL_CHARACTER;
            }
        }
        return KSBONJSON_DECODE_OK;
    }

    // Slow path: byte-by-byte UTF-8 validation for strings with non-ASCII
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

// Integer byte counts indexed by type code lower 2 bits: 0->1, 1->2, 2->4, 3->8
static const size_t intByteCounts[] = { 1, 2, 4, 8 };

#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wpadded"
typedef struct
{
    uint8_t isObject: 1;
    uint8_t isExpectingName: 1;
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

static uint64_t decodeUnsignedInt(DecodeContext* const ctx, const size_t size)
{
    return decodePrimitiveNumeric(ctx, size, 0).u64;
}

static int64_t decodeSignedInt(DecodeContext* const ctx, const size_t size)
{
    return decodePrimitiveNumeric(ctx, size, fillWithBit7(ctx->bufferCurrent[size-1])).i64;
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
    const size_t size = intByteCounts[typeCode & 0x03];
    SHOULD_HAVE_ROOM_FOR_BYTES(size);
    return ctx->callbacks->onUnsignedInteger(decodeUnsignedInt(ctx, size), ctx->userData);
}

static ksbonjson_decodeStatus decodeAndReportSignedInteger(DecodeContext* const ctx, const uint8_t typeCode)
{
    const size_t size = intByteCounts[typeCode & 0x03];
    SHOULD_HAVE_ROOM_FOR_BYTES(size);
    return ctx->callbacks->onSignedInteger(decodeSignedInt(ctx, size), ctx->userData);
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
    // BigNumber: zigzag LEB128 exponent + zigzag LEB128 signed_length + LE magnitude bytes
    size_t available = (size_t)(ctx->bufferEnd - ctx->bufferCurrent);

    int64_t exponent;
    size_t bytesRead = ksbonjson_readZigzagLEB128(ctx->bufferCurrent, available, &exponent);
    unlikely_if(bytesRead == 0)
    {
        return KSBONJSON_DECODE_INCOMPLETE;
    }
    ctx->bufferCurrent += bytesRead;
    available -= bytesRead;

    int64_t signedLength;
    bytesRead = ksbonjson_readZigzagLEB128(ctx->bufferCurrent, available, &signedLength);
    unlikely_if(bytesRead == 0)
    {
        return KSBONJSON_DECODE_INCOMPLETE;
    }
    ctx->bufferCurrent += bytesRead;
    available -= bytesRead;

    if (signedLength == 0)
    {
        // Zero significand
        return ctx->callbacks->onBigNumber(ksbonjson_newBigNumber(0, 0, (int32_t)exponent), ctx->userData);
    }

    int sign = signedLength < 0 ? -1 : 0;
    size_t byteCount = (size_t)(signedLength < 0 ? -signedLength : signedLength);

    unlikely_if(byteCount > available)
    {
        return KSBONJSON_DECODE_INCOMPLETE;
    }

    unlikely_if(byteCount > 8)
    {
        return KSBONJSON_DECODE_VALUE_OUT_OF_RANGE;
    }

    // Validate normalization: last byte (most significant) must be non-zero
    unlikely_if(ctx->bufferCurrent[byteCount - 1] == 0)
    {
        return KSBONJSON_DECODE_INVALID_DATA;
    }

    // Read LE magnitude bytes into uint64_t
    uint64_t significand = 0;
    for (size_t i = 0; i < byteCount; i++)
    {
        significand |= (uint64_t)ctx->bufferCurrent[i] << (i * 8);
    }
    ctx->bufferCurrent += byteCount;

    return ctx->callbacks->onBigNumber(ksbonjson_newBigNumber(sign, significand, (int32_t)exponent), ctx->userData);
}

static ksbonjson_decodeStatus decodeAndReportShortString(DecodeContext* const ctx, const uint8_t typeCode)
{
    // Short string length is in the lower nibble (0xD0-0xDF -> length 0-15)
    const size_t length = (size_t)(typeCode - TYPE_STRING0);
    SHOULD_HAVE_ROOM_FOR_BYTES(length);
    const uint8_t* const begin = ctx->bufferCurrent;
    ctx->bufferCurrent += length;
    SHOULD_NOT_CONTAIN_NUL_CHARS(begin, length);
    return ctx->callbacks->onString((const char*)begin, length, ctx->userData);
}

static ksbonjson_decodeStatus decodeAndReportLongString(DecodeContext* const ctx)
{
    // Long string: data bytes until 0xFF terminator
    // 0xFF cannot appear in valid UTF-8, so it's a safe terminator
    const uint8_t* start = ctx->bufferCurrent;
    size_t remaining = (size_t)(ctx->bufferEnd - start);

    // SIMD-accelerated scan for 0xFF terminator
    size_t offset = ksbonjson_simd_findByte(start, remaining, TYPE_STRING_LONG);
    unlikely_if(offset >= remaining)
    {
        return KSBONJSON_DECODE_INCOMPLETE;
    }

    const uint8_t* pos = start + offset;
    size_t length = offset;
    ctx->bufferCurrent = pos + 1; // skip terminator

    SHOULD_NOT_CONTAIN_NUL_CHARS(start, length);
    return ctx->callbacks->onString((const char*)start, length, ctx->userData);
}

static ksbonjson_decodeStatus beginArray(DecodeContext* const ctx)
{
    unlikely_if(ctx->containerDepth > KSBONJSON_MAX_CONTAINER_DEPTH)
    {
        return KSBONJSON_DECODE_CONTAINER_DEPTH_EXCEEDED;
    }

    ctx->containerDepth++;
    ctx->containers[ctx->containerDepth] = (ContainerState){
        .isObject = false,
        .isExpectingName = false,
    };

    return ctx->callbacks->onBeginArray(ctx->userData);
}

static ksbonjson_decodeStatus beginObject(DecodeContext* const ctx)
{
    unlikely_if(ctx->containerDepth > KSBONJSON_MAX_CONTAINER_DEPTH)
    {
        return KSBONJSON_DECODE_CONTAINER_DEPTH_EXCEEDED;
    }

    ctx->containerDepth++;
    ctx->containers[ctx->containerDepth] = (ContainerState)
                                            {
                                                .isObject = true,
                                                .isExpectingName = true,
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

static ksbonjson_decodeStatus decodeObjectName(DecodeContext* const ctx, const uint8_t typeCode)
{
    // Short string: 0x65-0xA7 (range-based detection)
    if (typeCode >= TYPE_STRING0 && typeCode <= TYPE_SHORT_STRING_MAX)
    {
        return decodeAndReportShortString(ctx, typeCode);
    }
    // Long string: 0xFF
    if (typeCode == TYPE_STRING_LONG)
    {
        return decodeAndReportLongString(ctx);
    }
    return KSBONJSON_DECODE_EXPECTED_OBJECT_NAME;
}

// Decode a typed array and report as regular array with individual elements
static ksbonjson_decodeStatus decodeAndReportTypedArray(DecodeContext* const ctx, const uint8_t typeCode)
{
    size_t tableIndex = (size_t)(TYPE_TYPED_UINT8 - typeCode);
    size_t elementSize = (size_t[]){1, 2, 4, 8, 1, 2, 4, 8, 4, 8}[tableIndex];
    int elementKind = (int[]){0, 0, 0, 0, 1, 1, 1, 1, 2, 2}[tableIndex];

    // Read ULEB128 element count
    size_t available = (size_t)(ctx->bufferEnd - ctx->bufferCurrent);
    uint64_t count64;
    size_t bytesRead = ksbonjson_readULEB128(ctx->bufferCurrent, available, &count64);
    unlikely_if(bytesRead == 0)
    {
        return KSBONJSON_DECODE_INCOMPLETE;
    }
    ctx->bufferCurrent += bytesRead;

    uint32_t count = (uint32_t)count64;
    size_t dataBytes = (size_t)count * elementSize;
    SHOULD_HAVE_ROOM_FOR_BYTES(dataBytes);

    // Report as begin array
    PROPAGATE_ERROR(ctx, ctx->callbacks->onBeginArray(ctx->userData));

    // Report individual elements
    for (uint32_t i = 0; i < count; i++)
    {
        union number_bits bits = {.u64 = 0};
        memcpy(bits.b, ctx->bufferCurrent, elementSize);
        ctx->bufferCurrent += elementSize;
        bits.u64 = fromLittleEndian(bits.u64);

        switch (elementKind)
        {
            case 0: // unsigned
            {
                uint64_t mask = elementSize < 8 ? ((uint64_t)1 << (elementSize * 8)) - 1 : UINT64_MAX;
                PROPAGATE_ERROR(ctx, ctx->callbacks->onUnsignedInteger(bits.u64 & mask, ctx->userData));
                break;
            }
            case 1: // signed
            {
                // Re-read with sign extension
                const uint8_t* elemStart = ctx->bufferCurrent - elementSize;
                int8_t signFill = (int8_t)elemStart[elementSize - 1] >> 7;
                union number_bits sbits = {.u64 = (uint64_t)(int64_t)signFill};
                memcpy(sbits.b, elemStart, elementSize);
                sbits.u64 = fromLittleEndian(sbits.u64);
                PROPAGATE_ERROR(ctx, ctx->callbacks->onSignedInteger(sbits.i64, ctx->userData));
                break;
            }
            case 2: // float
            {
                double value;
                if (elementSize == 4)
                    value = (double)bits.f32;
                else
                    value = bits.f64;
                PROPAGATE_ERROR(ctx, reportFloat(ctx, value));
                break;
            }
        }
    }

    // Report end container
    return ctx->callbacks->onEndContainer(ctx->userData);
}

static ksbonjson_decodeStatus decodeValue(DecodeContext* const ctx, const uint8_t typeCode)
{
    // Small integers: 0x00-0x64 (most common case)
    if (typeCode <= TYPE_SMALLINT_MAX)
    {
        return ctx->callbacks->onSignedInteger((int64_t)typeCode, ctx->userData);
    }

    // Short strings: 0x65-0xA7 (range-based detection)
    if (typeCode >= TYPE_STRING0 && typeCode <= TYPE_SHORT_STRING_MAX)
    {
        return decodeAndReportShortString(ctx, typeCode);
    }

    // Unsigned integers: 0xA8-0xAB (mask-based detection)
    if ((typeCode & TYPE_MASK_UINT) == TYPE_UINT_BASE)
    {
        return decodeAndReportUnsignedInteger(ctx, typeCode);
    }

    // Signed integers: 0xAC-0xAF (mask-based detection)
    if ((typeCode & TYPE_MASK_SINT) == TYPE_SINT_BASE)
    {
        return decodeAndReportSignedInteger(ctx, typeCode);
    }

    // Typed arrays: 0xF5-0xFE
    if (typeCode >= TYPE_TYPED_FLOAT64 && typeCode <= TYPE_TYPED_UINT8)
    {
        return decodeAndReportTypedArray(ctx, typeCode);
    }

    // Remaining types (individual checks)
    switch (typeCode)
    {
        case TYPE_STRING_LONG:
            return decodeAndReportLongString(ctx);
        case TYPE_BIG_NUMBER:
            return decodeAndReportBigNumber(ctx);
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
        case TYPE_END:
            return endContainer(ctx);
        default:
            return KSBONJSON_DECODE_INVALID_DATA;
    }
}

static ksbonjson_decodeStatus decodeDocument(DecodeContext* const ctx)
{
    static ksbonjson_decodeStatus (*decodeFuncs[2])(DecodeContext*, const uint8_t) =
    {
        decodeValue, decodeObjectName,
    };

    while(ctx->bufferCurrent < ctx->bufferEnd)
    {
        const uint8_t typeCode = *ctx->bufferCurrent++;

        // Handle container end marker
        if (typeCode == TYPE_END)
        {
            PROPAGATE_ERROR(ctx, endContainer(ctx));

            // Update parent container state after ending child container
            if (ctx->containerDepth > 0)
            {
                ContainerState* const parentContainer = &ctx->containers[ctx->containerDepth];
                if (parentContainer->isObject)
                {
                    parentContainer->isExpectingName = !parentContainer->isExpectingName;
                }
            }
            continue;
        }

        ContainerState* const container = &ctx->containers[ctx->containerDepth];

        if (container->isObject && container->isExpectingName)
        {
            PROPAGATE_ERROR(ctx, decodeObjectName(ctx, typeCode));
        }
        else
        {
            PROPAGATE_ERROR(ctx, decodeValue(ctx, typeCode));
        }

        // Update container state
        if (ctx->containerDepth > 0)
        {
            ContainerState* const updatedContainer = &ctx->containers[ctx->containerDepth];
            if (updatedContainer->isObject)
            {
                updatedContainer->isExpectingName = !updatedContainer->isExpectingName;
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
        case KSBONJSON_DECODE_MAX_DEPTH_EXCEEDED:
            return "Maximum container depth exceeded";
        case KSBONJSON_DECODE_MAX_STRING_LENGTH_EXCEEDED:
            return "Maximum string length exceeded";
        case KSBONJSON_DECODE_MAX_CONTAINER_SIZE_EXCEEDED:
            return "Maximum container size exceeded";
        case KSBONJSON_DECODE_MAX_DOCUMENT_SIZE_EXCEEDED:
            return "Maximum document size exceeded";
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

// Helper to add an entry and return its index (subtreeSize defaults to 1)
static inline size_t mapAddEntry(KSBONJSONMapContext* ctx, KSBONJSONMapEntry entry)
{
    size_t index = ctx->entriesCount;
    entry.subtreeSize = 1;
    ctx->entries[index] = entry;
    ctx->entriesCount++;
    return index;
}

// Decode unsigned int for position map
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
    int8_t signFill = (int8_t)ctx->input[ctx->position + byteCount - 1] >> 7;
    union number_bits bits = {.u64 = (uint64_t)(int64_t)signFill};
    memcpy(bits.b, ctx->input + ctx->position, byteCount);
    ctx->position += byteCount;
    return (int64_t)fromLittleEndian(bits.u64);
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

// Forward declarations for recursive scanning
static ksbonjson_decodeStatus mapScanValue(KSBONJSONMapContext* ctx, size_t* outIndex);
static ksbonjson_decodeStatus mapScanTypedArray(KSBONJSONMapContext* ctx, uint8_t typeCode, size_t* outIndex);
static ksbonjson_decodeStatus mapScanRecordInstance(KSBONJSONMapContext* ctx, size_t* outIndex);

// Scan a short string (length encoded in type code)
static ksbonjson_decodeStatus mapScanShortString(KSBONJSONMapContext* ctx, uint8_t typeCode, size_t* outIndex)
{
    MAP_SHOULD_HAVE_ENTRY_SPACE();

    // Short string length = typeCode - TYPE_STRING0 (0x65-0xA7 -> length 0-66)
    size_t length = (size_t)(typeCode - TYPE_STRING0);
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

// Scan a long string (0xFF terminated)
static ksbonjson_decodeStatus mapScanLongString(KSBONJSONMapContext* ctx, size_t* outIndex)
{
    MAP_SHOULD_HAVE_ENTRY_SPACE();

    size_t startOffset = ctx->position;

    // SIMD-accelerated scan for 0xFF terminator
    size_t remaining = ctx->inputLength - ctx->position;
    size_t offset = ksbonjson_simd_findByte(ctx->input + ctx->position, remaining, TYPE_STRING_LONG);
    unlikely_if(offset >= remaining)
    {
        return KSBONJSON_DECODE_INCOMPLETE;
    }

    ctx->position += offset;
    size_t length = ctx->position - startOffset;
    ctx->position++; // skip terminator

    // Check max string length (SIZE_MAX means use spec default)
    size_t maxStrLen = ctx->flags.maxStringLength < SIZE_MAX ? ctx->flags.maxStringLength : KSBONJSON_DEFAULT_MAX_STRING_LENGTH;
    unlikely_if(length > maxStrLen)
    {
        return KSBONJSON_DECODE_MAX_STRING_LENGTH_EXCEEDED;
    }

    // Validate string
    if (ctx->flags.rejectInvalidUTF8 || ctx->flags.rejectNUL)
    {
        ksbonjson_decodeStatus status = validateString(ctx->input + startOffset, length,
                                                        ctx->flags.rejectNUL,
                                                        ctx->flags.rejectInvalidUTF8);
        unlikely_if(status != KSBONJSON_DECODE_OK)
        {
            return status;
        }
    }

    KSBONJSONMapEntry entry = {
        .type = KSBONJSON_TYPE_STRING,
        .data.string = {
            .offset = (uint32_t)startOffset,
            .length = (uint32_t)length
        }
    };
    *outIndex = mapAddEntry(ctx, entry);
    return KSBONJSON_DECODE_OK;
}

// Scan an unsigned integer
static ksbonjson_decodeStatus mapScanUnsignedInt(KSBONJSONMapContext* ctx, uint8_t typeCode, size_t* outIndex)
{
    MAP_SHOULD_HAVE_ENTRY_SPACE();

    size_t byteCount = intByteCounts[typeCode & 0x03];
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

    size_t byteCount = intByteCounts[typeCode & 0x03];
    MAP_SHOULD_HAVE_ROOM_FOR_BYTES(byteCount);

    int64_t value = mapDecodeSignedInt(ctx, byteCount);

    KSBONJSONMapEntry entry = {
        .type = KSBONJSON_TYPE_INT,
        .data.intValue = value
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

// Scan a big number (zigzag LEB128 exponent + zigzag LEB128 signed_length + LE magnitude)
static ksbonjson_decodeStatus mapScanBigNumber(KSBONJSONMapContext* ctx, size_t* outIndex)
{
    MAP_SHOULD_HAVE_ENTRY_SPACE();

    size_t available = ctx->inputLength - ctx->position;

    int64_t exponent;
    size_t bytesRead = ksbonjson_readZigzagLEB128(ctx->input + ctx->position, available, &exponent);
    unlikely_if(bytesRead == 0)
    {
        return KSBONJSON_DECODE_INCOMPLETE;
    }
    ctx->position += bytesRead;
    available -= bytesRead;

    int64_t signedLength;
    bytesRead = ksbonjson_readZigzagLEB128(ctx->input + ctx->position, available, &signedLength);
    unlikely_if(bytesRead == 0)
    {
        return KSBONJSON_DECODE_INCOMPLETE;
    }
    ctx->position += bytesRead;
    available -= bytesRead;

    int32_t sign = 0;
    uint8_t significand[16] = {0};

    if (signedLength != 0)
    {
        sign = signedLength < 0 ? -1 : 0;
        size_t byteCount = (size_t)(signedLength < 0 ? -signedLength : signedLength);

        unlikely_if(byteCount > available)
        {
            return KSBONJSON_DECODE_INCOMPLETE;
        }

        unlikely_if(byteCount > 16)
        {
            return KSBONJSON_DECODE_VALUE_OUT_OF_RANGE;
        }

        // Validate normalization: last byte (most significant) must be non-zero
        unlikely_if(ctx->input[ctx->position + byteCount - 1] == 0)
        {
            return KSBONJSON_DECODE_INVALID_DATA;
        }

        // Copy LE magnitude bytes directly to the array
        memcpy(significand, ctx->input + ctx->position, byteCount);
        ctx->position += byteCount;
    }

    KSBONJSONMapEntry entry = {
        .type = KSBONJSON_TYPE_BIGNUMBER,
        .data.bigNumber = {
            .significand = {significand[0], significand[1], significand[2], significand[3],
                           significand[4], significand[5], significand[6], significand[7],
                           significand[8], significand[9], significand[10], significand[11],
                           significand[12], significand[13], significand[14], significand[15]},
            .exponent = (int32_t)exponent,
            .sign = sign
        }
    };
    *outIndex = mapAddEntry(ctx, entry);
    return KSBONJSON_DECODE_OK;
}

// Scan an array container (delimiter-terminated)
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

    // Read values until TYPE_END encountered
    while (true)
    {
        MAP_SHOULD_HAVE_ROOM_FOR_BYTES(1);
        if (ctx->input[ctx->position] == TYPE_END)
        {
            ctx->position++; // consume end marker
            break;
        }

        size_t childIndex;
        ksbonjson_decodeStatus status = mapScanValue(ctx, &childIndex);
        unlikely_if(status != KSBONJSON_DECODE_OK) return status;
        totalCount++;

        unlikely_if(totalCount > maxContSize)
        {
            return KSBONJSON_DECODE_MAX_CONTAINER_SIZE_EXCEEDED;
        }
    }

    // Update the array entry with child info and subtree size
    ctx->entries[arrayIndex].data.container.firstChild = (uint32_t)firstChild;
    ctx->entries[arrayIndex].data.container.count = totalCount;
    ctx->entries[arrayIndex].subtreeSize = (uint32_t)(ctx->entriesCount - arrayIndex);

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

    // Short string: 0x65-0xA7 (range-based detection)
    if (typeCode >= TYPE_STRING0 && typeCode <= TYPE_SHORT_STRING_MAX)
    {
        return mapScanShortString(ctx, typeCode, outIndex);
    }
    // Long string: 0xFF
    if (typeCode == TYPE_STRING_LONG)
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

// Scan an object container (delimiter-terminated)
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

    // Read key-value pairs until TYPE_END encountered
    while (true)
    {
        MAP_SHOULD_HAVE_ROOM_FOR_BYTES(1);
        if (ctx->input[ctx->position] == TYPE_END)
        {
            ctx->position++; // consume end marker
            break;
        }

        // Scan key (must be string)
        size_t keyIndex;
        ksbonjson_decodeStatus status = mapScanObjectName(ctx, &keyIndex);
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

    // Update the object entry with child info and subtree size
    ctx->entries[objectIndex].data.container.firstChild = (uint32_t)firstChild;
    ctx->entries[objectIndex].data.container.count = entryCount;
    ctx->entries[objectIndex].subtreeSize = (uint32_t)(ctx->entriesCount - objectIndex);

    // Pop container
    ctx->containerDepth--;

    *outIndex = objectIndex;
    return KSBONJSON_DECODE_OK;
}

// Element size lookup for typed arrays, indexed by (TYPE_TYPED_UINT8 - typeCode)
static const size_t typedArrayElementSizes[] = {
    1, 2, 4, 8, 1, 2, 4, 8, 4, 8
    // uint8, uint16, uint32, uint64, sint8, sint16, sint32, sint64, float32, float64
};

// Whether element is signed, indexed by (TYPE_TYPED_UINT8 - typeCode)
// 0=unsigned, 1=signed, 2=float
static const int typedArrayElementKinds[] = {
    0, 0, 0, 0, 1, 1, 1, 1, 2, 2
    // uint8, uint16, uint32, uint64, sint8, sint16, sint32, sint64, float32, float64
};

// Scan a typed array (0xF5-0xFE): expands to regular ARRAY + element entries
static ksbonjson_decodeStatus mapScanTypedArray(KSBONJSONMapContext* ctx, uint8_t typeCode, size_t* outIndex)
{
    MAP_SHOULD_HAVE_ENTRY_SPACE();

    size_t tableIndex = (size_t)(TYPE_TYPED_UINT8 - typeCode);
    size_t elementSize = typedArrayElementSizes[tableIndex];
    int elementKind = typedArrayElementKinds[tableIndex];

    // Read ULEB128 element count
    size_t available = ctx->inputLength - ctx->position;
    uint64_t count64;
    size_t bytesRead = ksbonjson_readULEB128(ctx->input + ctx->position, available, &count64);
    unlikely_if(bytesRead == 0)
    {
        return KSBONJSON_DECODE_INCOMPLETE;
    }
    ctx->position += bytesRead;

    // Check container size limit
    size_t maxContSize = ctx->flags.maxContainerSize < SIZE_MAX ? ctx->flags.maxContainerSize : KSBONJSON_DEFAULT_MAX_CONTAINER_SIZE;
    unlikely_if(count64 > maxContSize)
    {
        return KSBONJSON_DECODE_MAX_CONTAINER_SIZE_EXCEEDED;
    }
    uint32_t count = (uint32_t)count64;

    // Validate that we have enough bytes
    size_t dataBytes = (size_t)count * elementSize;
    MAP_SHOULD_HAVE_ROOM_FOR_BYTES(dataBytes);

    // Check that we have enough entry space (1 for array + count for elements)
    unlikely_if(ctx->entriesCount + 1 + count > ctx->entriesCapacity)
    {
        return KSBONJSON_DECODE_MAP_FULL;
    }

    // Reserve slot for array entry
    size_t arrayIndex = ctx->entriesCount;
    ctx->entries[arrayIndex] = (KSBONJSONMapEntry){
        .type = KSBONJSON_TYPE_ARRAY,
        .data.container = { .firstChild = 0, .count = 0 }
    };
    ctx->entriesCount++;

    size_t firstChild = ctx->entriesCount;

    // Read elements and create individual entries
    for (uint32_t i = 0; i < count; i++)
    {
        KSBONJSONMapEntry entry;
        union number_bits bits = {.u64 = 0};
        memcpy(bits.b, ctx->input + ctx->position, elementSize);
        ctx->position += elementSize;
        bits.u64 = fromLittleEndian(bits.u64);

        switch (elementKind)
        {
            case 0: // unsigned
            {
                // Mask to element size
                uint64_t mask = elementSize < 8 ? ((uint64_t)1 << (elementSize * 8)) - 1 : UINT64_MAX;
                entry.type = KSBONJSON_TYPE_UINT;
                entry.data.uintValue = bits.u64 & mask;
                break;
            }
            case 1: // signed
            {
                // Sign-extend from element size
                int64_t signFill = (int64_t)((int8_t)(ctx->input[ctx->position - 1])) >> 7;
                union number_bits sbits = {.u64 = (uint64_t)signFill};
                memcpy(sbits.b, ctx->input + ctx->position - elementSize, elementSize);
                sbits.u64 = fromLittleEndian(sbits.u64);
                entry.type = KSBONJSON_TYPE_INT;
                entry.data.intValue = sbits.i64;
                break;
            }
            case 2: // float
            {
                entry.type = KSBONJSON_TYPE_FLOAT;
                if (elementSize == 4)
                {
                    entry.data.floatValue = (double)bits.f32;
                }
                else
                {
                    entry.data.floatValue = bits.f64;
                }
                break;
            }
        }

        entry.subtreeSize = 1;
        ctx->entries[ctx->entriesCount] = entry;
        ctx->entriesCount++;
    }

    // Update array entry
    ctx->entries[arrayIndex].data.container.firstChild = (uint32_t)firstChild;
    ctx->entries[arrayIndex].data.container.count = count;
    ctx->entries[arrayIndex].subtreeSize = (uint32_t)(ctx->entriesCount - arrayIndex);

    *outIndex = arrayIndex;
    return KSBONJSON_DECODE_OK;
}

// Scan a record definition (0xB9): store key strings for later use by record instances
static ksbonjson_decodeStatus mapScanRecordDef(KSBONJSONMapContext* ctx)
{
    unlikely_if(ctx->recordDefCount >= KSBONJSON_MAX_RECORD_DEFS)
    {
        return KSBONJSON_DECODE_INVALID_DATA;
    }

    size_t firstKeyIndex = ctx->entriesCount;
    uint32_t keyCount = 0;
    bool checkDuplicates = ctx->flags.rejectDuplicateKeys;
    size_t maxContSize = ctx->flags.maxContainerSize < SIZE_MAX ? ctx->flags.maxContainerSize : KSBONJSON_DEFAULT_MAX_CONTAINER_SIZE;

    // Track key indices for duplicate detection within this definition
    size_t keyIndices[MAX_TRACKED_KEYS];

    // Read key strings until TYPE_END
    while (true)
    {
        MAP_SHOULD_HAVE_ROOM_FOR_BYTES(1);
        if (ctx->input[ctx->position] == TYPE_END)
        {
            ctx->position++; // consume end marker
            break;
        }

        size_t keyIndex;
        ksbonjson_decodeStatus status = mapScanObjectName(ctx, &keyIndex);
        unlikely_if(status != KSBONJSON_DECODE_OK) return status;

        if (checkDuplicates)
        {
            unlikely_if(keyCount >= MAX_TRACKED_KEYS)
            {
                return KSBONJSON_DECODE_TOO_MANY_KEYS;
            }
            const KSBONJSONMapEntry* newKey = &ctx->entries[keyIndex];
            for (size_t j = 0; j < keyCount; j++)
            {
                const KSBONJSONMapEntry* existingKey = &ctx->entries[keyIndices[j]];
                unlikely_if(stringsEqual(ctx, newKey, existingKey))
                {
                    return KSBONJSON_DECODE_DUPLICATE_OBJECT_NAME;
                }
            }
            keyIndices[keyCount] = keyIndex;
        }

        keyCount++;
        unlikely_if(keyCount > maxContSize)
        {
            return KSBONJSON_DECODE_MAX_CONTAINER_SIZE_EXCEEDED;
        }
    }

    // Store definition
    ctx->recordDefs[ctx->recordDefCount].firstKeyIndex = firstKeyIndex;
    ctx->recordDefs[ctx->recordDefCount].keyCount = keyCount;
    ctx->recordDefCount++;

    return KSBONJSON_DECODE_OK;
}

// Scan a record instance (0xBA): expands to regular OBJECT entry
static ksbonjson_decodeStatus mapScanRecordInstance(KSBONJSONMapContext* ctx, size_t* outIndex)
{
    MAP_SHOULD_HAVE_ENTRY_SPACE();

    // Read ULEB128 definition index
    size_t available = ctx->inputLength - ctx->position;
    uint64_t defIndex64;
    size_t bytesRead = ksbonjson_readULEB128(ctx->input + ctx->position, available, &defIndex64);
    unlikely_if(bytesRead == 0)
    {
        return KSBONJSON_DECODE_INCOMPLETE;
    }
    ctx->position += bytesRead;

    // Validate definition index
    unlikely_if(defIndex64 >= ctx->recordDefCount)
    {
        return KSBONJSON_DECODE_INVALID_DATA;
    }
    size_t defIndex = (size_t)defIndex64;
    KSBONJSONRecordDef* def = &ctx->recordDefs[defIndex];

    // Check max depth
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

    size_t firstChild = ctx->entriesCount;
    uint32_t valueCount = 0;

    // Read values until TYPE_END, interleaving with keys from definition
    while (true)
    {
        MAP_SHOULD_HAVE_ROOM_FOR_BYTES(1);
        if (ctx->input[ctx->position] == TYPE_END)
        {
            ctx->position++; // consume end marker
            break;
        }

        // Cannot have more values than keys
        unlikely_if(valueCount >= def->keyCount)
        {
            return KSBONJSON_DECODE_INVALID_DATA;
        }

        // Check entry space for key + value
        unlikely_if(ctx->entriesCount + 2 > ctx->entriesCapacity)
        {
            return KSBONJSON_DECODE_MAP_FULL;
        }

        // Re-add key from definition (copy the STRING entry)
        size_t defKeyIndex = def->firstKeyIndex + valueCount;
        KSBONJSONMapEntry keyEntry = ctx->entries[defKeyIndex];
        keyEntry.subtreeSize = 1;
        ctx->entries[ctx->entriesCount] = keyEntry;
        ctx->entriesCount++;

        // Scan value
        size_t valueIndex;
        ksbonjson_decodeStatus status = mapScanValue(ctx, &valueIndex);
        unlikely_if(status != KSBONJSON_DECODE_OK) return status;

        valueCount++;
    }

    // Pad remaining keys with NULL values
    for (uint32_t i = valueCount; i < def->keyCount; i++)
    {
        unlikely_if(ctx->entriesCount + 2 > ctx->entriesCapacity)
        {
            return KSBONJSON_DECODE_MAP_FULL;
        }

        // Re-add key from definition
        size_t defKeyIndex = def->firstKeyIndex + i;
        KSBONJSONMapEntry keyEntry = ctx->entries[defKeyIndex];
        keyEntry.subtreeSize = 1;
        ctx->entries[ctx->entriesCount] = keyEntry;
        ctx->entriesCount++;

        // Add NULL value
        KSBONJSONMapEntry nullEntry = { .type = KSBONJSON_TYPE_NULL, .subtreeSize = 1 };
        ctx->entries[ctx->entriesCount] = nullEntry;
        ctx->entriesCount++;
    }

    // entryCount = keys + values = 2 * def->keyCount
    uint32_t entryCount = 2 * def->keyCount;

    // Update the object entry
    ctx->entries[objectIndex].data.container.firstChild = (uint32_t)firstChild;
    ctx->entries[objectIndex].data.container.count = entryCount;
    ctx->entries[objectIndex].subtreeSize = (uint32_t)(ctx->entriesCount - objectIndex);

    *outIndex = objectIndex;
    return KSBONJSON_DECODE_OK;
}

// Main value scanner
static ksbonjson_decodeStatus mapScanValue(KSBONJSONMapContext* ctx, size_t* outIndex)
{
    MAP_SHOULD_HAVE_ROOM_FOR_BYTES(1);
    uint8_t typeCode = ctx->input[ctx->position++];

    // Small integers: 0x00-0x64 (most common case)
    if (typeCode <= TYPE_SMALLINT_MAX)
    {
        MAP_SHOULD_HAVE_ENTRY_SPACE();
        KSBONJSONMapEntry entry = {
            .type = KSBONJSON_TYPE_INT,
            .data.intValue = (int64_t)typeCode
        };
        *outIndex = mapAddEntry(ctx, entry);
        return KSBONJSON_DECODE_OK;
    }

    // Short strings: 0x65-0xA7 (range-based detection)
    if (typeCode >= TYPE_STRING0 && typeCode <= TYPE_SHORT_STRING_MAX)
    {
        return mapScanShortString(ctx, typeCode, outIndex);
    }

    // Unsigned integers: 0xA8-0xAB (mask-based detection)
    if ((typeCode & TYPE_MASK_UINT) == TYPE_UINT_BASE)
    {
        return mapScanUnsignedInt(ctx, typeCode, outIndex);
    }

    // Signed integers: 0xAC-0xAF (mask-based detection)
    if ((typeCode & TYPE_MASK_SINT) == TYPE_SINT_BASE)
    {
        return mapScanSignedInt(ctx, typeCode, outIndex);
    }

    // Typed arrays: 0xF5-0xFE
    if (typeCode >= TYPE_TYPED_FLOAT64 && typeCode <= TYPE_TYPED_UINT8)
    {
        return mapScanTypedArray(ctx, typeCode, outIndex);
    }

    // Remaining types (individual checks)
    switch (typeCode)
    {
        case TYPE_STRING_LONG:
            return mapScanLongString(ctx, outIndex);
        case TYPE_BIG_NUMBER:
            return mapScanBigNumber(ctx, outIndex);
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
        case TYPE_RECORD_INSTANCE:
            return mapScanRecordInstance(ctx, outIndex);
        default:
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
    ctx->recordDefCount = 0;
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

    // Scan record definitions (must appear before root value)
    while (ctx->position < ctx->inputLength && ctx->input[ctx->position] == TYPE_RECORD_DEF)
    {
        ctx->position++; // consume TYPE_RECORD_DEF
        ksbonjson_decodeStatus status = mapScanRecordDef(ctx);
        if (status != KSBONJSON_DECODE_OK)
        {
            return status;
        }
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

// Helper to get the subtree size (precomputed during scan)
static inline size_t mapSubtreeSize(KSBONJSONMapContext* ctx, size_t index)
{
    if (index >= ctx->entriesCount)
    {
        return 0;
    }
    return ctx->entries[index].subtreeSize;
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
            // Convert little-endian bytes to uint64 (using first 8 bytes)
            uint64_t significand = 0;
            for (size_t i = 0; i < 8 && i < KSBONJSON_MAX_BIGNUMBER_MAGNITUDE_BYTES; i++)
            {
                significand |= (uint64_t)entry->data.bigNumber.significand[i] << (i * 8);
            }
            double result = (double)significand * pow(10.0, (double)entry->data.bigNumber.exponent);
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
