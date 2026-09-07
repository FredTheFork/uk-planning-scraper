#!/usr/bin/env ruby
# frozen_string_literal: true
#
# sync_to_fenora.rb
#
# Syncs window/door-relevant planning applications to Fenora.
# Uses a multi-layered filter (lib/uk_planning_scraper/fenora_filter.rb)
# to ensure only genuine window, door, glazing, or joinery opportunities
# are sent.
#
# Usage:
#   FENORA_SYNC_KEY="your-secret-key" \
#     ruby sync_to_fenora.rb --db data/apps.db --batch 50 --dry-run=false
#
# Options:
#   --min-score N         Minimum Fenora relevance score to send (default 10)
#   --no-secondary        Exclude secondary leads (windows/doors in larger projects)
#   --no-uncertain        Exclude uncertain leads (borderline/vague descriptions)
#   --show-rejected       Print rejected applications and reasons
#   --export-filtered FILE  Write filtered results to CSV for review

require 'sqlite3'
require 'net/http'
require 'json'
require 'uri'
require 'optparse'
require 'time'
require 'logger'
require 'set'
require 'csv'
begin
  require 'dotenv/load'
rescue LoadError
  # dotenv gem not installed — rely on plain ENV vars
end
require_relative 'lib/uk_planning_scraper/fenora_filter'

options = {
  db: File.join(__dir__, 'data', 'apps.db'),
  batch: 50,
  dry_run: true,
  endpoint_path: '/functions/ingestPlanningApps',
  timeout: 20,
  min_score: UKPlanningScraper::FenoraFilter::KEEP_THRESHOLD,
  include_secondary: true,
  include_uncertain: true,
}

OptionParser.new do |o|
  o.banner = "Usage: sync_to_fenora.rb [options]"
  o.on('--db PATH', 'Path to apps.db') { |v| options[:db] = v }
  o.on('--batch N', Integer, 'Batch size (default 50)') { |v| options[:batch] = v }
  o.on('--dry-run [boolean]', 'Dry run (default true)') { |v| options[:dry_run] = v != 'false' && v != false }
  o.on('--endpoint PATH', 'REST endpoint path (default /functions/ingestPlanningApps)') { |v| options[:endpoint_path] = v }
  o.on('--min-score N', Integer, 'Minimum Fenora relevance score to send (default 10)') { |v| options[:min_score] = v }
  o.on('--no-secondary', 'Exclude secondary (windows/doors in larger projects)') { options[:include_secondary] = false }
  o.on('--no-uncertain', 'Exclude uncertain (borderline/vague descriptions)') { options[:include_uncertain] = false }
  o.on('--show-rejected', 'Print rejected applications and reasons') { options[:show_rejected] = true }
  o.on('--export-filtered FILE', 'Write filtered results to CSV for review') { |v| options[:export_csv] = v }
end.parse!

logger = Logger.new($stdout)
logger.level = Logger::INFO

# ENV credentials
fenora_key = ENV['FENORA_SYNC_KEY']
fenora_site = 'https://fenora.base44.app'

if fenora_key.nil? || fenora_key.empty?
  logger.fatal "Missing Fenora sync config. Please set FENORA_SYNC_KEY environment variable."
  exit 1
end

bearer_auth = "Bearer #{fenora_key}"

# ------------------------------------------------------------
# READ FROM DATABASE
# ------------------------------------------------------------

db = SQLite3::Database.new(options[:db], results_as_hash: true)
rows = db.execute('SELECT * FROM apps_to_sync;') rescue db.execute('SELECT * FROM apps;')
logger.info "Fetched #{rows.size} rows from apps_to_sync (db=#{options[:db]})"

# ------------------------------------------------------------
# FENORA RELEVANCE FILTER
# ------------------------------------------------------------

logger.info "Running Fenora window/door relevance filter..."

kept_rows = []
rejected_rows = []
stats = { relevant: 0, secondary: 0, uncertain: 0, irrelevant: 0 }

rows.each do |row|
  result = UKPlanningScraper::FenoraFilter.evaluate(
    row['description'],
    row['address'],
    row['status'],
  )

  stats[result[:category]] += 1

  should_keep = false
  if result[:keep]
    case result[:category]
    when :relevant
      should_keep = result[:score] >= options[:min_score]
    when :secondary
      should_keep = options[:include_secondary] && result[:score] >= options[:min_score]
    when :uncertain
      should_keep = options[:include_uncertain] && result[:score] >= options[:min_score]
    end
  end

  if should_keep
    enriched = row.dup
    enriched['fenora_score'] = result[:score]
    enriched['fenora_category'] = result[:category].to_s
    kept_rows << enriched
  else
    rejected_rows << {
      row: row,
      reason: result[:reason],
      score: result[:score],
      category: result[:category],
    }
  end
