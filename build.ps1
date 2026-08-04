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

# --- 3. Step 1: Build Rust DLLs via CMD (to load vcvars64) ---
Write-Host "======================================================" -ForegroundColor Yellow
Write-Host "  STEP 1a: Building printer driver adapter DLL (app-side)" -ForegroundColor Yellow
Write-Host "======================================================" -ForegroundColor Yellow

$certThumb = "AFA10C71552B67EB796101C042B41E36EF9F6FCE"
$cert = Get-Item "Cert:\CurrentUser\My\$certThumb" -ErrorAction SilentlyContinue
$inf2cat = "C:\Program Files (x86)\Windows Kits\10\bin\10.0.28000.0\x86\Inf2Cat.exe"

$tmpBat = "$env:TEMP\anuvadini_build_printer.bat"
Set-Content -Path $tmpBat -Encoding ASCII -Value @(
    "@echo off",
    "call ""$VcvarsPath""",
    "if errorlevel 1 exit /b 1",
    "cargo build -p printer_driver_adapter --release",
    "if errorlevel 1 exit /b 1",
    "cargo build -p printer_driver_render_filter --release",
    "exit /b %ERRORLEVEL%"
)
cmd.exe /c $tmpBat
if ($LASTEXITCODE -ne 0) {
    Write-Error "printer driver build FAILED (exit code $LASTEXITCODE)"
    exit $LASTEXITCODE
}
Write-Host "  [OK] printer_driver_adapter.dll + AnuvadiniPrinterDriverRenderFilter.dll built" -ForegroundColor Green

# Sign both DLLs immediately after build
$adapterDll = "$ProjectRoot\target\release\printer_driver_adapter.dll"
$renderDll = "$ProjectRoot\target\release\AnuvadiniPrinterDriverRenderFilter.dll"
if ($cert) {
    if (Test-Path $adapterDll) {
        Set-AuthenticodeSignature -Certificate $cert -FilePath $adapterDll -ErrorAction SilentlyContinue | Out-Null
    }
    if (Test-Path $renderDll) {
        Set-AuthenticodeSignature -Certificate $cert -FilePath $renderDll -ErrorAction SilentlyContinue | Out-Null
    }
    Write-Host "  [OK] Signed both printer DLLs" -ForegroundColor Green
} else {
    Write-Host "  [Warning] Signing cert not found, printer DLLs unsigned" -ForegroundColor Yellow
}

# Refresh the v4 driver package: the render filter DLL is part of the package;
# the adapter DLL is app-side only and must NOT be in the package.
$driverDir = "$ProjectRoot\drivers\AnuvadiniPrinterDriver"
$driverRenderDll = "$driverDir\AnuvadiniPrinterDriverRenderFilter.dll"
$driverCat = "$driverDir\anuvadiniprinterdriver.cat"
if (Test-Path $renderDll) {
    Remove-Item -Path "$driverDir\printer_driver_adapter.dll" -Force -ErrorAction SilentlyContinue
    Copy-Item -Path $renderDll -Destination $driverRenderDll -Force
    Write-Host "  [OK] Copied AnuvadiniPrinterDriverRenderFilter.dll to drivers folder" -ForegroundColor Green
    if (Test-Path $inf2cat) {
        Remove-Item -Path $driverCat -Force -ErrorAction SilentlyContinue
        & $inf2cat /driver:$driverDir /os:10_X64 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  [Warning] Inf2Cat failed, catalog may be stale" -ForegroundColor Yellow
        } elseif ($cert -and (Test-Path $driverCat)) {
            Set-AuthenticodeSignature -Certificate $cert -FilePath $driverCat -ErrorAction SilentlyContinue | Out-Null
            Write-Host "  [OK] Regenerated and signed catalog" -ForegroundColor Green
        }
    } else {
        Write-Host "  [Warning] Inf2Cat not found, catalog may be stale" -ForegroundColor Yellow
    }
}
Write-Host ""

Write-Host "======================================================" -ForegroundColor Yellow
Write-Host "  STEP 1b: Building Rust DLL (anuvadini.dll)" -ForegroundColor Yellow
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

# --- 5. Copy printer driver files to Flutter output ---
Write-Host "======================================================" -ForegroundColor Yellow
Write-Host "  STEP 3: Copying printer driver files" -ForegroundColor Yellow
Write-Host "======================================================" -ForegroundColor Yellow

$releaseDir = "$ProjectRoot\flutter\build\windows\x64\runner\Release"
$printerDllSrc = "$ProjectRoot\target\release\printer_driver_adapter.dll"
$printerDllDst = "$releaseDir\printer_driver_adapter.dll"
$printerDriverDir = "$releaseDir\drivers\AnuvadiniPrinterDriver"

if (Test-Path $printerDllSrc) {
    # Sign the DLL with self-signed cert before copying to output
    $certThumb = "AFA10C71552B67EB796101C042B41E36EF9F6FCE"
    $cert = Get-Item "Cert:\CurrentUser\My\$certThumb" -ErrorAction SilentlyContinue
    if ($cert) {
        Set-AuthenticodeSignature -Certificate $cert -FilePath $printerDllSrc -ErrorAction SilentlyContinue | Out-Null
        # Also sign the .cat file if it exists
        $catFile = "$ProjectRoot\drivers\AnuvadiniPrinterDriver\anuvadiniprinterdriver.cat"
        if (Test-Path $catFile) {
            Set-AuthenticodeSignature -Certificate $cert -FilePath $catFile -ErrorAction SilentlyContinue | Out-Null
            Write-Host "  [OK] Signed .cat file" -ForegroundColor Green
        }
        Write-Host "  [OK] Signed printer_driver_adapter.dll" -ForegroundColor Green
    } else {
        Write-Host "  [Warning] Signing cert not found, DLL will be unsigned" -ForegroundColor Yellow
    }

    Copy-Item -Path $printerDllSrc -Destination $printerDllDst -Force
    Write-Host "  [OK] Copied printer_driver_adapter.dll to Flutter output" -ForegroundColor Green
    # Also copy the driver package folder for installation
    if (-not (Test-Path $printerDriverDir)) {
        New-Item -ItemType Directory -Path $printerDriverDir -Force | Out-Null
    }
    Copy-Item -Path "$ProjectRoot\drivers\AnuvadiniPrinterDriver\*" -Destination $printerDriverDir -Recurse -Force
    # Re-sign the render filter DLL and CAT in the drivers dir (build.rs may have overwritten with unsigned)
    if ($cert) {
        $driverDll = "$printerDriverDir\AnuvadiniPrinterDriverRenderFilter.dll"
        if (Test-Path $driverDll) {
            Set-AuthenticodeSignature -Certificate $cert -FilePath $driverDll -ErrorAction SilentlyContinue | Out-Null
        }
        $driverCat = "$printerDriverDir\anuvadiniprinterdriver.cat"
        if (Test-Path $driverCat) {
            Set-AuthenticodeSignature -Certificate $cert -FilePath $driverCat -ErrorAction SilentlyContinue | Out-Null
        }
    }
    Write-Host "  [OK] Copied AnuvadiniPrinterDriver package to Flutter output" -ForegroundColor Green
} else {
    Write-Host "  [Warning] printer_driver_adapter.dll not found at $printerDllSrc" -ForegroundColor Yellow
}

# --- 6. Done ---
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
