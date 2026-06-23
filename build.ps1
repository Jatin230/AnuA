# build.ps1 - Full Anuvadini Windows build (Rust + Flutter)
# Run from the project root: .\build.ps1

$ErrorActionPreference = "Stop"
$ProjectRoot = $PSScriptRoot

# --- 1. Validate tools ---
$VcvarsPath = "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
if (-not (Test-Path $VcvarsPath)) {
    Write-Error "VS 2022 BuildTools not found at: $VcvarsPath"
    exit 1
}

$FlutterBat = "C:\Users\jatin\src\flutter\bin\flutter.bat"
if (-not (Test-Path $FlutterBat)) {
    Write-Error "Flutter not found at: $FlutterBat"
    exit 1
}

# --- 2. Set required environment variables ---
$env:VCPKG_ROOT = "$ProjectRoot\vcpkg_fake_root"
$env:LIBCLANG_PATH = "C:\Program Files\LLVM\bin"
$env:BINDGEN_EXTRA_CLANG_ARGS = "-I$ProjectRoot\vcpkg_fake_root\installed\x64-windows-static\include"
$env:PATH = "C:\Program Files\LLVM\bin;" + $env:PATH

Write-Host ""
Write-Host "======================================================" -ForegroundColor Cyan
Write-Host "  Environment" -ForegroundColor Cyan
Write-Host "======================================================" -ForegroundColor Cyan
Write-Host "  VCPKG_ROOT   : $env:VCPKG_ROOT"
Write-Host "  LIBCLANG_PATH: $env:LIBCLANG_PATH"
Write-Host ""

# --- 3. Step 1: Build Rust DLL via CMD (to load vcvars64) ---
Write-Host "======================================================" -ForegroundColor Yellow
Write-Host "  STEP 1: Building Rust DLL (anuvadini.dll)" -ForegroundColor Yellow
Write-Host "======================================================" -ForegroundColor Yellow

$vcpkgRoot = $env:VCPKG_ROOT
$libclangPath = $env:LIBCLANG_PATH
$bindgenArgs = $env:BINDGEN_EXTRA_CLANG_ARGS

$tmpBat = "$env:TEMP\anuvadini_build_rust.bat"

Set-Content -Path $tmpBat -Encoding ASCII -Value @(
    "@echo off",
    "call ""$VcvarsPath""",
    "if errorlevel 1 exit /b 1",
    "set VCPKG_ROOT=$vcpkgRoot",
    "set LIBCLANG_PATH=$libclangPath",
    "set BINDGEN_EXTRA_CLANG_ARGS=$bindgenArgs",
    "set PATH=C:\Program Files\LLVM\bin;%PATH%",
    "cargo build --features ""flutter webrtc"" --lib --release",
    "exit /b %ERRORLEVEL%"
)

cmd.exe /c $tmpBat
if ($LASTEXITCODE -ne 0) {
    Write-Error "Rust build FAILED (exit code $LASTEXITCODE)"
    exit $LASTEXITCODE
}

# Verify the DLL was produced
$dllPath = "$ProjectRoot\target\release\anuvadini.dll"
if (-not (Test-Path $dllPath)) {
    Write-Error "Expected DLL not found: $dllPath"
    exit 1
}
Write-Host ""
Write-Host "  [OK] Rust DLL built: $dllPath" -ForegroundColor Green
Write-Host ""

# --- 4. Step 2: Build Flutter Windows release ---
Write-Host "======================================================" -ForegroundColor Yellow
Write-Host "  STEP 2: Building Flutter Windows app" -ForegroundColor Yellow
Write-Host "======================================================" -ForegroundColor Yellow

Push-Location "$ProjectRoot\flutter"
try {
    & $FlutterBat build windows --release
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Flutter build FAILED (exit code $LASTEXITCODE)"
        exit $LASTEXITCODE
    }
}
finally {
    Pop-Location
}

# --- 5. Done ---
$releaseDir = "$ProjectRoot\flutter\build\windows\x64\runner\Release"
$opusSource = "$ProjectRoot\vcpkg_fake_root\installed\x64-windows\bin\opus.dll"
$opusDest = "$releaseDir\opus.dll"

if (Test-Path $opusSource) {
    if (Test-Path $releaseDir) {
        Write-Host "  Copying $opusSource to $releaseDir..."
        Copy-Item -Path $opusSource -Destination $opusDest -Force
    }
} else {
    Write-Host "  [Warning] opus.dll not found in vcpkg folder: $opusSource" -ForegroundColor Yellow
}

$exePath = "$releaseDir\Anuvadini.exe"
Write-Host ""
Write-Host "======================================================" -ForegroundColor Green
Write-Host "  BUILD COMPLETE" -ForegroundColor Green
Write-Host "======================================================" -ForegroundColor Green
if (Test-Path $exePath) {
    Write-Host "  EXE: $exePath" -ForegroundColor Green
} else {
    Write-Host "  EXE not found - check flutter\build\" -ForegroundColor Yellow
}
Write-Host ""
