@echo off
setlocal enableextensions enabledelayedexpansion

REM ============================================================
REM  UK Planning Scraper - One-Click Launcher
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

REM Step 3: Run the scraper
echo Starting scraper...
echo.

REM Use bundle exec if a Gemfile.lock exists, otherwise plain ruby
if exist "Gemfile.lock" (
    call bundle exec ruby scrape.rb
    if errorlevel 1 (
        echo.
        echo Bundle exec failed, trying plain ruby...
        echo.
        ruby scrape.rb
    )
) else (
    ruby scrape.rb
)

echo.
echo ============================================================
echo  Scraper finished. Results saved to the project folder.
echo ============================================================
pause
