#!/bin/bash

# Build APK for RustDesk on Linux/WSL
# This script builds native Rust libraries and Flutter APK for Android

set -e

# Colors for output
GREEN='\033[0;32m'
CYAN='\033[0;36m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${CYAN}====================================${NC}"
echo -e "${CYAN}RustDesk APK Builder for Linux/WSL${NC}"
echo -e "${CYAN}====================================${NC}"
echo ""

# Parse arguments
BUILD_MODE=${1:-release}
TARGET=${2:-aarch64}

if [[ "$BUILD_MODE" != "debug" && "$BUILD_MODE" != "release" ]]; then
    echo -e "${RED}ERROR: Build mode must be 'debug' or 'release'${NC}"
    exit 1
fi

echo -e "${YELLOW}Build Mode: $BUILD_MODE${NC}"
echo -e "${YELLOW}Target: $TARGET${NC}"
echo ""

# Set up Android NDK
# Use r28c if available, otherwise r26d
if [ -d "$HOME/android-ndk-r28c" ]; then
    export ANDROID_NDK_HOME="$HOME/android-ndk-r28c"
    echo -e "${GREEN}Using NDK: r28c${NC}"
elif [ -d "$HOME/android-ndk-r26d" ]; then
    export ANDROID_NDK_HOME="$HOME/android-ndk-r26d"
    echo -e "${GREEN}Using NDK: r26d${NC}"
elif [ -d "$HOME/android-ndk" ]; then
    export ANDROID_NDK_HOME="$HOME/android-ndk"
    echo -e "${GREEN}Using NDK: default${NC}"
else
    echo -e "${RED}ERROR: Android NDK not found${NC}"
    echo "Please install NDK to: $HOME/android-ndk-r28c or similar"
    exit 1
fi

export ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-$HOME/android-sdk}"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Android/Sdk}"

echo -e "${YELLOW}NDK Path: $ANDROID_NDK_HOME${NC}"
echo ""

# Get project root
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_ROOT"

echo -e "${GREEN}Project Root: $PROJECT_ROOT${NC}"
echo ""

# Step 1: Build Rust native libraries
echo -e "${CYAN}====================================${NC}"
echo -e "${CYAN}Step 1: Building Rust native libraries${NC}"
echo -e "${CYAN}====================================${NC}"
echo ""

if [[ "$TARGET" == "aarch64" || "$TARGET" == "all" ]]; then
    echo -e "${GREEN}Building for aarch64-linux-android...${NC}"
    cargo build --target aarch64-linux-android --$BUILD_MODE
    if [ $? -ne 0 ]; then
        echo -e "${RED}ERROR: Build failed for aarch64${NC}"
        exit 1
    fi
fi

if [[ "$TARGET" == "armv7" || "$TARGET" == "all" ]]; then
    echo ""
    echo -e "${GREEN}Building for armv7-linux-androideabi...${NC}"
    cargo build --target armv7-linux-androideabi --$BUILD_MODE
    if [ $? -ne 0 ]; then
        echo -e "${RED}ERROR: Build failed for armv7${NC}"
        exit 1
    fi
fi

# Step 2: Build Flutter APK
echo ""
echo -e "${CYAN}====================================${NC}"
echo -e "${CYAN}Step 2: Building Flutter APK${NC}"
echo -e "${CYAN}====================================${NC}"
echo ""

cd "$PROJECT_ROOT/flutter"

echo -e "${GREEN}Getting Flutter dependencies...${NC}"
flutter pub get
if [ $? -ne 0 ]; then
    echo -e "${RED}ERROR: Failed to get Flutter dependencies${NC}"
    exit 1
fi

echo ""
echo -e "${GREEN}Building APK in $BUILD_MODE mode...${NC}"

if [ "$BUILD_MODE" == "release" ]; then
    flutter build apk --release --split-per-abi --target-platform android-arm64,android-arm \
        --obfuscate --split-debug-info ./split-debug-info
else
    flutter build apk --debug --split-per-abi --target-platform android-arm64,android-arm
fi

if [ $? -ne 0 ]; then
    echo -e "${RED}ERROR: Failed to build APK${NC}"
    exit 1
fi

# Step 3: Success
echo ""
echo -e "${CYAN}====================================${NC}"
echo -e "${GREEN}Build completed successfully!${NC}"
echo -e "${CYAN}====================================${NC}"
echo ""

echo -e "${YELLOW}Generated APK files:${NC}"
find "$PROJECT_ROOT/flutter/build/app/outputs/apk" -name "*.apk" -type f | while read f; do
    echo -e "${GREEN}  - $(basename $f)${NC}"
done

echo ""
echo -e "${YELLOW}Build output location:${NC}"
echo -e "${GREEN}  $PROJECT_ROOT/flutter/build/app/outputs/apk${NC}"
echo ""
