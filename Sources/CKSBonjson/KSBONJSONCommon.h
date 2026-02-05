//
//  KSBONJSONCommon.h
//
//  Created by Karl Stenerud on 2025-03-15.
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

// ABOUTME: Shared constants, macros, and type codes for BONJSON codec.
// ABOUTME: Phase 2 type codes with delimiter-terminated format.

#ifndef KSBONJSONCommon_h
#define KSBONJSONCommon_h

#include <stdint.h>
#include <stddef.h>
#include <string.h>

#ifdef __cplusplus
extern "C" {
#endif


// ============================================================================
// Helpers
// ============================================================================

#ifndef KSBONJSON_IS_LITTLE_ENDIAN
#   ifdef __BYTE_ORDER__
#       if __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
#           define KSBONJSON_IS_LITTLE_ENDIAN 1
#       elif __BYTE_ORDER__ == __ORDER_BIG_ENDIAN__
#           define KSBONJSON_IS_LITTLE_ENDIAN 0
#       else
#           error Cannot detect endianness
#       endif
#   elif defined(__i386__) || defined(__x86_64__) || defined(_M_IX86) || defined(_M_X64) || defined(__aarch64__) || defined(_M_ARM64)
#       define KSBONJSON_IS_LITTLE_ENDIAN 1
#   else
#       error Cannot detect endianness
#   endif
#endif

#ifndef HAS_BUILTIN
#   ifdef _MSC_VER
#       define HAS_BUILTIN(A) 0
#   else
#       define HAS_BUILTIN(A) __has_builtin(A)
#   endif
#endif

// Compiler hints for "if" statements
#ifndef likely_if
#   pragma GCC diagnostic push
#   pragma GCC diagnostic ignored "-Wunused-macros"
#   if HAS_BUILTIN(__builtin_expect)
#       define likely_if(x) if(__builtin_expect(x,1))
#       define unlikely_if(x) if(__builtin_expect(x,0))
#   else
#       define likely_if(x) if(x)
#       define unlikely_if(x) if(x)
#   endif
#   pragma GCC diagnostic pop
#endif


// ============================================================================
// Type codes (Phase 2: delimiter-terminated format)
// ============================================================================
//
// Layout:
//   0x00-0xC8: Small integers (-100 to 100), value = type_code - 100
//   0xC9:      RESERVED
//   0xCA:      BigNumber (zigzag LEB128 exponent + significand)
//   0xCB:      float32 (IEEE 754 binary32, little-endian)
//   0xCC:      float64 (IEEE 754 binary64, little-endian)
//   0xCD:      null
//   0xCE:      false
//   0xCF:      true
//   0xD0-0xDF: Short strings (0-15 bytes, length = type_code & 0x0F)
//   0xE0-0xE3: Unsigned integers (1, 2, 4, 8 bytes)
//   0xE4-0xE7: Signed integers (1, 2, 4, 8 bytes)
//   0xE8-0xFB: RESERVED
//   0xFC:      Array start
//   0xFD:      Object start
//   0xFE:      Container end
//   0xFF:      Long string start / string terminator

enum
{
    // Small integers: 0x00-0xC8 encode values -100 to 100
    // value = type_code - 100, so type_code = value + 100
    TYPE_SMALLINT_MIN  = 0x00,  // -100
    TYPE_SMALLINT_ZERO = 0x64,  // 0
    TYPE_SMALLINT_MAX  = 0xC8,  // 100

    // Big number (zigzag LEB128 exponent + zigzag LEB128 signed_length + LE magnitude)
    TYPE_BIG_NUMBER = 0xCA,

    // Floats (float32 and float64 only)
    TYPE_FLOAT32 = 0xCB,
    TYPE_FLOAT64 = 0xCC,

    // Null
    TYPE_NULL = 0xCD,

    // Booleans
    TYPE_FALSE = 0xCE,
    TYPE_TRUE  = 0xCF,

    // Short strings (0-15 bytes), lower nibble = length
    TYPE_STRING0  = 0xD0,
    TYPE_STRING1  = 0xD1,
    TYPE_STRING2  = 0xD2,
    TYPE_STRING3  = 0xD3,
    TYPE_STRING4  = 0xD4,
    TYPE_STRING5  = 0xD5,
    TYPE_STRING6  = 0xD6,
    TYPE_STRING7  = 0xD7,
    TYPE_STRING8  = 0xD8,
    TYPE_STRING9  = 0xD9,
    TYPE_STRING10 = 0xDA,
    TYPE_STRING11 = 0xDB,
    TYPE_STRING12 = 0xDC,
    TYPE_STRING13 = 0xDD,
    TYPE_STRING14 = 0xDE,
    TYPE_STRING15 = 0xDF,

    // Unsigned integers: CPU-native sizes (1, 2, 4, 8 bytes)
    TYPE_UINT8  = 0xE0,
    TYPE_UINT16 = 0xE1,
    TYPE_UINT32 = 0xE2,
    TYPE_UINT64 = 0xE3,

    // Signed integers: CPU-native sizes (1, 2, 4, 8 bytes)
    TYPE_SINT8  = 0xE4,
    TYPE_SINT16 = 0xE5,
    TYPE_SINT32 = 0xE6,
    TYPE_SINT64 = 0xE7,

    // Containers (delimiter-terminated with TYPE_END)
    TYPE_ARRAY  = 0xFC,
    TYPE_OBJECT = 0xFD,
    TYPE_END    = 0xFE,

    // Long string: FF + data + FF (0xFF is both start and terminator)
    TYPE_STRING_LONG = 0xFF,
};

enum
{
    SMALLINT_MIN = -100,
    SMALLINT_MAX = 100,
    SMALLINT_BIAS = 100,  // type_code = value + SMALLINT_BIAS
};

// Masks and bases for efficient type detection
enum
{
    // Short strings: 0xD0-0xDF (lower nibble = length)
    TYPE_MASK_SHORT_STRING = 0xF0,
    TYPE_SHORT_STRING_BASE = 0xD0,

    // Unsigned integers: 0xE0-0xE3
    TYPE_MASK_UINT = 0xFC,
    TYPE_UINT_BASE = 0xE0,

    // Signed integers: 0xE4-0xE7
    TYPE_MASK_SINT = 0xFC,
    TYPE_SINT_BASE = 0xE4,
};


// ============================================================================
// Endianness helpers
// ============================================================================

static inline uint64_t ksbonjson_toLittleEndian(uint64_t v)
{
#if KSBONJSON_IS_LITTLE_ENDIAN
    return v;
#else
    return __builtin_bswap64(v);
#endif
}

static inline uint64_t ksbonjson_fromLittleEndian(uint64_t v)
{
    return ksbonjson_toLittleEndian(v); // same operation
}


// ============================================================================
// Bit counting helpers
// ============================================================================

// Count leading zero bits (min result 0, max 63; value=0 returns 63)
static inline size_t ksbonjson_clz64Max63(uint64_t value)
{
    value |= 1;
#if HAS_BUILTIN(__builtin_clzll)
    return (size_t)__builtin_clzll(value);
#else
    value |= value >> 1;  value |= value >> 2;
    value |= value >> 4;  value |= value >> 8;
    value |= value >> 16; value |= value >> 32;
    value = ~value;
    value &= -(int64_t)value;
    union { float f; uint32_t u; } conv = { .f = (float)value };
    uint64_t bits = ((conv.u >> 23) - 0x7f) & 0xff;
    bits = ((bits & 0x7f) ^ (bits >> 7)) | ((bits & 0x80) >> 1);
    return 64 - bits;
#endif
}

// Minimum bytes needed to store an unsigned value (min 1)
static inline size_t ksbonjson_uintBytesMin1(uint64_t value)
{
    return (63 - ksbonjson_clz64Max63(value)) / 8 + 1;
}

// Minimum bytes needed to store a signed value (min 1)
static inline size_t ksbonjson_sintBytesMin1(int64_t value)
{
#if HAS_BUILTIN(__builtin_clrsbll)
    return (63 - (size_t)__builtin_clrsbll(value | 1)) / 8 + 1;
#else
    int64_t mask = value >> 63;
    uint64_t abs_val = (uint64_t)((value + mask) ^ mask);
    size_t lz = ksbonjson_clz64Max63(abs_val);
    size_t bytes_to_remove = lz / 8;
    int64_t shifted = value << (bytes_to_remove * 8);
    size_t sign_changed = ((value ^ shifted) >> 63) & 1;
    return 8 - bytes_to_remove + sign_changed;
#endif
}

// Round byte count up to next CPU-native size (1, 2, 4, 8)
static const size_t ksbonjson_nativeSizeTable[] = {
    0, 1, 2, 4, 4, 8, 8, 8, 8
};

static inline size_t ksbonjson_roundToNativeSize(size_t bytes)
{
    return ksbonjson_nativeSizeTable[bytes];
}

// Table mapping native byte count to type code index: 1->0, 2->1, 4->2, 8->3
static const uint8_t ksbonjson_nativeSizeIndex[] = {
    0, 0, 1, 0, 2, 0, 0, 0, 3
};


// ============================================================================
// Zigzag + LEB128 encoding for bignum fields
// ============================================================================

// Zigzag encode: 0→0, -1→1, 1→2, -2→3, 2→4, ...
static inline uint64_t ksbonjson_zigzagEncode(int64_t v)
{
    return (uint64_t)((v << 1) ^ (v >> 63));
}

// Zigzag decode: 0→0, 1→-1, 2→1, 3→-2, 4→2, ...
static inline int64_t ksbonjson_zigzagDecode(uint64_t v)
{
    return (int64_t)((v >> 1) ^ -(int64_t)(v & 1));
}

// Write zigzag LEB128 to buffer. Returns number of bytes written.
// Caller must ensure buf has at least 10 bytes available.
static inline size_t ksbonjson_writeZigzagLEB128(uint8_t *buf, int64_t value)
{
    uint64_t v = ksbonjson_zigzagEncode(value);
    size_t i = 0;
    do {
        uint8_t byte = (uint8_t)(v & 0x7F);
        v >>= 7;
        if (v != 0) byte |= 0x80;
        buf[i++] = byte;
    } while (v != 0);
    return i;
}

// Read zigzag LEB128 from buffer. Returns number of bytes consumed, or 0 on error.
static inline size_t ksbonjson_readZigzagLEB128(const uint8_t *buf, size_t available, int64_t *out)
{
    uint64_t result = 0;
    size_t shift = 0;
    size_t i = 0;
    do {
        if (i >= available) return 0;
        uint8_t byte = buf[i];
        result |= (uint64_t)(byte & 0x7F) << shift;
        shift += 7;
        i++;
        if (!(byte & 0x80)) {
            *out = ksbonjson_zigzagDecode(result);
            return i;
        }
    } while (shift < 64);
    return 0; // overflow
}


#ifdef __cplusplus
}
#endif

#endif // KSBONJSONCommon_h
