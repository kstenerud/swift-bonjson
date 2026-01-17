#!/bin/bash
# ABOUTME: Runs the BONJSON vs JSON benchmark comparison with release optimizations.

set -e

cd "$(dirname "$0")"

echo "Building benchmark in release mode..."
swift build -c release --product bonjson-benchmark 2>&1 | grep -v "^Build complete" || true

echo ""
swift run -c release bonjson-benchmark
