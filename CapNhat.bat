@echo off
setlocal EnableDelayedExpansion
rem Cai cac goi cap nhat (v*) vao runtime. Gop tat ca goi: moi file chi lay ban cua goi moi nhat, xem truoc,
rem hoi Y/N mot lan, sao luu + chep moi file mot lan (CapNhat.ps1).
rem Cach dung: CapNhat.bat [thu muc goc]   (mac dinh: thu muc cha cua Update, vd E:\PhongThan)
cd /d "%~dp0"
set "TARGET=%~1"
if "%TARGET%"=="" set "TARGET=%~dp0.."

:menu
cls
echo ==================================================
echo   PHONG THAN - CAI DAT BAN CAP NHAT
echo   Runtime: %TARGET%
echo ==================================================
echo   Cac goi co trong thu muc:
set N=0
for /f "delims=" %%D in ('dir /b /ad /on "v*"') do (
    if exist "%%D\SHA256SUMS.txt" (
        set /a N+=1
        set "PKG!N!=%%D"
        echo     !N!^) %%D
    )
)
echo --------------------------------------------------
echo   1. Cap nhat tat ca (Server + Client)
echo   2. Chi Client
echo   3. Chi Server
echo   4. Chon mot goi (Server + Client)
echo   0. Thoat
echo --------------------------------------------------
echo   Luu y: tat game va server truoc khi cai.
set "CHOICE="
set /p CHOICE=Chon:
if "%CHOICE%"=="1" set "PART=All" & goto run
if "%CHOICE%"=="2" set "PART=Client" & goto run
if "%CHOICE%"=="3" set "PART=Server" & goto run
if "%CHOICE%"=="4" goto one
if "%CHOICE%"=="0" exit /b 0
goto menu

:run
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0CapNhat.ps1" -Target "%TARGET%" -Part %PART%
pause
goto menu

:one
set "PICK="
set /p PICK=So thu tu goi (1-%N%):
if not defined PKG%PICK% goto menu
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0CapNhat.ps1" -Target "%TARGET%" -Part All -Only "!PKG%PICK%!"
pause
goto menu
