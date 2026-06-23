@echo off
REM Build APK for RustDesk Android
REM This script builds the native Rust libraries and then the Flutter APK

setlocal enabledelayedexpansion

echo.
echo ====================================
echo RustDesk APK Builder for Windows
echo ====================================
echo.

REM Set build mode (debug or release)
if "%1"=="" (
    set MODE=release
) else (
    set MODE=%1
)

echo Build Mode: %MODE%
echo.

REM Check if required tools are available
echo Checking prerequisites...
where flutter >nul 2>&1
if errorlevel 1 (
    echo ERROR: Flutter is not installed or not in PATH
    echo Please install Flutter and add it to your PATH
    exit /b 1
)

where cargo >nul 2>&1
if errorlevel 1 (
    echo ERROR: Rust/Cargo is not installed or not in PATH
    echo Please install Rust and add it to your PATH
    exit /b 1
)

REM Get the project root directory
cd /d "%~dp0"
set PROJECT_ROOT=%CD%

echo Project Root: %PROJECT_ROOT%
echo.

REM Build Rust native libraries for Android
echo.
echo ====================================
echo Step 1: Building Rust native libraries for Android
echo ====================================
echo.

REM You may need to adjust these for different ARM architectures
echo Building for ARM64 (aarch64)...
cargo build --manifest-path "%PROJECT_ROOT%\Cargo.toml" --target aarch64-linux-android --%MODE%
if errorlevel 1 (
    echo ERROR: Failed to build Rust libraries for aarch64
    exit /b 1
)

echo.
echo Building for ARMv7
cargo build --manifest-path "%PROJECT_ROOT%\Cargo.toml" --target armv7-linux-androideabi --%MODE%
if errorlevel 1 (
    echo WARNING: Failed to build Rust libraries for armv7 (this may be optional)
)

echo.
echo ====================================
echo Step 2: Building Flutter APK
echo ====================================
echo.

cd /d "%PROJECT_ROOT%\flutter"

REM Clean previous builds (optional)
echo Cleaning previous builds...
call flutter clean

REM Get dependencies
echo Getting Flutter dependencies...
call flutter pub get

REM Build the APK
echo.
echo Building APK in %MODE% mode...
if "%MODE%"=="release" (
    call flutter build apk --release --split-per-abi --target-platform android-arm64,android-arm --obfuscate --split-debug-info ./split-debug-info
) else (
    call flutter build apk --debug --split-per-abi --target-platform android-arm64,android-arm
)

if errorlevel 1 (
    echo ERROR: Failed to build APK
    exit /b 1
)

echo.
echo ====================================
echo Build completed successfully!
echo ====================================
echo.

REM List the generated APKs
echo Generated APK files:
for /r "%PROJECT_ROOT%\flutter\build\app\outputs\apk" %%F in (*.apk) do (
    echo   - %%~nxF
)

echo.
echo Build output location: %PROJECT_ROOT%\flutter\build\app\outputs\apk
echo.

goto END

:END
endlocal
exit /b 0
