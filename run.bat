@echo off
setlocal enableextensions enabledelayedexpansion

REM ============================================================
REM  UK Planning Scraper - One-Click Launcher
REM ============================================================
REM  This batch file auto-detects the project folder, installs
REM  any missing gems, and runs the scraper. It handles paths
REM  with spaces and parentheses automatically.
REM ============================================================

REM Use the batch file's own directory (handles spaces and parentheses)
set "PROJECT_DIR=%~dp0"
cd /d "%PROJECT_DIR%"

REM Clear any stale PLAYWRIGHT_BROWSERS_PATH so Playwright uses its default cache
set "PLAYWRIGHT_BROWSERS_PATH="

echo ============================================================
echo  UK Planning Scraper
echo ============================================================
echo.

REM Step 1: Check that Ruby is installed
where ruby >nul 2>&1
if errorlevel 1 (
    echo ERROR: Ruby is not installed or not in your PATH.
    echo Please install Ruby 3.1+ with Devkit from:
    echo   https://rubyinstaller.org
    echo.
    pause
    exit /b 1
)

REM Step 2: Check that Node.js is installed (needed for Playwright)
where node >nul 2>&1
if errorlevel 1 (
    echo ERROR: Node.js is not installed or not in your PATH.
    echo Please install Node.js 18+ from:
    echo   https://nodejs.org
    echo.
    pause
    exit /b 1
)

REM Step 3: Ensure gems are installed
echo Checking gems...
call bundle check >nul 2>&1
if errorlevel 1 (
    echo Installing gems ^(first run only^)...
    call bundle install
    if errorlevel 1 (
        echo.
        echo ERROR: Bundle install failed. Try running manually:
        echo   bundle install
        echo.
        pause
        exit /b 1
    )
    echo Gems installed successfully.
    echo.
)

REM Step 4: Run the scraper
echo Starting scraper...
echo.
call bundle exec ruby scrape.rb

echo.
echo ============================================================
echo  Scraper finished. Results saved to the project folder.
echo ============================================================
pause
