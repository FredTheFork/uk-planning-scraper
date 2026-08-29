#!/usr/bin/env ruby
# frozen_string_literal: true

# ============================================================
#  UK Planning Scraper - Master Runner (scrape.rb)
# ============================================================
# Unset any bad PLAYWRIGHT_BROWSERS_PATH so Playwright uses its default
# cache (e.g. %USERPROFILE%\AppData\Local\ms-playwright on Windows).
ENV.delete('PLAYWRIGHT_BROWSERS_PATH')

# Load Playwright compatibility layer early (defines CLI_EXECUTABLE_PATH)
require_relative 'lib/uk_planning_scraper/playwright_compat'

# ------------------------------------------------------------
# PRE-FLIGHT: Ensure Playwright Chromium browser is installed
# ------------------------------------------------------------
require 'open3'
require 'timeout'

def ensure_playwright_browser!
  cli = Playwright::CLI_EXECUTABLE_PATH

  gem_version = Playwright.compatible_cli_version rescue 'unknown'
  installed = Playwright.installed_core_version rescue 'unknown'
  puts "Playwright version check:"
  puts "  Ruby gem needs:        playwright-core@#{gem_version}"
  puts "  Installed:             #{installed}"
  puts "  CLI path:              #{cli}"
  puts ""

  unless File.file?(cli)
    puts "Playwright CLI not found at #{cli}"
    puts "   Run:  npm install playwright-core@#{gem_version}"
    exit 1
  end

  # Skip the install entirely if Chromium is already on disk.
  if Playwright.chromium_installed?
    puts "Chromium is already installed at:"
    puts "  #{Playwright.chromium_browser_path}"
    puts ""
    return
  end

  puts "Ensuring Chromium is installed..."
  puts "(This downloads ~150MB on first run — please be patient)"
  puts ""

  args = ['node', cli, 'install', 'chromium']

  # Run the install with a timeout. The Node process can hang after download
  # completes (during extraction) due to antivirus scanning or file locks.
  # If it times out, we check whether the binary actually landed on disk —
  # if so, we proceed anyway.
  pid = Process.spawn(*args)
  timeout_seconds = 300  # 5 minutes

  begin
    Timeout.timeout(timeout_seconds) { Process.wait(pid) }
    success = $?.success?
  rescue Timeout::Error
    puts ""
    puts "Install is taking longer than #{timeout_seconds / 60} minutes..."
    begin
      if Gem.win_platform?
        system("taskkill /F /T /PID #{pid}")
      else
        Process.kill('TERM', pid)
        Process.wait(pid)
      end
    rescue
    end

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

  unless success
    if Playwright.chromium_installed?
      puts ""
      puts "Chromium is ready (install reported failure but binary exists)."
      puts "  #{Playwright.chromium_browser_path}"
      puts ""
      return
    end
    puts ""
    puts "Failed to install Chromium automatically."
    puts "Try manually:  npx playwright-core install chromium"
    exit 1
  end

  puts ""
  puts "Chromium is ready."
  puts ""
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
RETRY_CSV = File.join(__dir__, 'retry_authorities.csv')

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
    # Authority#scrape returns an array of Hashes (via to_hash), not
    # Application objects, so we use hash access with symbol keys.
    h = app.is_a?(Hash) ? app : app.to_hash
    csv << [
      h[:authority_name], h[:council_reference],
      h[:date_received], h[:date_validated], h[:status],
      h[:decision], h[:date_decision], h[:info_url], h[:address],
      h[:description], h[:documents_count], h[:documents_url],
      h[:alternative_reference], h[:appeal_status], h[:appeal_decision]
    ]
  end
end

puts "🗂️  Results exported to: #{output_path}"
puts "============================================================"