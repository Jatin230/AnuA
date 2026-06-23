# Build APK for RustDesk Android
# This PowerShell script builds the native Rust libraries and then the Flutter APK

param(
    [ValidateSet("debug", "release")]
    [string]$BuildMode = "release",
    
    [switch]$SkipRustBuild = $false,
    
    [switch]$SkipClean = $false
)

# Set error action preference
$ErrorActionPreference = "Stop"

# Color functions for output
function Write-Header($message) {
    Write-Host ""
    Write-Host "====================================" -ForegroundColor Cyan
    Write-Host $message -ForegroundColor Cyan
    Write-Host "====================================" -ForegroundColor Cyan
    Write-Host ""
}

function Write-Step($message) {
    Write-Host $message -ForegroundColor Green
}

function Write-Error($message) {
    Write-Host "ERROR: $message" -ForegroundColor Red
}

# Main script
try {
    Write-Header "RustDesk APK Builder for Windows (PowerShell)"
    
    Write-Host "Build Mode: $BuildMode" -ForegroundColor Yellow
    Write-Host ""
    
    # Check prerequisites
    Write-Step "Checking prerequisites..."
    
    $flutterCheck = Get-Command flutter -ErrorAction SilentlyContinue
    if (-not $flutterCheck) {
        throw "Flutter is not installed or not in PATH. Please install Flutter."
    }
    
    $cargoCheck = Get-Command cargo -ErrorAction SilentlyContinue
    if (-not $cargoCheck) {
        throw "Rust/Cargo is not installed or not in PATH. Please install Rust."
    }
    
    # Get project root
    $ProjectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
    Write-Host "Project Root: $ProjectRoot" -ForegroundColor Yellow
    Write-Host ""
    
    # Build Rust native libraries for Android (if not skipped)
    if (-not $SkipRustBuild) {
        Write-Header "Step 1: Building Rust native libraries for Android"
        
        Write-Step "Building for ARM64 (aarch64)..."
        & cargo build --manifest-path "$ProjectRoot\Cargo.toml" --target aarch64-linux-android --$BuildMode
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to build Rust libraries for aarch64"
        }
        
        Write-Host ""
        Write-Step "Building for ARMv7..."
        & cargo build --manifest-path "$ProjectRoot\Cargo.toml" --target armv7-linux-androideabi --$BuildMode
        if ($LASTEXITCODE -ne 0) {
            Write-Host "WARNING: Failed to build Rust libraries for armv7 (this may be optional)" -ForegroundColor Yellow
        }
    }
    
    Write-Header "Step 2: Building Flutter APK"
    
    # Navigate to flutter directory
    Push-Location "$ProjectRoot\flutter"
    
    # Clean previous builds (if not skipped)
    if (-not $SkipClean) {
        Write-Step "Cleaning previous builds..."
        & flutter clean
        if ($LASTEXITCODE -ne 0) {
            Write-Host "WARNING: Flutter clean returned non-zero exit code" -ForegroundColor Yellow
        }
    }
    
    # Get dependencies
    Write-Step "Getting Flutter dependencies..."
    & flutter pub get
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to get Flutter dependencies"
    }
    
    # Build APK
    Write-Host ""
    Write-Step "Building APK in $BuildMode mode..."
    
    if ($BuildMode -eq "release") {
        & flutter build apk --release --split-per-abi --target-platform android-arm64,android-arm --obfuscate --split-debug-info ./split-debug-info
    } else {
        & flutter build apk --debug --split-per-abi --target-platform android-arm64,android-arm
    }
    
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to build APK"
    }
    
    # Return to original location
    Pop-Location
    
    Write-Header "Build completed successfully!"
    
    # List generated APKs
    Write-Host "Generated APK files:" -ForegroundColor Yellow
    $apkPath = "$ProjectRoot\flutter\build\app\outputs\apk"
    if (Test-Path $apkPath) {
        Get-ChildItem -Path $apkPath -Filter "*.apk" -Recurse | ForEach-Object {
            Write-Host "  - $($_.Name)" -ForegroundColor Green
        }
    }
    
    Write-Host ""
    Write-Host "Build output location: $apkPath" -ForegroundColor Yellow
    Write-Host ""
    
} catch {
    Write-Error $_.Exception.Message
    exit 1
}
