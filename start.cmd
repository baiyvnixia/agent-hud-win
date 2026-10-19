@echo off
rem Agent HUD - start with a console window attached (useful for debugging).
rem For normal use, run start-silent.vbs instead so no console flashes.
powershell -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0hud.ps1" %*
