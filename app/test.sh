#!/bin/zsh
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$PROJECT_DIR/.build/tests"
DEFAULT_SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
COMPATIBLE_SDK_PATH="/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk"
if [[ -d "$COMPATIBLE_SDK_PATH" ]]; then
  SDK_PATH="$COMPATIBLE_SDK_PATH"
else
  SDK_PATH="$DEFAULT_SDK_PATH"
fi

mkdir -p "$BUILD_DIR"
swiftc \
  -sdk "$SDK_PATH" \
  -target "$(uname -m)-apple-macosx15.0" \
  -module-cache-path "$BUILD_DIR/module-cache" \
  -Xcc -fmodules-cache-path="$BUILD_DIR/clang-module-cache" \
  -parse-as-library \
  "$PROJECT_DIR/Sources/TranslationCore.swift" \
  "$PROJECT_DIR/Tests/TranslationCoreTests.swift" \
  -o "$BUILD_DIR/TranslationCoreTests"

"$BUILD_DIR/TranslationCoreTests"
