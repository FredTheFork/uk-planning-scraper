#!/usr/bin/env ruby
# frozen_string_literal: true
#
# sync_to_fenora.rb
#
# Usage:
#   FENORA_SYNC_KEY="your-secret-key" \
#     ruby sync_to_fenora.rb --db data/apps.db --batch 50 --dry-run=false
#

require 'sqlite3'
require 'net/http'
require 'json'
require 'uri'
require 'optparse'
require 'time'
require 'logger'
require 'dotenv/load'

options = {
  db: File.join(__dir__, 'data', 'apps.db'),
  batch: 50,
  dry_run: true,
  endpoint_path: '/functions/ingestPlanningApps',
  timeout: 20
}

OptionParser.new do |o|
  o.banner = "Usage: sync_to_fenora.rb [options]"
  o.on('--db PATH', 'Path to apps.db') { |v| options[:db] = v }
  o.on('--batch N', Integer, 'Batch size (default 50)') { |v| options[:batch] = v }
  o.on('--dry-run [boolean]', 'Dry run (default true)') { |v| options[:dry_run] = v != 'false' && v != false }
  o.on('--endpoint PATH', 'REST endpoint path (default /functions/ingestPlanningApps)') { |v| options[:endpoint_path] = v }
end.parse!

logger = Logger.new($stdout)
logger.level = Logger::INFO

# ENV credentials (set these in your .env or environment)
fenora_key = ENV['FENORA_SYNC_KEY']
fenora_site = 'https://fenora.base44.app'

if fenora_key.nil? || fenora_key.empty?
  logger.fatal "Missing Fenora sync config. Please set FENORA_SYNC_KEY environment variable."
  exit 1
end

# Build Bearer auth header
bearer_auth = "Bearer #{fenora_key}"

# Read rows from apps_to_sync view
db = SQLite3::Database.new(options[:db], results_as_hash: true)
rows = db.execute('SELECT * FROM apps_to_sync;') rescue db.execute('SELECT * FROM apps;')

logger.info "Fetched #{rows.size} rows from apps_to_sync (db=#{options[:db]})"

# Transform rows to minimal payload objects
payloads = rows.map do |r|
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
    description: r['description']
  }
end

if options[:dry_run]
  logger.info "Dry run enabled — would send #{payloads.size} items in batches of #{options[:batch]} to #{fenora_site}#{options[:endpoint_path]}"
  exit 0
end

# Send batches with retry/backoff
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
      'Authorization' => bearer_auth
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

logger.info "Sync complete."