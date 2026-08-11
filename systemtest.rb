# frozen_string_literal: true
# System-wide smoke-test scraper *with optional Excel export and postprocessing*
#   * Scrape one system (eg. "idox", "arcus") or ALL
#   * Set DAYS via env (default 30)
#   * Toggle excel export with EXPORT_EXCEL=yes
#   * Toggle postprocessing with POSTPROCESS=yes
#   * Guards against the classic "validated_days must be an Integer" bug

require_relative 'lib/uk_planning_scraper'
require 'fileutils'

SYSTEM_NAME     = (ENV['SYSTEM']        || 'Advancedsearch').downcase.strip  # "idox", "arcus", etc. or "all"
DAYS            = (ENV['DAYS']          || 14).to_i
EXPORT_TO_XLSX  = (ENV['EXPORT_EXCEL']  || 'y').match?(/^(y|1|true)$/i)
DO_POSTPROCESS  = (ENV['POSTPROCESS']   || 'y').match?(/^(y|1|true)$/i)

print "Enter keyword(s) to search (leave blank for none): "
KEYWORDS = gets.strip
KEYWORDS = nil if KEYWORDS.empty?
raise ArgumentError, 'DAYS must be > 0' if DAYS <= 0

# --------------------------- Excel setup ---------------------------
if EXPORT_TO_XLSX
  require 'write_xlsx'
  FILENAME  = ENV['XLSX_FILE'] || 'planning_applications_export.xlsx'
  workbook  = WriteXLSX.new(FILENAME)
  worksheet = workbook.add_worksheet
  HEADERS = [
    'Authority Name', 'Council Reference', 'Date Received',
    'Status', 'Decision', 'Info URL', 'Address',
    'Description', 'Documents Count', 'Documents URL'
  ]
  HEADERS.each_with_index { |h, col| worksheet.write(0, col, h) }
  xls_row = 1
end

# --------------------------- SELECT AUTHORITIES ---------------------------
all = UKPlanningScraper::Authority.all
authorities = if SYSTEM_NAME == 'all'
  all
else
  all.select { |a| a.system.to_s.strip.downcase == SYSTEM_NAME }
end.sort_by(&:name)

puts "Scraping #{authorities.size} authorities using #{SYSTEM_NAME == 'all' ? 'all systems' : SYSTEM_NAME.capitalize}…"

total_apps = 0
all_results = []

authorities.each do |authority|
  begin
    puts "\n==> Scraping: #{authority.name} (#{authority.system})"
    authority.validated_days(DAYS)
    apps = Array(authority.scrape)
    total_apps += apps.size
    all_results.concat(apps)
    puts "✅ Done: #{apps.size} applications found."

    # --- optional Excel dump ---
    if EXPORT_TO_XLSX && !apps.empty?
      apps.each do |app|
        worksheet.write(xls_row, 0,  app[:authority_name] || authority.name)
        worksheet.write(xls_row, 1,  app[:council_reference])
        worksheet.write(xls_row, 2,  app[:date_received]&.to_s)
        worksheet.write(xls_row, 3,  app[:date_validated]&.to_s)
        worksheet.write(xls_row, 4,  app[:status])
        worksheet.write(xls_row, 5,  app[:decision])
        worksheet.write(xls_row, 6,  app[:date_decision]&.to_s)
        worksheet.write(xls_row, 7,  app[:info_url])
        worksheet.write(xls_row, 8,  app[:address])
        worksheet.write(xls_row, 9,  app[:description])
        worksheet.write(xls_row,10,  app[:documents_count])
        worksheet.write(xls_row,11,  app[:documents_url])
        worksheet.write(xls_row,12,  app[:alternative_reference])
        worksheet.write(xls_row,13,  app[:appeal_status])
        worksheet.write(xls_row,14,  app[:appeal_decision])
        xls_row += 1
      end
    end
  rescue => e
    puts "❌ Error scraping #{authority.name}: #{e.class} - #{e.message}"
  end
end

workbook&.close if EXPORT_TO_XLSX

puts "\nTOTAL applications scraped from #{authorities.size} authorities: #{total_apps}"

# --------------------------- Optional PostProcessing ---------------------------
if DO_POSTPROCESS && !all_results.empty?
  begin
    require_relative 'lib/uk_planning_scraper/postprocess'
    FileUtils.mkdir_p(File.join(__dir__, 'data'))
    db_path = File.join(__dir__, 'data', 'apps.db')

    puts "\n=== Running PostProcess ==="
    summary = UKPlanningScraper::PostProcess.run(all_results, mode: :sqlite, db_path: db_path)
    puts "PostProcess summary:"
    puts summary.inspect
  rescue => e
    puts "⚠️ PostProcess failed: #{e.class} - #{e.message}"
  end
else
    puts "⏭️ Skipping PostProcess (disabled or no results)."
end

puts "\nSystem scrape complete."
