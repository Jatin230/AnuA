@echo off
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
if errorlevel 1 exit /b 1
set VCPKG_ROOT=C:\Users\jatin\Downloads\rustdesk\vcpkg_fake_root
set LIBCLANG_PATH=C:\Program Files\LLVM\bin
set BINDGEN_EXTRA_CLANG_ARGS=-IC:\Users\jatin\Downloads\rustdesk\vcpkg_fake_root\installed\x64-windows-static\include
set PATH=C:\Program Files\LLVM\bin;%PATH%
echo.
echo === Rebuilding Rust DLL with webrtc feature ===
cargo build --features "flutter webrtc" --lib --release
exit /b %ERRORLEVEL%
