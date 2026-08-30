ENV.delete('PLAYWRIGHT_BROWSERS_PATH')
require_relative 'lib/uk_planning_scraper/playwright_compat'
require 'pp'
require 'fileutils'
require 'timeout'
require_relative 'lib/uk_planning_scraper'
require_relative 'lib/uk_planning_scraper/servlet'
require_relative 'lib/uk_planning_scraper/postprocess'

# Playwright::ensure_browser! already ran at require time via playwright_compat.rb.
# It handles chromium, chromium-headless-shell, and winldd downloads + symlinks.
# No need for a duplicated local ensure_browser! here.

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