#!/bin/zsh
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$PROJECT_DIR/.build"
APP_NAME="中英快译.app"
APP_DIR="$BUILD_DIR/$APP_NAME"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
MODULE_CACHE="$BUILD_DIR/module-cache"
DEFAULT_SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
COMPATIBLE_SDK_PATH="/Library/Developer/CommandLineTools/SDKs/MacOSX15.4.sdk"
if [[ -d "$COMPATIBLE_SDK_PATH" ]]; then
  SDK_PATH="$COMPATIBLE_SDK_PATH"
else
  SDK_PATH="$DEFAULT_SDK_PATH"
fi
ARCHS_VALUE="${ARCHS:-arm64 x86_64}"
ARCHITECTURES=(${=ARCHS_VALUE})
SOURCE_FILES=(
  "$PROJECT_DIR/Sources/Diagnostics.swift"
  "$PROJECT_DIR/Sources/LaunchAtLogin.swift"
  "$PROJECT_DIR/Sources/TranslationCore.swift"
  "$PROJECT_DIR/Sources/TranslationRunner.swift"
  "$PROJECT_DIR/Sources/SelectionCapture.swift"
  "$PROJECT_DIR/Sources/RightClickWatcher.swift"
  "$PROJECT_DIR/Sources/QuickResult.swift"
  "$PROJECT_DIR/Sources/main.swift"
)
ARCH_BINARIES=()

mkdir -p "$MACOS_DIR" "$MODULE_CACHE"
cp "$PROJECT_DIR/Info.plist" "$CONTENTS_DIR/Info.plist"
mkdir -p "$CONTENTS_DIR/Resources"
cp "$PROJECT_DIR/Resources/BilingualTranslator.icns" "$CONTENTS_DIR/Resources/BilingualTranslator.icns"

for architecture in "${ARCHITECTURES[@]}"; do
  output="$BUILD_DIR/BilingualTranslator-$architecture"
  swiftc \
    -sdk "$SDK_PATH" \
    -target "$architecture-apple-macosx15.0" \
    -module-cache-path "$MODULE_CACHE/$architecture" \
    -Xcc -fmodules-cache-path="$MODULE_CACHE/clang-$architecture" \
    -O \
    -parse-as-library \
    -framework AppKit \
    -framework Carbon \
    -framework ServiceManagement \
    -framework SwiftUI \
    -framework Translation \
    -Xlinker -platform_version \
    -Xlinker macos \
    -Xlinker 15.0 \
    -Xlinker 15.4 \
    "${SOURCE_FILES[@]}" \
    -o "$output"
  ARCH_BINARIES+=("$output")
done

if (( ${#ARCH_BINARIES[@]} == 1 )); then
  cp "${ARCH_BINARIES[1]}" "$MACOS_DIR/BilingualTranslator"
else
  lipo -create "${ARCH_BINARIES[@]}" -output "$MACOS_DIR/BilingualTranslator"
fi

plutil -lint "$CONTENTS_DIR/Info.plist"
# 用固定的自签名证书，让指定要求（DR）绑定证书而非 cdhash，
# 这样重新构建后系统授予的辅助功能等权限不会失效。
SIGN_IDENTITY="${CODESIGN_IDENTITY:-BilingualTranslator Local Code Signing}"
if security find-identity -p codesigning 2>/dev/null | grep -q "$SIGN_IDENTITY"; then
  codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_DIR"
else
  print "警告：未找到签名证书「$SIGN_IDENTITY」，回退到 ad-hoc 签名（权限会在每次构建后失效）。"
  codesign --force --deep --sign - "$APP_DIR"
fi
codesign --verify --deep --strict --verbose=2 "$APP_DIR"
lipo -info "$MACOS_DIR/BilingualTranslator"
print "构建完成：$APP_DIR"
