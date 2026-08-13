require_relative 'lib/uk_planning_scraper/playwright_compat'
require 'pp'
require 'fileutils'
require_relative 'lib/uk_planning_scraper/postprocess'
ENV.delete('PLAYWRIGHT_BROWSERS_PATH')

def ensure_browser!
  cli = Playwright::CLI_EXECUTABLE_PATH
  puts "Ensuring Chromium is installed..."
  puts "(This downloads ~150MB on first run — please be patient)"
  puts ""

  args = ['node', cli, 'install', 'chromium']

  success = system(*args)
  unless success
    puts ""
    puts "Failed to install Chromium. Run manually: npx playwright-core install chromium"
    exit 1
  end
  puts ""
  puts "Chromium is ready."
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