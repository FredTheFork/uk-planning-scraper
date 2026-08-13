#!/usr/bin/env ruby
# frozen_string_literal: true

# ============================================================
#  UK Planning Scraper - Master Runner (scrape.rb)
# ============================================================
# Unset any bad PLAYWRIGHT_BROWSERS_PATH so Playwright uses its default
# cache (e.g. %USERPROFILE%\AppData\Local\ms-playwright on Windows).
ENV.delete('PLAYWRIGHT_BROWSERS_PATH')

# ------------------------------------------------------------
# PRE-FLIGHT: Ensure Playwright Chromium browser is installed
# ------------------------------------------------------------
require 'open3'

def ensure_playwright_browser!
  cli = File.expand_path('node_modules/.bin/playwright', __dir__)
  cli = "#{cli}.cmd" if Gem.win_platform? && File.file?("#{cli}.cmd")

  unless File.file?(cli)
    puts "❌ Playwright CLI not found at #{cli}"
    puts "   Run:  npm install"
    exit 1
  end

  # Check if Chromium is already installed by asking the CLI for its browser path.
  # `playwright install --dry-run chromium` exits 0 if installed, non-zero if not.
  puts "Checking Playwright Chromium installation..."
  cmd = Gem.win_platform? ? "\"#{cli}\"" : cli
  stdout, status = Open3.capture2e("#{cmd} install --dry-run chromium 2>&1")

  if status.success?
    puts "✔️ Playwright Chromium is installed."
    return
  end

  puts "Playwright Chromium not found. Installing now (one-time ~150MB download)..."
  stdout, status = Open3.capture2e("#{cmd} install chromium 2>&1")
  if status.success?
    puts "✔️ Playwright Chromium installed successfully."
  else
    puts "❌ Failed to install Playwright Chromium:"
    puts stdout
    puts "   Try manually:  npx playwright install chromium"
    exit 1
  end
end

ensure_playwright_browser!

require_relative 'lib/uk_planning_scraper/postprocess'

require_relative 'lib/uk_planning_scraper/authority'
require_relative 'lib/uk_planning_scraper/application'
require_relative 'lib/uk_planning_scraper/authority_scrape_params'
require_relative 'lib/uk_planning_scraper/randoms1'
require_relative 'lib/uk_planning_scraper/randoms2'
require_relative 'lib/uk_planning_scraper/randoms3'
require_relative 'lib/uk_planning_scraper/idox'
require_relative 'lib/uk_planning_scraper/advancedsearch'
require_relative 'lib/uk_planning_scraper/agileplanning'
require_relative 'lib/uk_planning_scraper/agileapps'
require_relative 'lib/uk_planning_scraper/ocella'
require_relative 'lib/uk_planning_scraper/arcus'
require_relative 'lib/uk_planning_scraper/northgate'
require_relative 'lib/uk_planning_scraper/northgate_es'
require_relative 'lib/uk_planning_scraper/servlet'
require_relative 'lib/uk_planning_scraper/systemni'

require 'csv'
require 'time'

DAYS = 7
AUTHORITIES_CSV = File.join(__dir__, 'lib/uk_planning_scraper/authorities.csv')
RETRY_CSV = File.join(__dir__, 'retry_authorities .csv')

# ------------------------------------------------------------
# LOAD AUTHORITIES
# ------------------------------------------------------------

authorities = []
CSV.foreach(AUTHORITIES_CSV, headers: true) do |row|
  name = row['authority_name']&.strip
  url  = row['url']&.strip
  tags = row['tags']&.strip
  next unless name && url
  authorities << { name: name, url: url, tags: tags }
end

puts "============================================================"
puts "UK Planning Scraper — Full Authority Run"
puts "Scraping last #{DAYS} days"
puts "Loaded #{authorities.size} authorities from CSV"
puts "============================================================"

