// ABOUTME: Platform-adaptive SIMD primitives for accelerated byte scanning.
// ABOUTME: Provides fast 0xFF search, NUL detection, and ASCII validation.

#ifndef KSBONJSON_SIMD_H
#define KSBONJSON_SIMD_H

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#include <string.h>

// ============================================================================
// Platform Detection
// ============================================================================

#if defined(__aarch64__) || defined(_M_ARM64)
    #define KSBONJSON_SIMD_NEON 1
    #include <arm_neon.h>
    #define KSBONJSON_SIMD_WIDTH 16
#elif defined(__x86_64__) || defined(_M_X64) || defined(__i386__) || defined(_M_IX86)
    #if defined(__SSE2__) || defined(_MSC_VER)
        #define KSBONJSON_SIMD_SSE2 1
        #include <emmintrin.h>
        #define KSBONJSON_SIMD_WIDTH 16
    #endif
#endif

#ifndef KSBONJSON_SIMD_WIDTH
    #define KSBONJSON_SIMD_WIDTH 0
#endif


// ============================================================================
// SIMD Implementations
// ============================================================================

#if KSBONJSON_SIMD_NEON

/**
 * Find the first occurrence of a byte value in a buffer using NEON.
 * Returns the offset from ptr, or len if not found.
 */
static inline size_t ksbonjson_simd_findByte(const uint8_t *ptr, size_t len, uint8_t needle)
{
    size_t i = 0;
    uint8x16_t vneedle = vdupq_n_u8(needle);

    while (i + 16 <= len)
    {
        uint8x16_t data = vld1q_u8(ptr + i);
        uint8x16_t cmp = vceqq_u8(data, vneedle);
        uint8x16_t folded = vpmaxq_u8(cmp, cmp);
        if (vgetq_lane_u64(vreinterpretq_u64_u8(folded), 0) != 0)
        {
            // Found a match in this block — find exact position
            for (size_t j = i; j < i + 16; j++)
            {
                if (ptr[j] == needle) return j;
            }
        }
        i += 16;
    }

    // Scalar tail
    for (; i < len; i++)
    {
        if (ptr[i] == needle) return i;
    }
    return len;
}

/**
 * Check if a buffer contains a specific byte using NEON.
 * Returns true if the byte is found.
 */
static inline bool ksbonjson_simd_containsByte(const uint8_t *ptr, size_t len, uint8_t needle)
{
    size_t i = 0;
    uint8x16_t vneedle = vdupq_n_u8(needle);

    while (i + 16 <= len)
    {
        uint8x16_t data = vld1q_u8(ptr + i);
        uint8x16_t cmp = vceqq_u8(data, vneedle);
        uint8x16_t folded = vpmaxq_u8(cmp, cmp);
        if (vgetq_lane_u64(vreinterpretq_u64_u8(folded), 0) != 0)
        {
            return true;
        }
        i += 16;
    }

    for (; i < len; i++)
    {
        if (ptr[i] == needle) return true;
    }
    return false;
}

/**
 * Check if all bytes in a buffer are ASCII (< 0x80) using NEON.
 * Returns true if all bytes are ASCII.
 */
static inline bool ksbonjson_simd_isAllAscii(const uint8_t *ptr, size_t len)
{
    size_t i = 0;
    uint8x16_t highBit = vdupq_n_u8(0x80);

    while (i + 16 <= len)
    {
        uint8x16_t data = vld1q_u8(ptr + i);
        // Test if any byte has high bit set
        uint8x16_t test = vandq_u8(data, highBit);
        uint8x16_t folded = vpmaxq_u8(test, test);
        if (vgetq_lane_u64(vreinterpretq_u64_u8(folded), 0) != 0)
        {
            return false;
        }
        i += 16;
    }

    for (; i < len; i++)
    {
        if (ptr[i] >= 0x80) return false;
    }
    return true;
}

#elif KSBONJSON_SIMD_SSE2

static inline size_t ksbonjson_simd_findByte(const uint8_t *ptr, size_t len, uint8_t needle)
{
    size_t i = 0;
    __m128i vneedle = _mm_set1_epi8((char)needle);

    while (i + 16 <= len)
    {
        __m128i data = _mm_loadu_si128((const __m128i *)(ptr + i));
        __m128i cmp = _mm_cmpeq_epi8(data, vneedle);
        int mask = _mm_movemask_epi8(cmp);
        if (mask != 0)
        {
            return i + (size_t)__builtin_ctz((unsigned)mask);
        }
        i += 16;
    }

    for (; i < len; i++)
    {
        if (ptr[i] == needle) return i;
    }
    return len;
}

static inline bool ksbonjson_simd_containsByte(const uint8_t *ptr, size_t len, uint8_t needle)
{
    size_t i = 0;
    __m128i vneedle = _mm_set1_epi8((char)needle);

    while (i + 16 <= len)
    {
        __m128i data = _mm_loadu_si128((const __m128i *)(ptr + i));
        __m128i cmp = _mm_cmpeq_epi8(data, vneedle);
        if (_mm_movemask_epi8(cmp) != 0)
        {
            return true;
        }
        i += 16;
    }

    for (; i < len; i++)
    {
        if (ptr[i] == needle) return true;
    }
    return false;
}

static inline bool ksbonjson_simd_isAllAscii(const uint8_t *ptr, size_t len)
{
    size_t i = 0;

    while (i + 16 <= len)
    {
        __m128i data = _mm_loadu_si128((const __m128i *)(ptr + i));
        if (_mm_movemask_epi8(data) != 0)
        {
            return false;
        }
        i += 16;
    }

    for (; i < len; i++)
    {
        if (ptr[i] >= 0x80) return false;
    }
    return true;
}

#else

// Scalar fallbacks using word-at-a-time tricks

static inline size_t ksbonjson_simd_findByte(const uint8_t *ptr, size_t len, uint8_t needle)
{
    return (size_t)(memchr(ptr, needle, len) ? (const uint8_t*)memchr(ptr, needle, len) - ptr : len);
}

static inline bool ksbonjson_simd_containsByte(const uint8_t *ptr, size_t len, uint8_t needle)
{
    return memchr(ptr, needle, len) != NULL;
}

static inline bool ksbonjson_simd_isAllAscii(const uint8_t *ptr, size_t len)
{
    for (size_t i = 0; i < len; i++)
    {
        if (ptr[i] >= 0x80) return false;
    }
    return true;
}

#endif

#endif // KSBONJSON_SIMD_H
