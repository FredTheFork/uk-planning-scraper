@echo off
setlocal enableextensions

REM Use the batch file's own directory (handles spaces and parentheses)
set "PROJECT_DIR=%~dp0"
cd /d "%PROJECT_DIR%"

REM Clear any stale PLAYWRIGHT_BROWSERS_PATH
set "PLAYWRIGHT_BROWSERS_PATH="

REM Step 1: Ensure gems are installed
call bundle check >nul 2>&1
if errorlevel 1 (
    echo Installing gems...
    call bundle install
)

REM Step 2: Run the scraper (auto-installs matching playwright-core + Chromium)
echo Starting scraper...
call bundle exec ruby scrape.rb
pause
