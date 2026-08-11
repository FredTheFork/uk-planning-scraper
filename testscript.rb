# frozen_string_literal: true
# Utest.rb – Ultimate Scraper Test Runner with Excel export + keyword support
# Run with: ruby Utest.rb

require_relative 'lib/uk_planning_scraper'
require 'write_xlsx'

# ======================= CONFIGURATION =======================
# Choose your scraping parameters here:

SYSTEM_NAME    = 'systemni'        # "idox", "arcus", "randoms1", "all", etc.
DAYS           = 7             # validated_days back from today
EXPORT_TO_XLSX = true          # true/false → write Excel export
FILENAME       = "planning_applications_export.xlsx"

# Optionally restrict to a single authority (set to nil for all)
SINGLE_AUTHORITY = nil          # e.g. "Aberdeen" or nil

# Optional keywords (only systems that support keywords will use these)
SEARCH_KEYWORDS = ["wooden", "window"]
# =============================================================


# --------------------------- Excel setup ---------------------------
workbook  = nil
worksheet = nil
xls_row   = 1

if EXPORT_TO_XLSX
  workbook  = WriteXLSX.new(FILENAME)
  worksheet = workbook.add_worksheet
  HEADERS = [
    'Authority Name', 'Council Reference', 'Date Received', 'Date Validated',
    'Status', 'Decision', 'Date Decision', 'Info URL', 'Address',
    'Description', 'Documents Count', 'Documents URL',
    'Alternative Reference', 'Appeal Status', 'Appeal Decision'
  ]
  HEADERS.each_with_index { |h, col| worksheet.write(0, col, h) }
end


# --------------------------- SELECT AUTHORITIES ---------------------------
all = UKPlanningScraper::Authority.all

authorities =
  if SINGLE_AUTHORITY
    Array(UKPlanningScraper::Authority.named(SINGLE_AUTHORITY))
  elsif SYSTEM_NAME == 'all'
    all
  else
    all.select { |a| a.system.to_s.strip.downcase == SYSTEM_NAME }
  end.sort_by(&:name)

puts "Scraping #{authorities.size} authorities using #{SYSTEM_NAME == 'all' ? 'all systems' : SYSTEM_NAME.capitalize}…"

total_apps = 0

# --------------------------- MAIN SCRAPE LOOP ---------------------------
authorities.each do |authority|
  begin
    puts "\n==> Scraping: #{authority.name} (#{authority.system})"
    authority.validated_days(DAYS)

    # Apply keywords (if system supports it)
    SEARCH_KEYWORDS.each do |kw|
      authority.keywords(kw) if authority.respond_to?(:keywords)
    end

    apps = Array(authority.scrape)
    total_apps += apps.size
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
    puts e.backtrace.first
    next
  end
end

workbook&.close if EXPORT_TO_XLSX

puts "\nTOTAL applications scraped from #{authorities.size} authorities: #{total_apps}"
puts "System scrape complete."
