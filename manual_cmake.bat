
@echo off
set cmakePath="C:\agent_tools\vcpkg\downloads\tools\cmake-3.31.10-windows\cmake-3.31.10-windows-x86_64\bin\cmake.exe"
set msbuildPath="C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\MSBuild\Current\Bin\MSBuild.exe"
set vcvars="C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
set LIBCLANG_PATH=C:\Program Files\LLVM\bin

call %vcvars%
if %errorlevel% neq 0 exit /b %errorlevel%

cd /d "%~dp0flutter"
if exist build\windows rmdir /s /q build\windows
if not exist build\windows mkdir build\windows

echo Running CMake...
%cmakePath% -S windows -B build/windows -G "Visual Studio 17 2022" -A x64
if %errorlevel% neq 0 exit /b %errorlevel%

echo Building Rust Core...
cd ..
cargo build --features flutter --release --lib
if %errorlevel% neq 0 exit /b %errorlevel%

echo Building Virtual Display...
cargo build --release -p dylib_virtual_display
if %errorlevel% neq 0 exit /b %errorlevel%

echo Running Build...
cd flutter
%msbuildPath% build\windows\Anuvadini.sln /p:Configuration=Release /p:Platform=x64
