require_relative 'lib/uk_planning_scraper'
require 'pp'
require 'fileutils'
require_relative 'lib/uk_planning_scraper/postprocess'
require 'playwright'
ENV.delete('PLAYWRIGHT_BROWSERS_PATH')
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