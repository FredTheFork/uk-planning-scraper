@echo off
setlocal enableextensions

REM ============================================================
REM  UK Planning Scraper - Desktop Shortcut Launcher
REM ============================================================
REM  Copy this file to your Desktop and double-click it to run
REM  the scraper. It finds the project folder automatically.
REM
REM  HOW TO USE:
REM    1. Copy this file to your Desktop
REM    2. Double-click it any time you want to run the scraper
REM    3. Results are saved as CSV files in the project folder
REM ============================================================

REM --- CONFIGURATION: Set this to your project folder path ---
REM If you used the default location, this should work as-is.
REM If your project is elsewhere, change the line below.
set "PROJECT_DIR=%USERPROFILE%\uk-planning-scraper"

REM Try common locations if the default doesn't exist
if not exist "%PROJECT_DIR%\scrape.rb" (
    set "PROJECT_DIR=%USERPROFILE%\Desktop\uk-planning-scraper"
)
if not exist "%PROJECT_DIR%\scrape.rb" (
    set "PROJECT_DIR=%USERPROFILE%\Documents\uk-planning-scraper"
)
if not exist "%PROJECT_DIR%\scrape.rb" (
    REM Try the I: drive location from the original setup
    set "PROJECT_DIR=I:\ukplanningscraper (newest update)"
)

if not exist "%PROJECT_DIR%\scrape.rb" (
    echo.
    echo ERROR: Could not find the scraper project folder.
    echo.
    echo Please edit this file and set PROJECT_DIR to the correct path.
    echo For example:
    echo   set "PROJECT_DIR=C:\Users\YourName\Documents\uk-planning-scraper"
    echo.
    pause
    exit /b 1
)

echo Found project at: %PROJECT_DIR%
echo.

cd /d "%PROJECT_DIR%"

REM Clear any stale PLAYWRIGHT_BROWSERS_PATH
set "PLAYWRIGHT_BROWSERS_PATH="

REM Run the main batch file
call "%PROJECT_DIR%\run.bat"
