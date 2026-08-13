@echo off
cd /d "%~dp0"

REM Clear any stale PLAYWRIGHT_BROWSERS_PATH so Playwright uses its default cache
set PLAYWRIGHT_BROWSERS_PATH=

REM Step 1: Ensure gems are installed and updated to pinned versions
echo Checking gems...
call bundle check >nul 2>&1
if errorlevel 1 (
    echo Installing gems...
    call bundle install
)
echo Ensuring playwright-ruby-client is pinned to 1.52.0...
call bundle update playwright-ruby-client --quiet

REM Step 2: Delete any mismatched browser cache (chromium-1076 vs chromium-1200)
REM scrape.rb will auto-install the correct revision on startup.
if exist "%USERPROFILE%\AppData\Local\ms-playwright\chromium-1076" (
    echo Found stale chromium-1076 cache. Removing...
    rmdir /s /q "%USERPROFILE%\AppData\Local\ms-playwright\chromium-1076"
)

REM Step 3: Run the scraper (it will auto-install the correct Chromium)
echo Starting scraper...
call bundle exec ruby scrape.rb
pause
