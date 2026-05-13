@echo off
setlocal EnableDelayedExpansion

set "REPO_ROOT=%~dp0"
cd /d "%REPO_ROOT%"

call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
if errorlevel 1 exit /b 1

set "LLVM_BIN=C:\Program Files\LLVM\bin"
set "VCPKG_ROOT=%REPO_ROOT%vcpkg_fake_root"
set "VCPKG_INCLUDE=%VCPKG_ROOT%\installed\x64-windows-static\include"
set "LIBCLANG_PATH=%LLVM_BIN%"
set "PATH=%LLVM_BIN%;%PATH%"
set "BINDGEN_EXTRA_CLANG_ARGS=-I%VCPKG_INCLUDE%"

for %%I in ("%INCLUDE:;=" "%") do (
  if not "%%~I"=="" (
    set "BINDGEN_EXTRA_CLANG_ARGS=!BINDGEN_EXTRA_CLANG_ARGS! -I%%~I"
  )
)

cargo run --release
exit /b %ERRORLEVEL%
