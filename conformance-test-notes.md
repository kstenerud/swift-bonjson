# Conformance Test Implementation Notes

## Summary

The conformance test runner is implemented in `Tests/BONJSONTests/ConformanceTests.swift`.

## Skipped Tests

### Known Limitations
- **BigNumber roundtrip**: Swift's Decimal type encodes as an object structure, not BONJSON BigNumber format
- **Negative zero roundtrip**: Encoder encodes -0.0 as integer 0
- **NaN decode**: Decoder doesn't properly distinguish NaN float bit patterns
- 21 BigNumber tests that exceed implementation limits (>19 significant digits or exponents outside -128 to 127)
- 3 `nan_infinity: "stringify"` tests (would require converting float NaN/Infinity to strings)

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

#### Unclosed Container Detection (FIXED)
- Returns error when running out of data without 0xFE end marker

#### Trailing Bytes Detection (FIXED)
- Added `KSBONJSON_DECODE_TRAILING_BYTES` error code
- Added `rejectTrailingBytes` flag to `KSBONJSONDecodeFlags`
- Added `trailingBytesDecodingStrategy` to `BONJSONDecoder`
- Position map scan now checks for unconsumed bytes after root value

## Potential Future Improvements

### Encoder
1. Preserve negative zero as float instead of integer 0

### Decoder
1. Distinguish NaN/Infinity float patterns when `allow_nan_infinity` is set

### Tests to Add
1. Integer boundary tests (values at boundaries between encoding sizes)
2. Deeply nested containers at exactly the depth limit
