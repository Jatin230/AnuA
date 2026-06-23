# Building RustDesk APK for Android

This guide explains how to build an Android APK file for the RustDesk project on Windows.

## Prerequisites

Before building the APK, ensure you have the following installed:

### 1. **Flutter SDK**
   - Download from: https://flutter.dev/docs/get-started/install/windows
   - Add Flutter to your PATH environment variable
   - Verify installation:
     ```
     flutter --version
     ```

### 2. **Rust Toolchain**
   - Download from: https://rustup.rs/
   - Add Rust targets for Android:
     ```
     rustup target add aarch64-linux-android
     rustup target add armv7-linux-androideabi
     rustup target add x86_64-linux-android
     rustup target add i686-linux-android
     ```

### 3. **Android SDK & NDK**
   - Install Android Studio from: https://developer.android.com/studio
   - Install Android SDK (API 21+)
   - Install Android NDK (r23b or later recommended)
   - Set environment variables:
     ```
     ANDROID_SDK_ROOT=C:\Users\<username>\AppData\Local\Android\sdk
     ANDROID_NDK_HOME=C:\Users\<username>\AppData\Local\Android\sdk\ndk\<version>
     ```

### 4. **Java Development Kit (JDK)**
   - Install JDK 11 or higher
   - Set JAVA_HOME environment variable

### 5. **Git** (if not already installed)
   - Download from: https://git-scm.com/

## Build Instructions

### Option 1: Using PowerShell (Recommended for Windows)

```powershell
# Navigate to the project root
cd C:\Users\<username>\Downloads\rustdesk

# Run the build script
.\build_apk_windows.ps1 -BuildMode release

# Optional parameters:
# -BuildMode debug      : Build in debug mode (faster, larger APK)
# -SkipRustBuild        : Skip Rust compilation (if already done)
# -SkipClean            : Skip cleaning previous builds
```

Example with all options:
```powershell
.\build_apk_windows.ps1 -BuildMode release -SkipClean
```

### Option 2: Using Batch (CMD)

```bash
cd C:\Users\<username>\Downloads\rustdesk
build_apk_windows.bat release
```

Or for debug build:
```bash
build_apk_windows.bat debug
```

### Option 3: Manual Step-by-Step Build

#### Step 1: Build Rust Native Libraries

```bash
cd C:\Users\<username>\Downloads\rustdesk

# For ARM64 (most common for modern devices)
cargo build --target aarch64-linux-android --release

# For ARMv7 (older devices)
cargo build --target armv7-linux-androideabi --release

# For x86_64 (emulator)
cargo build --target x86_64-linux-android --release
```

#### Step 2: Build Flutter APK

```bash
cd flutter

# Get dependencies
flutter pub get

# Build release APK (split per ABI for smaller individual APKs)
flutter build apk --release --split-per-abi

# Or build a universal APK (larger, works on all devices)
flutter build apk --release
```

## Build Output

The compiled APK files will be located at:
```
flutter/build/app/outputs/apk/release/
```

For split APKs:
- `app-armeabi-v7a-release.apk` - For 32-bit ARM devices
- `app-arm64-v8a-release.apk` - For 64-bit ARM devices

## Common Issues & Solutions

### Issue: "flutter: command not found"
**Solution:** Add Flutter to your PATH environment variable
1. Find Flutter SDK installation path
2. Go to Settings → Environment Variables
3. Add Flutter/bin directory to PATH

### Issue: "Cargo not found"
**Solution:** Install Rust from https://rustup.rs/ and restart terminal

### Issue: "ANDROID_NDK_HOME not found"
**Solution:** Set NDK path in environment variables
```bash
set ANDROID_NDK_HOME=C:\Users\<username>\AppData\Local\Android\sdk\ndk\<version>
```

### Issue: "Missing protoc or other build tools"
**Solution:** Run the script again or install missing components through Android Studio

### Issue: "Build times out or hangs"
**Solution:**
1. Increase available RAM (at least 8GB recommended)
2. Close other applications
3. Clear build cache: `flutter clean`
4. Try building in debug mode first for testing

## Build Variants

### Debug Build (Faster, Larger Size)
```bash
flutter build apk --debug
```
- Faster compilation
- Larger APK size
- Useful for testing

### Release Build (Slower, Optimized, Smaller Size)
```bash
flutter build apk --release
```
- Optimized for performance
- Smaller APK size
- Ready for distribution
- With obfuscation and split debug info

### Universal APK (Single APK for All Devices)
```bash
flutter build apk --release
```

### Split-Per-ABI APKs (Separate APK per Architecture)
```bash
flutter build apk --release --split-per-abi
```
- Smaller downloads
- Users get only their device's version

## App Bundle (For Google Play Store)

To create an App Bundle for publishing to Google Play Store:

```bash
flutter build appbundle --release
```

Output location: `flutter/build/app/outputs/bundle/release/app-release.aab`

## Signing the APK

For production releases, you need to sign the APK. Create a signing key:

```bash
keytool -genkey -v -keystore release.keystore -alias my-key-alias -keyalg RSA -keysize 2048 -validity 10000
```

Then configure in `flutter/android/app/build.gradle` or create `key.properties`:

```properties
storeFile=release.keystore
storePassword=your_password
keyAlias=my-key-alias
keyPassword=your_key_password
```

## Next Steps

After building:
1. Copy APK to Android device
2. Install: `adb install app-release.apk`
3. Or share through Play Store, APKMirror, etc.

## Additional Resources

- [Flutter Android Documentation](https://flutter.dev/docs/deployment/android)
- [Android NDK Setup](https://developer.android.com/ndk/guides/setup)
- [Rust Android Documentation](https://rust-lang.github.io/rustup/cross-compilation.html)
