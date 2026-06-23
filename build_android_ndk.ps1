# Set up Android NDK environment variables and build APK
# This script configures the NDK paths and then builds for Android

param(
    [ValidateSet("aarch64", "armv7", "all")]
    [string]$Target = "aarch64",
    
    [ValidateSet("debug", "release")]
    [string]$BuildMode = "release"
)

$ErrorActionPreference = "Stop"

# Android NDK path
$NDK_HOME = "C:\Users\jatin\AppData\Local\Android\sdk\ndk\30.0.14904198"
$NDK_TOOLCHAIN = "$NDK_HOME\toolchains\llvm\prebuilt\windows-x86_64\bin"

# Verify NDK exists
if (-not (Test-Path $NDK_HOME)) {
    Write-Host "ERROR: Android NDK not found at $NDK_HOME" -ForegroundColor Red
    exit 1
}

Write-Host "Setting up Android NDK environment..." -ForegroundColor Cyan
Write-Host "NDK Path: $NDK_HOME" -ForegroundColor Yellow

# Set environment variables for aarch64
if ($Target -eq "aarch64" -or $Target -eq "all") {
    Write-Host "`nConfiguring for aarch64-linux-android..." -ForegroundColor Green
    
    $env:CC_aarch64_linux_android = "$NDK_TOOLCHAIN\aarch64-linux-android35-clang.cmd"
    $env:AR_aarch64_linux_android = "$NDK_TOOLCHAIN\llvm-ar.exe"
    
    # Skip OpenSSL vendor build (use pre-built from NDK)
    $env:OPENSSL_NO_VENDOR = "1"
    $env:OPENSSL_LIB_DIR = "$NDK_HOME\toolchains\llvm\prebuilt\windows-x86_64\sysroot\usr\lib\aarch64-linux-android"
    $env:OPENSSL_INCLUDE_DIR = "$NDK_HOME\toolchains\llvm\prebuilt\windows-x86_64\sysroot\usr\include"
    
    Write-Host "Building aarch64 target..."
    & cargo build --target aarch64-linux-android --$BuildMode
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: Build failed for aarch64" -ForegroundColor Red
        exit 1
    }
}

# Set environment variables for armv7
if ($Target -eq "armv7" -or $Target -eq "all") {
    Write-Host "`nConfiguring for armv7-linux-androideabi..." -ForegroundColor Green
    
    $env:CC_armv7_linux_androideabi = "$NDK_TOOLCHAIN\armv7a-linux-androideabi35-clang.cmd"
    $env:AR_armv7_linux_androideabi = "$NDK_TOOLCHAIN\llvm-ar.exe"
    
    # Skip OpenSSL vendor build (use pre-built from NDK)
    $env:OPENSSL_NO_VENDOR = "1"
    $env:OPENSSL_LIB_DIR = "$NDK_HOME\toolchains\llvm\prebuilt\windows-x86_64\sysroot\usr\lib\armv7a-linux-androideabi"
    $env:OPENSSL_INCLUDE_DIR = "$NDK_HOME\toolchains\llvm\prebuilt\windows-x86_64\sysroot\usr\include"
    
    Write-Host "Building armv7 target..."
    & cargo build --target armv7-linux-androideabi --$BuildMode
    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: Build failed for armv7" -ForegroundColor Red
        exit 1
    }
}

Write-Host "`nBuild completed successfully!" -ForegroundColor Green
