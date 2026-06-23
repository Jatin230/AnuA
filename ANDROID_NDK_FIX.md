# Fixing Android NDK Build Issues on Windows

## Problem
When building Rust code for Android targets, you get errors like:
```
Failed to find tool. Is `clang.exe` installed?
Failed to find tool. Is `aarch64-linux-android-clang` installed?
```

## Root Cause
The `ring` crate (and other crates with C/C++ code) need to compile C code for Android. The build system can't find the Android NDK's C compiler because environment variables aren't properly configured.

## Solution

### Step 1: Verify NDK Installation
```powershell
# Check if NDK exists at the expected location
dir "C:\Users\jatin\AppData\Local\Android\sdk\ndk"

# You should see a version folder like "30.0.14904198"
```

If NDK is not installed:
1. Open Android Studio
2. Click SDK Manager (bottom right)
3. Go to SDK Tools tab
4. Check "NDK" checkbox
5. Click Apply
6. Wait for installation to complete

### Step 2: Update .cargo/config.toml

The config has been updated to include CC and CXX settings. This tells cargo where to find the Android NDK C compilers.

### Step 3: Try Building Again

#### Option A: Using the NDK build script (Recommended)
```powershell
cd C:\Users\jatin\Downloads\rustdesk
.\build_android_ndk.ps1 -Target aarch64 -BuildMode release

# Or build both targets
.\build_android_ndk.ps1 -Target all -BuildMode release
```

#### Option B: Manual build with environment variables
```powershell
cd C:\Users\jatin\Downloads\rustdesk

# Set environment variables
$NDK = "C:\Users\jatin\AppData\Local\Android\sdk\ndk\30.0.14904198\toolchains\llvm\prebuilt\windows-x86_64\bin"
$env:CC_aarch64_linux_android = "$NDK\aarch64-linux-android35-clang.cmd"
$env:CXX_aarch64_linux_android = "$NDK\aarch64-linux-android35-clang++.cmd"

# Build
cargo build --target aarch64-linux-android --release
```

#### Option C: Direct cargo build
```powershell
cd C:\Users\jatin\Downloads\rustdesk
cargo build --target aarch64-linux-android --release
```

### Step 4: Build Complete Flutter APK

Once Rust compilation succeeds:
```powershell
cd flutter
flutter pub get
flutter build apk --release --split-per-abi
```

## Troubleshooting

### Still getting compiler errors?

**Check 1: NDK toolchain files exist**
```powershell
dir "C:\Users\jatin\AppData\Local\Android\sdk\ndk\30.0.14904198\toolchains\llvm\prebuilt\windows-x86_64\bin\aarch64*"
```

You should see files like:
- `aarch64-linux-android35-clang.cmd`
- `aarch64-linux-android35-clang++.cmd`

**Check 2: Clear Cargo cache**
```powershell
cd C:\Users\jatin\Downloads\rustdesk
cargo clean
cargo build --target aarch64-linux-android --release
```

**Check 3: Verify NDK environment**
```powershell
$NDK = "C:\Users\jatin\AppData\Local\Android\sdk\ndk\30.0.14904198"
echo $NDK
ls "$NDK\toolchains\llvm\prebuilt\windows-x86_64\bin"
```

**Check 4: Update rustup Android targets**
```powershell
rustup target add aarch64-linux-android
rustup target add armv7-linux-androideabi
rustup update
```

## Common NDK Paths

If your NDK is in a different location, update the paths:

**Standard Android Studio installation:**
```
C:\Users\<username>\AppData\Local\Android\sdk\ndk\<version>
```

**Custom NDK location:**
Check in Android Studio:
1. File → Settings → Appearance & Behavior → System Settings → Android SDK
2. Look for "Android NDK location"

## Environment Variables for Reference

The `.cargo/config.toml` now includes:
- `CC_aarch64_linux_android` - C compiler for 64-bit ARM
- `CXX_aarch64_linux_android` - C++ compiler for 64-bit ARM
- `CC_armv7_linux_androideabi` - C compiler for 32-bit ARM
- `CXX_armv7_linux_androideabi` - C++ compiler for 32-bit ARM

## Final APK Build

After successful Rust build:
```powershell
cd flutter
flutter build apk --release --split-per-abi --obfuscate --split-debug-info ./split-debug-info
```

Output will be at: `flutter/build/app/outputs/apk/release/`

## Additional Resources

- [Android NDK Documentation](https://developer.android.com/ndk/downloads)
- [Cargo Build Script Documentation](https://doc.rust-lang.org/cargo/build-script-examples.html)
- [Ring Crate Build Requirements](https://github.com/briansmith/ring/blob/main/BUILDING.md)
