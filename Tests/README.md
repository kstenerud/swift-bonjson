# Swift BONJSON Tests

This directory contains Swift-specific unit tests for the BONJSON library.

## Universal BONJSON Conformance Tests

In addition to Swift-specific tests, this library runs the **universal BONJSON conformance test suite** located at `../bonjson/tests/` (will eventually be vendored as a submodule).

The universal test suite contains:

### `conformance/`
The main conformance tests that verify correct BONJSON encoding/decoding behavior. These test files cover:
- Basic types (null, boolean, empty containers)
- Integers (all sizes, boundaries)
- Floats (32/64-bit, special values)
- Strings (short, long, UTF-8)
- BigNumbers (arbitrary precision)
- Containers (arrays, objects, nesting)
- Error handling (truncation, invalid data)
- Security (duplicate keys, invalid UTF-8, NUL characters)

### `runner/`
**Important:** This directory contains tests to validate the **test runner itself**. Before implementing or modifying the conformance test runner, review these tests to ensure correct behavior:

- `valid/` - Test files the runner should process successfully
- `structural-errors/` - Files that should cause the runner to exit with errors
- `skip-scenarios/` - Tests that should be skipped with warnings
- `config/` - Config file processing tests
- `special-values/` - Edge cases for value parsing and comparison (NaN, -0.0, etc.)

See `../bonjson/tests/runner/README.md` for complete documentation.

## Running Tests

```bash
swift test                      # Run all tests
swift test --filter Conformance # Run only conformance tests
swift test --filter Benchmark   # Run benchmarks
```
