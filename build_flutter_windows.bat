@echo off
setlocal EnableDelayedExpansion

set "REPO_ROOT=%~dp0"
cd /d "%REPO_ROOT%"

call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
if errorlevel 1 (
  echo Failed to initialize Visual Studio build environment.
  exit /b 1
)

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

if not exist "%VCPKG_INCLUDE%\opus\opus_multistream.h" (
  echo Missing opus headers at "%VCPKG_INCLUDE%".
  exit /b 1
)

echo Building Flutter Windows package...
if exist "%REPO_ROOT%flutter\build\windows" (
  echo Removing stale Flutter Windows CMake cache...
  rmdir /s /q "%REPO_ROOT%flutter\build\windows"
)

set "CMAKE_GENERATOR=Visual Studio 17 2022"
python build.py --flutter --skip-portable-pack %*
exit /b %ERRORLEVEL%
