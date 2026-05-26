@echo off
setlocal
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
if errorlevel 1 exit /b 1

set "LIBCLANG_PATH=C:\Program Files\LLVM\bin"
set "PATH=C:\Program Files\LLVM\bin;%PATH%"
set "VCPKG_ROOT=C:\Users\jatin\Downloads\anuvadini\vcpkg_fake_root"
set "BINDGEN_EXTRA_CLANG_ARGS=-IC:\Users\jatin\Downloads\anuvadini\vcpkg_fake_root\installed\x64-windows-static\include"

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
