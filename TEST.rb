require_relative 'lib/uk_planning_scraper/playwright_compat'
require 'pp'
require 'fileutils'
require 'timeout'
require_relative 'lib/uk_planning_scraper/postprocess'
ENV.delete('PLAYWRIGHT_BROWSERS_PATH')

def ensure_browser!
  cli = Playwright::CLI_EXECUTABLE_PATH

  Playwright.ensure_browser_symlinks!

  if Playwright.chromium_installed?
    puts "Chromium is already installed at:"
    puts "  #{Playwright.chromium_browser_path}"
    puts ""
    return
  end

  puts "Ensuring Chromium is installed..."
  puts "(This downloads ~150MB on first run — please be patient)"
  puts ""

  # First, try the Ruby-based download + extraction (bypasses the Node CLI
  # which hangs during zip extraction on some Windows systems).
  begin
    Playwright.install_chromium_ruby!
    Playwright.ensure_browser_symlinks!
    if Playwright.chromium_installed?
      puts ""
      puts "Chromium is ready (installed via Ruby)."
      puts "  #{Playwright.chromium_browser_path}"
      puts ""
      return
    end
  rescue => e
    puts "Ruby-based install failed: #{e.class} - #{e.message}"
    puts "Falling back to Node CLI..."
  end

  # Fallback: use the Node CLI with a polling loop
  args = ['node', Playwright.core_cli_path, 'install', 'chromium']

  pid = Process.spawn(*args)
  max_wait = 1200
  interval = 5
  waited = 0

  loop do
    sleep interval
    waited += interval

    done = Process.waitpid(pid, Process::WNOHANG)
    if done
      Playwright.ensure_browser_symlinks!
      if Playwright.chromium_installed?
        sleep 5
      end
      if Playwright.chromium_installed?
        puts ""
        puts "Chromium is ready."
        puts "  #{Playwright.chromium_browser_path}"
        puts ""
        return
      else
        puts ""
        puts "Failed to install Chromium. Run manually: npx playwright-core install chromium"
        exit 1
      end
    end

    Playwright.ensure_browser_symlinks!
    if Playwright.chromium_installed?
      puts ""
      puts "Chromium binary is ready (download completed)."
      puts "  #{Playwright.chromium_browser_path}"
      puts ""
      begin
        if Gem.win_platform?
          system("taskkill /F /T /PID #{pid}", exception: false)
        else
          Process.kill('TERM', pid)
          Process.wait(pid)
        end
      rescue
      end
      return
    end

    if waited >= max_wait
      puts ""
      puts "Install is taking longer than #{max_wait / 60} minutes..."
      begin
        if Gem.win_platform?
          system("taskkill /F /T /PID #{pid}", exception: false)
        else
          Process.kill('TERM', pid)
          Process.wait(pid)
        end
      rescue
      end

      Playwright.ensure_browser_symlinks!
      if Playwright.chromium_installed?
        puts "Chromium binary was downloaded successfully despite the timeout."
        puts "  #{Playwright.chromium_browser_path}"
        puts ""
        return
      else
        puts "Chromium install did not complete."
        puts "Try manually:  npx playwright-core install chromium"
        exit 1
      end
    end

    print "." if waited % 30 == 0
  end
end
ensure_browser!

NAME = 'Boston'
DAYS = 10
authorities = UKPlanningScraper::Authority.named(NAME)
applications = authorities.validated_days(DAYS).scrape
#UKPlanningScraper::EXCELEXPORT.export(applications)

if !applications.empty?
  begin
    FileUtils.mkdir_p(File.join(__dir__, 'data'))
    db_path = File.join(__dir__, 'data', 'apps.db')
    puts "\n=== Running PostProcess ==="
    summary = UKPlanningScraper::PostProcess.run(applications, mode: :sqlite, db_path: db_path)
    puts "PostProcess summary:"
    puts summary.inspect
  rescue => e
    puts "⚠️ PostProcess failed: #{e.class} - #{e.message}"
  end
else
  puts "⏭️ Skipping PostProcess (no results)."
end

puts "\nScrape complete."