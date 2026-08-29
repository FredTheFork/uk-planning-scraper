#!/usr/bin/env ruby
# frozen_string_literal: true

# ============================================================
#  UK Planning Scraper - Master Runner (scrape.rb)
# ============================================================
# Unset any bad PLAYWRIGHT_BROWSERS_PATH so Playwright uses its default
# cache (e.g. %USERPROFILE%\AppData\Local\ms-playwright on Windows).
ENV.delete('PLAYWRIGHT_BROWSERS_PATH')

# Load Playwright compatibility layer — this automatically:
#   1. Aligns the Node playwright-core version to the gem version
#   2. Downloads Chromium if it's not already present
#   3. Creates symlinks/junctions for revision mismatches
#   4. Monkey-patches BrowserType#launch to use explicit executablePath
require_relative 'lib/uk_planning_scraper/playwright_compat'

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
require 'json'
require 'fileutils'

DAYS = 7 unless defined?(DAYS)
AUTHORITIES_CSV = File.join(__dir__, 'lib/uk_planning_scraper/authorities.csv')
RETRY_CSV = File.join(__dir__, 'retry_authorities.csv')
CHECKPOINT_FILE = File.join(__dir__, 'data', 'checkpoint.json')
DATA_DIR = File.join(__dir__, 'data')

# ------------------------------------------------------------
# STARTUP ROBUSTNESS CHECKS
# ------------------------------------------------------------

puts "============================================================"
puts "UK Planning Scraper — Full Authority Run"
puts "Scraping last #{DAYS} days"
puts "============================================================"

required_files = [
  ['cacert.pem', 'TLS certificate bundle for HTTPS requests'],
  ['lib/uk_planning_scraper/authorities.csv', 'Authority list CSV'],
  ['node_modules/playwright-core/package.json', 'Playwright Node CLI (run: npm install)'],
]

missing_files = []
required_files.each do |rel, desc|
  path = File.join(__dir__, rel)
  missing_files << "#{rel} (#{desc})" unless File.file?(path)
end

if missing_files.any?
  puts "❌ Missing required files:"
  missing_files.each { |f| puts "   - #{f}" }
  puts ""
  puts "Please ensure all project files are present before running."
  exit 1
end

FileUtils.mkdir_p(DATA_DIR) unless File.directory?(DATA_DIR)

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

puts "Loaded #{authorities.size} authorities from CSV"

# Validate system detection and warn about unknown systems
unknown_systems = []
authorities.each do |auth|
  obj = UKPlanningScraper::Authority.new(auth[:name], auth[:url])
  unknown_systems << auth[:name] if obj.system == 'unknownsystem'
end

if unknown_systems.any?
  puts "⚠️  #{unknown_systems.size} authorities have unknown system types:"
  unknown_systems.first(10).each { |n| puts "   - #{n}" }
  puts "   ..." if unknown_systems.size > 10
end

# ------------------------------------------------------------
# CHECKPOINT / RESUME LOGIC
# ------------------------------------------------------------

resume_mode = ARGV.include?('--resume')

checkpoint = nil
if resume_mode && File.file?(CHECKPOINT_FILE)
  begin
    checkpoint = JSON.parse(File.read(CHECKPOINT_FILE))
    puts "📂 Resuming from checkpoint: #{checkpoint['completed_count']} authorities already done"
  rescue => e
    puts "⚠️  Could not read checkpoint file: #{e.message}"
    checkpoint = nil
  end
end

def save_checkpoint(file, data)
  File.write(file, JSON.pretty_generate(data))
rescue => e
  warn "⚠️  Could not save checkpoint: #{e.message}"
end

completed_authorities = if checkpoint
  checkpoint['completed_authorities'] || []
else
  []
end

if resume_mode && completed_authorities.any?
  original_count = authorities.size
  authorities = authorities.reject { |a| completed_authorities.include?(a[:name]) }
  puts "📋 Skipping #{original_count - authorities.size} already-completed authorities"
end

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
# HELPER: save results to SQLite incrementally
# ------------------------------------------------------------
def save_results_incremental(apps, db_path)
  return if apps.empty?
  begin
    app_objects = apps.map do |app|
      if app.is_a?(UKPlanningScraper::Application)
        app
      elsif app.is_a?(Hash)
        a = UKPlanningScraper::Application.new
        a.scraped_at            = app[:scraped_at]
        a.authority_name        = app[:authority_name]
        a.council_reference     = app[:council_reference]
        a.date_received         = app[:date_received]
        a.date_validated        = app[:date_validated]
        a.status                = app[:status]
        a.decision              = app[:decision]
        a.date_decision         = app[:date_decision]
        a.info_url              = app[:info_url]
        a.address               = app[:address]
        a.description           = app[:description]
        a.documents_count       = app[:documents_count]
        a.documents_url         = app[:documents_url]
        a.alternative_reference = app[:alternative_reference]
        a.appeal_status         = app[:appeal_status]
        a.appeal_decision       = app[:appeal_decision]
        a
      end
    end.compact

    UKPlanningScraper::PostProcess.run(
      app_objects,
      mode: :sqlite,
      db_path: db_path
    )
  rescue => e
    warn "⚠️  Incremental save failed: #{e.class} - #{e.message}"
  end
end

# ------------------------------------------------------------
# MAIN LOOP
# ------------------------------------------------------------

start_time = Time.now
total_scraped = 0
all_results = []
failed_authorities = []

db_path = File.join(DATA_DIR, 'apps.db')

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

  # Save results incrementally to SQLite
  save_results_incremental(apps, db_path)

  # Update checkpoint
  completed_authorities << auth[:name] unless completed_authorities.include?(auth[:name])
  save_checkpoint(CHECKPOINT_FILE, {
    'completed_authorities' => completed_authorities,
    'completed_count' => completed_authorities.size,
    'total_scraped' => total_scraped,
    'last_updated' => Time.now.iso8601,
    'last_authority' => auth[:name]
  })
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

    save_results_incremental(apps, db_path)

    puts "Saved #{apps.size} applications from #{auth[:name]} (retry)"
    puts "Running total: #{total_scraped}"
  end
end

# Final PostProcess run for the complete batch
summary = UKPlanningScraper::PostProcess.run(
  all_results,
  mode: :sqlite,
  db_path: db_path
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

# Clean up checkpoint on successful completion
if File.file?(CHECKPOINT_FILE)
  File.delete(CHECKPOINT_FILE)
  puts "🧹 Checkpoint cleared."
end

puts "============================================================"
