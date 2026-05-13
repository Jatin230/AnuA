@echo off
setlocal

set "REPO_ROOT=%~dp0"
set "APP_EXE=%REPO_ROOT%flutter\build\windows\x64\runner\Release\rustdesk.exe"

if not exist "%APP_EXE%" (
  echo Flutter build output not found.
  echo Run build first: build_flutter_windows.bat
  exit /b 1
)

start "" "%APP_EXE%"
exit /b 0
