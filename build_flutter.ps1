
$vcvars = "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
$env:PATH = "C:\Users\jatin\src\flutter_windows_3.41.5-stable\flutter\bin;C:\Program Files\LLVM\bin;" + $env:PATH
$env:LIBCLANG_PATH = "C:\Program Files\LLVM\bin\libclang.dll"

# Create a temporary batch file to run the build with initialized environment
$batContent = @"
@echo off
call "$vcvars"
if %errorlevel% neq 0 exit /b %errorlevel%
cd /d "%~dp0flutter"
flutter build windows --release
"@

$batFile = "$PSScriptRoot\flutter_build_cmd.bat"
Set-Content -Path $batFile -Value $batContent -Encoding Ascii

Write-Host "Starting Flutter build with toolchain..."
cmd /c "$batFile" 2>&1 | Out-File -FilePath flutter_build_out.log -Encoding utf8