end

logger.info "Filter results: #{stats[:relevant]} relevant, #{stats[:secondary]} secondary, #{stats[:uncertain]} uncertain, #{stats[:irrelevant]} irrelevant"
logger.info "Sending #{kept_rows.size} applications (min_score=#{options[:min_score]}, include_secondary=#{options[:include_secondary]}, include_uncertain=#{options[:include_uncertain]})"

if options[:show_rejected] && rejected_rows.any?
  puts "\n--- Rejected applications (#{rejected_rows.size}) ---"
  rejected_rows.first(50).each do |r|
    ref = r[:row]['council_reference'] || r[:row][:council_reference] || '?'
    desc = (r[:row]['description'] || r[:row][:description] || '').to_s[0..80]
    puts "  [#{r[:score]}] #{r[:category]} #{ref}: #{desc}..."
    puts "       Reason: #{r[:reason]}"
  end
  puts "..." if rejected_rows.size > 50
end

# Optional: export filtered results to CSV for review
if options[:export_csv]
  CSV.open(options[:export_csv], 'w') do |csv|
    csv << %w[council_reference authority_name fenora_score fenora_category address description status]
    kept_rows.each do |r|
      csv << [r['council_reference'], r['authority_name'], r['fenora_score'], r['fenora_category'], r['address'], r['description']&.to_s&.[](0..200), r['status']]
    end
  end
  logger.info "Exported #{kept_rows.size} filtered applications to #{options[:export_csv]}"
end

# ------------------------------------------------------------
# TRANSFORM TO PAYLOAD
# ------------------------------------------------------------

payloads = kept_rows.map do |r|
  {
    authority_name: r['authority_name'],
    council_reference: r['council_reference'],
    info_url: r['info_url'],
    date_received: r['date_received'],
    date_validated: r['date_validated'],
    status: r['status'],
    decision: r['decision'],
    documents_url: r['documents_url'],
    address: r['address'],
    description: r['description'],
    fenora_score: r['fenora_score'],
    fenora_category: r['fenora_category'],
  }
end

if options[:dry_run]
  logger.info "Dry run enabled — would send #{payloads.size} items in batches of #{options[:batch]} to #{fenora_site}#{options[:endpoint_path]}"
  logger.info "Sample of filtered applications:"
  payloads.first(20).each do |p|
    puts "  [#{p[:fenora_score]}] #{p[:fenora_category].ljust(10)} #{p[:council_reference]}: #{p[:description]&.to_s&.[](0..80)}"
  end
  exit 0
end

# ------------------------------------------------------------
# SEND TO FENORA
# ------------------------------------------------------------

uri = URI.join(fenora_site, options[:endpoint_path])

payloads.each_slice(options[:batch]).with_index(1) do |batch, idx|
  body = { apps: batch }.to_json
  tries = 0
  begin
    tries += 1
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == 'https'
    http.read_timeout = options[:timeout]
    req = Net::HTTP::Post.new(uri.request_uri, {
      'Content-Type' => 'application/json',
      'Authorization' => bearer_auth,
    })
    req.body = body

    logger.info "Sending batch #{idx} (#{batch.size} items) to #{uri} (attempt #{tries})"
    resp = http.request(req)

    if resp.code.to_i >= 200 && resp.code.to_i < 300
      j = JSON.parse(resp.body) rescue {}
      logger.info "Batch #{idx} success: processed=#{j['processed'] || 'unknown'} errors=#{(j['errors'] || []).size}"
    else
      logger.warn "Batch #{idx} HTTP #{resp.code}: #{resp.body}"
      raise "HTTP #{resp.code}"
    end
  rescue => e
    if tries < 5
      sleep_time = 2 ** tries
      logger.warn "Batch #{idx} failed (#{e.class} - #{e}). Retrying in #{sleep_time}s..."
      sleep sleep_time
      retry
    else
      logger.error "Batch #{idx} permanently failed after #{tries} tries: #{e.class} - #{e}"
    end
  end
end

logger.info "Sync complete. Sent #{payloads.size} window/door-relevant applications to Fenora."
