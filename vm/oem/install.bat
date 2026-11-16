@echo off
rem Runs once at the end of the unattended install (dockurr/windows copies /oem to C:\OEM).
powershell -NoProfile -ExecutionPolicy Bypass -File C:\OEM\setup-ssh.ps1 > C:\OEM\setup-ssh.log 2>&1
