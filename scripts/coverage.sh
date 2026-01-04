#!/bin/bash
# ABOUTME: Script to run tests with code coverage and generate detailed reports.
# ABOUTME: Outputs coverage data in an easily parseable format.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_DIR"

# Clean previous coverage data
rm -rf .build/debug/codecov/

echo "=== Running tests with coverage ==="
swift test --enable-code-coverage 2>&1 | grep -E "Executed|passed|failed" | tail -5

# Check if coverage data was generated
if [ ! -f .build/debug/codecov/default.profdata ]; then
    echo "ERROR: Coverage data not generated. Tests may have crashed."
    exit 1
fi

PROFDATA=".build/debug/codecov/default.profdata"
TEST_BINARY=".build/debug/BONJSONPackageTests.xctest/Contents/MacOS/BONJSONPackageTests"

echo ""
echo "=== COVERAGE SUMMARY ==="
xcrun llvm-cov report "$TEST_BINARY" \
    -instr-profile="$PROFDATA" \
    -ignore-filename-regex='Tests/|.build/'

echo ""
echo "=== UNCOVERED LINES BY FILE ==="

# For each source file, show uncovered line numbers
for file in Sources/BONJSON/*.swift; do
    filename=$(basename "$file")
    echo ""
    echo "--- $filename ---"

    # Get line-by-line coverage, extract uncovered lines (count = 0)
    # The format is: "   LINE|  COUNT|CODE" where COUNT=0 means uncovered
    xcrun llvm-cov show "$TEST_BINARY" \
        -instr-profile="$PROFDATA" \
        -show-line-counts-or-regions \
        "$file" 2>/dev/null | \
    grep -E '^\s*[0-9]+\|\s*0\|' | \
    while IFS='|' read -r linenum count code; do
        # Trim whitespace
        linenum=$(echo "$linenum" | tr -d ' ')
        code=$(echo "$code" | sed 's/^[[:space:]]*//' | cut -c1-80)
        # Skip empty lines and lines with just braces
        if [ -n "$code" ] && [ "$code" != "{" ] && [ "$code" != "}" ] && [ "$code" != "})" ]; then
            printf "  %4s: %s\n" "$linenum" "$code"
        fi
    done
done

echo ""
echo "=== COVERAGE COMPLETE ==="
