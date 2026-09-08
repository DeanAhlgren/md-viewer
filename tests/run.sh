#!/bin/zsh
set -eu
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/mdviewer-tests.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT
MDVIEWER_REGISTER=0 MDVIEWER_APP_PATH="$test_dir/MD Viewer.app" ./build.sh
clang -fobjc-arc -Wall -Wextra -Wno-unused-parameter tests/editor_tests.m \
  -o "$test_dir/MD Viewer.app/Contents/MacOS/editor_tests" \
  -framework Cocoa -framework WebKit -framework UniformTypeIdentifiers
"$test_dir/MD Viewer.app/Contents/MacOS/editor_tests"
