require_relative 'lib/uk_planning_scraper'
require 'pp'
require 'fileutils'
require_relative 'lib/uk_planning_scraper/postprocess'
require 'playwright'
require 'open3'
ENV.delete('PLAYWRIGHT_BROWSERS_PATH')

# Auto-install Chromium using the same CLI the gem uses
def ensure_browser!
  cli = Playwright::CLI_EXECUTABLE_PATH
  if Gem.win_platform?
    stdout, status = Open3.capture2e("\"#{cli}\" install chromium 2>&1")
  else
    stdout, status = Open3.capture2e("node \"#{cli}\" install chromium 2>&1")
  end
  puts stdout
  unless status.success?
    puts "Failed to install Chromium. Run manually: npx playwright install chromium"
    exit 1
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