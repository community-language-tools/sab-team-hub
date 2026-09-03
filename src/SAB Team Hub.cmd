@echo off
setlocal
chcp 65001 >nul
title SAB Team Hub

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0SAB-Team-Hub.ps1" %*
set "HUB_EXIT=%ERRORLEVEL%"

if not "%HUB_EXIT%"=="0" (
  echo.
  echo The Hub stopped with an error. The message above says what happened.
  echo.
  pause
)

endlocal & exit /b %HUB_EXIT%
