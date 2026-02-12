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
// ABOUTME: Phase 3 type codes with typed arrays and records.

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
// Type codes (Phase 3: typed arrays and records)
// ============================================================================
//
// Layout:
//   0x00-0x64: Small integers (0 to 100), value = type_code
//   0x65-0xA7: Short strings (0-66 bytes, length = type_code - 0x65)
//   0xA8-0xAB: Unsigned integers (1, 2, 4, 8 bytes)
//   0xAC-0xAF: Signed integers (1, 2, 4, 8 bytes)
//   0xB0:      float32 (IEEE 754 binary32, little-endian)
//   0xB1:      float64 (IEEE 754 binary64, little-endian)
//   0xB2:      BigNumber (zigzag LEB128 exponent + significand)
//   0xB3:      null
//   0xB4:      false
//   0xB5:      true
//   0xB6:      Container end
//   0xB7:      Array start
//   0xB8:      Object start
//   0xB9:      Record definition
//   0xBA:      Record instance
//   0xBB-0xF4: RESERVED
//   0xF5:      Typed array float64
//   0xF6:      Typed array float32
//   0xF7:      Typed array sint64
//   0xF8:      Typed array sint32
//   0xF9:      Typed array sint16
//   0xFA:      Typed array sint8
//   0xFB:      Typed array uint64
//   0xFC:      Typed array uint32
//   0xFD:      Typed array uint16
//   0xFE:      Typed array uint8
//   0xFF:      Long string start / string terminator

enum
{
    // Small integers: 0x00-0x64 encode values 0 to 100
    // value = type_code directly (no bias)
    TYPE_SMALLINT_MAX  = 0x64,  // 100

    // Short strings (0-66 bytes), length = type_code - TYPE_STRING0
    TYPE_STRING0         = 0x65,
    TYPE_SHORT_STRING_MAX = 0xA7,

    // Unsigned integers: CPU-native sizes (1, 2, 4, 8 bytes)
    TYPE_UINT8  = 0xA8,
    TYPE_UINT16 = 0xA9,
    TYPE_UINT32 = 0xAA,
    TYPE_UINT64 = 0xAB,

    // Signed integers: CPU-native sizes (1, 2, 4, 8 bytes)
    TYPE_SINT8  = 0xAC,
    TYPE_SINT16 = 0xAD,
    TYPE_SINT32 = 0xAE,
    TYPE_SINT64 = 0xAF,

    // Floats (float32 and float64 only)
    TYPE_FLOAT32 = 0xB0,
    TYPE_FLOAT64 = 0xB1,

    // Big number (zigzag LEB128 exponent + zigzag LEB128 signed_length + LE magnitude)
    TYPE_BIG_NUMBER = 0xB2,

    // Null
    TYPE_NULL = 0xB3,

    // Booleans
    TYPE_FALSE = 0xB4,
    TYPE_TRUE  = 0xB5,

    // Container end marker
    TYPE_END = 0xB6,

    // Containers (delimiter-terminated with TYPE_END)
    TYPE_ARRAY  = 0xB7,
    TYPE_OBJECT = 0xB8,

    // Records
    TYPE_RECORD_DEF      = 0xB9,
    TYPE_RECORD_INSTANCE = 0xBA,

    // Typed arrays: type_code + ULEB128(count) + raw LE element data
    TYPE_TYPED_FLOAT64 = 0xF5,
    TYPE_TYPED_FLOAT32 = 0xF6,
    TYPE_TYPED_SINT64  = 0xF7,
    TYPE_TYPED_SINT32  = 0xF8,
    TYPE_TYPED_SINT16  = 0xF9,
    TYPE_TYPED_SINT8   = 0xFA,
    TYPE_TYPED_UINT64  = 0xFB,
    TYPE_TYPED_UINT32  = 0xFC,
    TYPE_TYPED_UINT16  = 0xFD,
    TYPE_TYPED_UINT8   = 0xFE,

    // Long string: FF + data + FF (0xFF is both start and terminator)
    TYPE_STRING_LONG = 0xFF,
};

enum
{
    SMALLINT_MIN = 0,
    SMALLINT_MAX = 100,
};

// Masks and bases for efficient type detection
enum
{
    // Unsigned integers: 0xA8-0xAB
    TYPE_MASK_UINT = 0xFC,
    TYPE_UINT_BASE = 0xA8,

    // Signed integers: 0xAC-0xAF
    TYPE_MASK_SINT = 0xFC,
    TYPE_SINT_BASE = 0xAC,
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

// Write unsigned LEB128 to buffer. Returns number of bytes written.
// Caller must ensure buf has at least 10 bytes available.
static inline size_t ksbonjson_writeULEB128(uint8_t *buf, uint64_t value)
{
    size_t i = 0;
    do {
        uint8_t byte = (uint8_t)(value & 0x7F);
        value >>= 7;
        if (value != 0) byte |= 0x80;
        buf[i++] = byte;
    } while (value != 0);
    return i;
}

// Read unsigned LEB128 from buffer. Returns number of bytes consumed, or 0 on error.
static inline size_t ksbonjson_readULEB128(const uint8_t *buf, size_t available, uint64_t *out)
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
            *out = result;
            return i;
        }
    } while (shift < 64);
    return 0; // overflow
}


#ifdef __cplusplus
}
#endif

#endif // KSBONJSONCommon_h
