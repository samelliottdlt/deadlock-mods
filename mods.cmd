@echo off
rem Front end for scripts\Mods.ps1: run ".\mods help" (PowerShell) or "mods help" (cmd) from the repo root.
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Mods.ps1" %*
