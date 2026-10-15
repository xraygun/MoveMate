@echo off
rem MoveMate - move user files from an old PC to a new PC (network, direct cable, external drive or server). See HOW-TO.txt.
start "" powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0scripts\Migrate-UserFiles.ps1"