# ------------------------------------------------------------
# HELPER: scrape one authority safely
# ------------------------------------------------------------
def scrape_authority(auth)
  name = auth[:name]
  url  = auth[:url]
  tag  = auth[:tags]

  puts "\n==> Scraping: #{name}"
  puts "    #{url}"
  puts "    Tag: #{tag || 'none'}"

  begin
    applications = []

    # --------------------------------------------------------
    # RANDOMS (tag-based dispatch)
    # --------------------------------------------------------
    if tag == 'randoms1'
      puts "Using Randoms1 scraper for #{name}"
      authority_obj = UKPlanningScraper::Authority.named(name)
      authority_obj.validated_days(DAYS)
      applications = authority_obj.scrape

    elsif tag == 'randoms2'
      puts "Using Randoms2 scraper for #{name}"
      authority_obj = UKPlanningScraper::Authority.named(name)
      authority_obj.validated_days(DAYS)
      applications = authority_obj.scrape

    elsif tag == 'randoms3'
      puts "Using Randoms3 scraper for #{name}"
      authority_obj = UKPlanningScraper::Authority.named(name)
      authority_obj.validated_days(DAYS)
      applications = authority_obj.scrape

    else
      # --------------------------------------------------------
      # STANDARD SYSTEMS
      # --------------------------------------------------------
      authority_obj = UKPlanningScraper::Authority.new(name, url)
      authority_obj.validated_days(DAYS)
      applications = authority_obj.scrape
    end

    puts "✅ Scraped #{applications.size} applications from #{name}"
    { applications: applications, failed: false }

  rescue => e
    puts "❌ Scrape failed for #{name}: #{e.class} - #{e.message}"
    puts e.backtrace.first
    { applications: [], failed: true, error: e }
  end
end

# ------------------------------------------------------------
# MAIN LOOP
# ------------------------------------------------------------

start_time = Time.now
total_scraped = 0
all_results = []
failed_authorities = []

authorities.each_with_index do |auth, i|
  puts "\n------------------------------------------------------------"
  puts "[#{i + 1}/#{authorities.size}] #{auth[:name]}"
  puts "------------------------------------------------------------"

  result = scrape_authority(auth)
  apps = result[:applications]
  total_scraped += apps.size
  all_results.concat(apps)

  failed_authorities << auth if result[:failed]

  puts "Saved #{apps.size} applications from #{auth[:name]}"
  puts "Running total: #{total_scraped}"
end

# ------------------------------------------------------------
# RETRY FAILED AUTHORITIES
# ------------------------------------------------------------

if failed_authorities.any?
  puts "\n============================================================"
  puts "Detected #{failed_authorities.size} authorities with scraping errors — writing to retry CSV..."
  puts "============================================================"

  CSV.open(RETRY_CSV, 'w') do |csv|
    csv << ['authority_name', 'url', 'tags']
    failed_authorities.each do |auth|
      csv << [auth[:name], auth[:url], auth[:tags]]
    end
  end

  puts "✅ Wrote retry CSV: #{RETRY_CSV}"

  retry_authorities = []
  CSV.foreach(RETRY_CSV, headers: true) do |row|
    name = row['authority_name']&.strip
    url  = row['url']&.strip
    tags = row['tags']&.strip
    next unless name && url
    retry_authorities << { name: name, url: url, tags: tags }
  end

  puts "\n============================================================"
  puts "Retrying #{retry_authorities.size} authorities..."
  puts "============================================================"

  retry_authorities.each_with_index do |auth, i|
    puts "\n------------------------------------------------------------"
    puts "[Retry #{i + 1}/#{retry_authorities.size}] #{auth[:name]}"
    puts "------------------------------------------------------------"

    result = scrape_authority(auth)
    apps = result[:applications]
    total_scraped += apps.size
    all_results.concat(apps)

    puts "Saved #{apps.size} applications from #{auth[:name]} (retry)"
    puts "Running total: #{total_scraped}"
  end
end

summary = UKPlanningScraper::PostProcess.run(
  all_results,
  mode: :sqlite,
  db_path: File.join(__dir__, 'data', 'apps.db')
)
puts "PostProcess summary: #{summary.inspect}"

elapsed = (Time.now - start_time).round(1)
puts "\n============================================================"
puts "🏁  Scrape complete!"
puts "🕒  Duration: #{elapsed} seconds"
puts "📈  Total applications scraped: #{total_scraped}"
puts "============================================================"

output_path = File.join(__dir__, "scrape_results_#{Time.now.strftime('%Y%m%d_%H%M%S')}.csv")
CSV.open(output_path, 'w') do |csv|
  csv << %w[
    authority_name council_reference date_received date_validated
    status decision date_decision info_url address description
    documents_count documents_url alternative_reference
    appeal_status appeal_decision
  ]
  all_results.each do |app|
    csv << [
      app.authority_name, app.council_reference,
      app.date_received, app.date_validated, app.status,
      app.decision, app.date_decision, app.info_url, app.address,
      app.description, app.documents_count, app.documents_url,
      app.alternative_reference, app.appeal_status, app.appeal_decision
    ]
  end
end

puts "🗂️  Results exported to: #{output_path}"
puts "============================================================"