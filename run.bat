@echo off
cd /d "%~dp0"

REM Clear any stale PLAYWRIGHT_BROWSERS_PATH so Playwright uses its default cache
set PLAYWRIGHT_BROWSERS_PATH=

REM Step 1: Ensure gems are installed (skip if already present)
call bundle check >nul 2>&1
if errorlevel 1 (
    echo Installing gems...
    call bundle install
)

REM Step 2: Ensure Playwright Chromium is installed (skip if already present)
if not exist "%USERPROFILE%\AppData\Local\ms-playwright\chromium-*" (
    echo Installing Playwright Chromium...
    call npx playwright install chromium
)

REM Step 3: Run the scraper
echo Starting scraper...
call bundle exec ruby scrape.rb
pause
