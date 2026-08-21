@echo off
rem =====================================================================
rem s6.cmd  -  run tools\s6.ps1 without touching the execution policy
rem ---------------------------------------------------------------------
rem A stock Windows refuses to run .ps1 files (execution policy
rem "Restricted"). This wrapper bypasses that for this one script only,
rem which is per-process and changes nothing on the machine:
rem
rem     .\tools\s6.cmd ports
rem     .\tools\s6.cmd prog
rem     .\tools\s6.cmd term
rem     .\tools\s6.cmd upload -Port COM4
rem =====================================================================
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0s6.ps1" %*
exit /b %ERRORLEVEL%
