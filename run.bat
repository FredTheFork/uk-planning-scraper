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

REM Step 1b: Verify playwright-ruby-client matches Node playwright version
echo Checking Playwright version alignment...
for /f "delims=" %%v in ('npx playwright --version 2^>nul') do set NODE_PW_VERSION=%%v
for /f "delims=" %%v in ('call bundle show playwright-ruby-client 2^>nul ^| findstr /R "playwright-ruby-client"') do set RUBY_PW_GEM=%%v
echo   Node Playwright:    %NODE_PW_VERSION%
echo   Ruby Playwright gem: %RUBY_PW_GEM%
echo.
echo If versions do not match, edit Gemfile to pin playwright-ruby-client
echo to the exact Node version, then run: bundle update playwright-ruby-client
echo.

REM Step 2: Ensure Playwright Chromium is installed (skip if already present)
if not exist "%USERPROFILE%\AppData\Local\ms-playwright\chromium-*" (
    echo Installing Playwright Chromium...
    call npx playwright install chromium
) else (
    echo Playwright Chromium already cached.
)

REM Step 3: Run the scraper
echo Starting scraper...
call bundle exec ruby scrape.rb
pause
