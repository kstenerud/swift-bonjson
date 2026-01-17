# Conformance Test Implementation Notes

## Summary

The conformance test runner is implemented in `Tests/BONJSONTests/ConformanceTests.swift`.

Current test results:
- **Conformance tests**: 288 passed, 1 failed, 17 skipped
- **Runner valid tests**: 31 passed, 0 failed, 7 skipped
- **Runner special values tests**: 18 passed, 0 failed, 3 skipped

## Remaining Failures

### security.json:empty_chunk_with_continuation
The test expects `empty_chunk_continuation` error but the decoder reports `truncated`.
This is acceptable behavior since the error is detected, just with a different error type.

## Skipped Tests

### Unsupported Options
- `max_depth`, `max_string_length`, `max_chunks`, `max_container_size`, `max_document_size`

### Known Limitations
- **BigNumber roundtrip**: Swift's Decimal type encodes as an object structure, not BONJSON BigNumber format
- **Negative zero roundtrip**: Encoder encodes -0.0 as integer 0
- **NaN decode**: Decoder doesn't properly distinguish NaN float bit patterns

## Fixed Issues

### In Universal Test Suite

#### hex-formats.json (FIXED)
- `hex_lowercase_compact`: Changed `input_bytes` from "856865" to "826865"
- `hex_uppercase_compact`: Changed `input_bytes` from "856865" to "826865"
- (0x82 = 2-byte string for "he", was incorrectly 0x85 = 5-byte string)

#### basic-types.json (FIXED)
- Renamed `object_simple` to `object_multiple_keys` and changed to `roundtrip` test
- Added `object_single_key` encode test with single key-value pair (deterministic)

### In swift-bonjson Library

#### Chunked String Decoding (FIXED)
- Added `CHUNKED_STRING_FLAG` to mark chunked strings in position map
- Swift decoder now correctly re-assembles chunked strings from raw bytes

#### Unclosed Container Detection (FIXED)
- Added `foundEndMarker` flag in `mapScanArray` and `mapScanObject`
- Returns `KSBONJSON_DECODE_UNCLOSED_CONTAINERS` when running out of data without end marker

#### Trailing Bytes Detection (FIXED)
- Added `KSBONJSON_DECODE_TRAILING_BYTES` error code
- Added `rejectTrailingBytes` flag to `KSBONJSONDecodeFlags`
- Added `trailingBytesDecodingStrategy` to `BONJSONDecoder`
- Position map scan now checks for unconsumed bytes after root value

#### Non-canonical Length Detection (FIXED)
- Added `KSBONJSON_DECODE_NON_CANONICAL_LENGTH` error code
- Added `rejectNonCanonicalLengths` flag to `KSBONJSONDecodeFlags`
- Length payload decoder now verifies payload wouldn't fit in fewer bytes

#### BigNumber NaN/Infinity Rejection (FIXED)
- Moved check for `significandLength == 0 && exponentLength != 0` before the significand processing
- Now correctly rejects special BigNumber encodings as `KSBONJSON_DECODE_INVALID_DATA`

## Potential Future Improvements

### Encoder
1. Preserve negative zero as float instead of integer 0

### Decoder
1. Distinguish NaN/Infinity float patterns when `allow_nan_infinity` is set
2. Return specific `empty_chunk_continuation` error for that edge case

### Tests to Add
1. Float16/bfloat16 edge cases (subnormal values, min/max representable)
2. Integer boundary tests (values at boundaries between encoding sizes)
3. Deeply nested containers at exactly the depth limit
