require_relative 'lib/uk_planning_scraper'
require 'write_xlsx'

# === CONFIGURATION ===
DAYS = 3
ANAME = 'Aberdeen'
SEARCH_KEYWORDS = []
FILENAME = "planning_applications_export.xlsx"

# Authorities to scrape
# Use `.all` for all, or `.named('Breckland')` for one, or comma-separated list
authorities = Array(UKPlanningScraper::Authority.named(ANAME))

# === SETUP EXCEL ===
workbook = WriteXLSX.new(FILENAME)
worksheet = workbook.add_worksheet

HEADERS = [
  'Authority Name', 'Council Reference', 'Date Received', 'Date Validated',
  'Status', 'Decision', 'Date Decision', 'Info URL', 'Address',
  'Description', 'Documents Count', 'Documents URL',
  'Alternative Reference', 'Appeal Status', 'Appeal Decision'
]

HEADERS.each_with_index { |header, col| worksheet.write(0, col, header) }

row = 1

# === SCRAPE & WRITE ===
authorities.each do |authority|
  begin
    puts "Scraping: #{authority.name} (#{authority.system})..."

    # Chain keyword search and date filter
    authority.validated_days(DAYS)
    SEARCH_KEYWORDS.each { |kw| authority.keywords(kw) }

    apps = Array(authority.scrape)

    puts "  → #{apps.size} applications found."

    apps.each do |app|
      worksheet.write(row, 0,  app[:authority_name] || authority.name)
      worksheet.write(row, 1,  app[:council_reference])
      worksheet.write(row, 2,  app[:date_received]&.to_s)
      worksheet.write(row, 3,  app[:date_validated]&.to_s)
      worksheet.write(row, 4,  app[:status])
      worksheet.write(row, 5,  app[:decision])
      worksheet.write(row, 6,  app[:date_decision]&.to_s)
      worksheet.write(row, 7,  app[:info_url])
      worksheet.write(row, 8,  app[:address])
      worksheet.write(row, 9,  app[:description])
      worksheet.write(row, 10, app[:documents_count])
      worksheet.write(row, 11, app[:documents_url])
      worksheet.write(row, 12, app[:alternative_reference])
      worksheet.write(row, 13, app[:appeal_status])
      worksheet.write(row, 14, app[:appeal_decision])
      row += 1
    end

  rescue => e
    puts "❌ Error scraping #{authority.name}: #{e.class} - #{e.message}"
    next
  end
end

workbook.close
puts "✅ Done! Exported to #{FILENAME}"
