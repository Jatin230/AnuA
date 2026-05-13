$ErrorActionPreference = "Continue"

$repoRoot = $PSScriptRoot
$vcvars = "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
$llvmBin = "C:\Program Files\LLVM\bin"
$vcpkgFakeRoot = Join-Path $repoRoot "vcpkg_fake_root"
$vcpkgInclude = Join-Path $vcpkgFakeRoot "installed\x64-windows-static\include"

if (-not (Test-Path $vcvars)) {
    throw "vcvars64.bat not found at: $vcvars"
}
if (-not (Test-Path (Join-Path $llvmBin "libclang.dll"))) {
    throw "libclang.dll not found at: $llvmBin"
}
if (-not (Test-Path (Join-Path $vcpkgInclude "opus\opus_multistream.h"))) {
    throw "Opus headers not found at: $vcpkgInclude"
}

# Build batch script so vcvars applies to the same cmd process as cargo.
$batContent = @"
@echo off
setlocal
call "$vcvars"
if errorlevel 1 exit /b 1

set "LIBCLANG_PATH=$llvmBin"
set "PATH=$llvmBin;%PATH%"
set "VCPKG_ROOT=$vcpkgFakeRoot"
set "BINDGEN_EXTRA_CLANG_ARGS=-I$vcpkgInclude"

for %%I in ("%INCLUDE:;=" "%") do (
  if not "%%~I"=="" (
    set "BINDGEN_EXTRA_CLANG_ARGS=!BINDGEN_EXTRA_CLANG_ARGS! -I%%~I"
  )
)

echo LIBCLANG_PATH=%LIBCLANG_PATH%
echo VCPKG_ROOT=%VCPKG_ROOT%
echo BINDGEN_EXTRA_CLANG_ARGS=%BINDGEN_EXTRA_CLANG_ARGS%

cargo build --features flutter --lib --release -v
exit /b %ERRORLEVEL%
"@

$batFile = Join-Path $repoRoot "build_cmd.bat"
Set-Content -Path $batFile -Value $batContent -Encoding Ascii

Push-Location $repoRoot
try {
    cmd /v:on /c "$batFile" 2>&1 | Tee-Object -FilePath (Join-Path $repoRoot "build_native_out.log") | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "Native build failed with exit code $LASTEXITCODE"
    }
} finally {
    Pop-Location
}
