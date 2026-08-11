# frozen_string_literal: true
#
# lib/uk_planning_scraper/postprocess.rb
#
# PostProcess: clean, filter, dedupe scraped Application objects and persist to SQLite.
# Adds:
#   * last_scraped_run timestamp
#   * apps_to_sync view (latest run)
#

require 'sqlite3'
require 'uri'
require 'json'
require 'set'
require 'time'
require_relative 'application'

module UKPlanningScraper
  module PostProcess
    DEFAULT_SQLITE_PATH = File.expand_path('../../../../data/apps.db', __FILE__)

    DEFAULT_EXCLUDE_PATTERNS = [
      /TPO/i,
      /\bTree Preservation\b/i,
      /\bNon[-\s]*Material\b/i,
      /\bNMA\b/i,
      /\bDischarge\b/i,
      /\bdischarge\b/i,
      /\bNon[-\s]*Material Amendment\b/i,
      /\bNon-Material-Amendment\b/i,
      /\bNon-material-amendment\b/i,
      /\bCertificate of Lawfulness\b/i,
      /\bLawful Development\b/i,
      /\bCertificate\b/i,
      /\bPrior Approval\b/i,
      /\bAdvertisement\b/i,
      /\bAdvertis/i,
      /\bvary condition\b/i,
      /\bVariation Of Condition\b/i,
      /\bvariation of condition\b/i,
      /\bWorks to a tree\b/i,
      /\bcrown\b/i,
      /\bVariation\b/i,
      /\bTelecom(?:munications)?\b.*\b(mast|pole|telecom)/i,
      /\bTEL\b/i,
      /\bAGR\b/i,
      /\bT1\b/i,
      /\bT2\b/i,
      /\bT3\b/i,
      /\b- Remove\b/i,
      /\b- Fell\b/i,
      /\bfell\b/i,
      /\cclear\b/i,
      /\bprune\b/i,
      /\bDamson\b/i,
      /\bSycamore\b/i,
      /\breduce\b/i,
      /\b- Clear\b/i,
      /\b- Reduce\b/i,
      /\breduce crown\b/i,
      /\bReduce crown\b/i,
      /\bDischarge\b/i,
    ].freeze

    DEFAULT_REQUIRE_FIELDS = %i[authority_name council_reference info_url description address].freeze

    CREATE_TABLE_SQL = <<~SQL
      CREATE TABLE IF NOT EXISTS apps (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        authority_name TEXT NOT NULL,
        council_reference TEXT NOT NULL,
        info_url TEXT NOT NULL,
        scraped_at TEXT,
        date_received TEXT,
        date_validated TEXT,
        status TEXT,
        decision TEXT,
        date_decision TEXT,
        address TEXT,
        description TEXT,
        documents_count INTEGER,
        documents_url TEXT,
        alternative_reference TEXT,
        appeal_status TEXT,
        appeal_decision TEXT,
        last_scraped_run TEXT,
        UNIQUE(authority_name, council_reference)
      );
    SQL

    CREATE_INDEXES_SQL = <<~SQL
      CREATE INDEX IF NOT EXISTS idx_apps_authority_ref ON apps(authority_name, council_reference);
      CREATE INDEX IF NOT EXISTS idx_apps_last_run ON apps(last_scraped_run);
    SQL

    CREATE_VIEW_SQL = <<~SQL
      CREATE VIEW IF NOT EXISTS apps_to_sync AS
      SELECT *
      FROM apps
      WHERE last_scraped_run = (SELECT MAX(last_scraped_run) FROM apps);
    SQL

    module_function

    def run(apps, opts = {})
      opts = default_opts.merge(opts || {})
      run_time = Time.now.utc.iso8601

      puts "PostProcess: starting with #{apps.size} scraped apps at #{run_time}"

      normalized = apps.map { |a| normalize_application(a) }.compact
      puts "  → Normalized: #{normalized.size}"

      validated, invalid = validated_partition(normalized, opts[:filters][:require_fields])
      puts "  → Valid: #{validated.size}, Invalid: #{invalid.size}"

      filtered, excluded = filter_apps(validated, opts[:filters][:exclude_patterns], opts[:filters][:min_description_length])
      puts "  → Filtered: kept #{filtered.size}, excluded #{excluded.size}"

      deduped, duplicates = dedupe_apps(filtered)
      puts "  → Deduped: kept #{deduped.size}, duplicates removed #{duplicates.size}"

      store_sqlite(deduped, opts[:db_path], run_time)

      summary = {
        input_count: apps.size,
        valid_count: validated.size,
        excluded_count: excluded.size,
        deduped_count: deduped.size,
        run_time: run_time
      }

      puts "PostProcess: finished. Summary: #{summary.inspect}"
      summary
    end

    def default_opts
      {
        db_path: DEFAULT_SQLITE_PATH,
        filters: {
          exclude_patterns: DEFAULT_EXCLUDE_PATTERNS.dup,
          require_fields: DEFAULT_REQUIRE_FIELDS.dup,
          min_description_length: 20
        }
      }
    end

    # === Normalize ===
    def normalize_application(app)
      a = app.is_a?(Application) ? app.dup : Application.new.tap { |o| app.to_h.each { |k, v| o.send("#{k}=", v) if o.respond_to?("#{k}=") } }
      a.authority_name = normalize_text(a.authority_name)
      a.council_reference = normalize_text(a.council_reference)
      a.info_url = normalize_url(a.info_url)
      a.address = normalize_text(a.address)
      a.description = normalize_text(a.description)
      a.status = normalize_text(a.status)
      a.decision = normalize_text(a.decision)
      a.documents_url = normalize_text(a.documents_url)
      a.scraped_at = to_iso(a.scraped_at)
      a.date_received = normalize_date(a.date_received)
      a.date_validated = normalize_date(a.date_validated)
      a.date_decision = normalize_date(a.date_decision)
      a
    rescue => e
      warn "normalize_application failed: #{e.class} - #{e.message}"
      nil
    end

    def normalize_text(s)
      return nil if s.nil?
      s = s.to_s.encode('UTF-8', invalid: :replace, undef: :replace, replace: '')
      s = s.gsub(/\u00A0/, ' ').gsub(/[[:cntrl:]]+/, ' ')
      s = s.gsub(/\s+/, ' ').strip
      s.empty? ? nil : s
    end

    def normalize_url(u)
      return nil if u.nil? || u.to_s.strip.empty?
      uri = URI.parse(u) rescue nil
      uri ? uri.to_s : u.to_s.strip
    end

    def normalize_date(d)
      return nil if d.nil?
      s = d.to_s.strip
      return nil if s.empty?
      Date.strptime(s, '%d-%m-%Y') rescue Date.strptime(s, '%d/%m/%Y') rescue Date.iso8601(s) rescue Date.parse(s) rescue nil
    rescue
      nil
    end

    def to_iso(obj)
      return obj if obj.is_a?(String)
      obj&.respond_to?(:iso8601) ? obj.iso8601 : obj.to_s
    end

    # === Validation / Filtering / Deduplication ===
    def validated_partition(apps, require_fields)
      valid, invalid = [], []
      apps.each do |a|
        ok = require_fields.all? { |f| val = a.send(f) rescue nil; val && !val.to_s.strip.empty? }
        (ok ? valid : invalid) << a
      end
      [valid, invalid]
    end

    def filter_apps(apps, exclude_patterns, min_len)
      kept, excluded = [], []
      apps.each do |a|
        reason = if a.description.nil? || a.description.length < min_len
                   :short_description
                 elsif a.status&.match?(/withdrawn|refused|invalid/i)
                   :status_excluded
                 elsif exclude_patterns.any? { |rx| rx.match?(a.description.to_s) || rx.match?(a.council_reference.to_s) || rx.match?(a.address.to_s) }
                   :pattern_excluded
                 end
        reason ? excluded << { app: a, reason: reason } : kept << a
      end
      [kept, excluded]
    end

    def dedupe_apps(apps)
      kept_map, duplicates = {}, []
      apps.each do |a|
        key = "#{a.authority_name}||#{a.council_reference}"
        if kept_map[key]
          existing = kept_map[key]
          winner = prefer_application(existing, a)
          duplicates << { kept: winner, removed: (winner == existing ? a : existing) }
          kept_map[key] = winner
        else
          kept_map[key] = a
        end
      end
      [kept_map.values, duplicates]
    end

    def prefer_application(a, b)
      return a if a.date_received && !b.date_received
      return b if b.date_received && !a.date_received
      return a if (a.description || '').length >= (b.description || '').length
      b
    end

    # === SQLite Storage ===
    def store_sqlite(apps, db_path, run_time)
      Dir.mkdir(File.dirname(db_path)) unless Dir.exist?(File.dirname(db_path))
      puts "Persisting #{apps.size} apps to SQLite DB: #{db_path}"

      db = SQLite3::Database.new(db_path)
      db.execute_batch(CREATE_TABLE_SQL)

      # Ensure column exists for old DBs
      cols = db.execute("PRAGMA table_info(apps);").map { |r| r[1] }
      unless cols.include?('last_scraped_run')
        db.execute("ALTER TABLE apps ADD COLUMN last_scraped_run TEXT;")
      end

      db.execute_batch(CREATE_INDEXES_SQL)
      db.transaction
      insert_sql = <<~SQL
        INSERT OR REPLACE INTO apps (
          authority_name, council_reference, info_url, scraped_at,
          date_received, date_validated, status, decision, date_decision,
          address, description, documents_count, documents_url,
          alternative_reference, appeal_status, appeal_decision,
          last_scraped_run
        ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);
      SQL
      stmt = db.prepare(insert_sql)

      apps.each do |a|
        stmt.execute(
          a.authority_name, a.council_reference, a.info_url, a.scraped_at,
          a.date_received&.to_s, a.date_validated&.to_s, a.status, a.decision, a.date_decision&.to_s,
          a.address, a.description, a.documents_count, a.documents_url,
          a.alternative_reference, a.appeal_status, a.appeal_decision,
          run_time
        )
      end

      db.commit
      db.execute_batch(CREATE_VIEW_SQL)
      puts "SQLite: commit successful. View apps_to_sync updated."
    rescue => e
      db.rollback rescue nil
      warn "SQLite store failed: #{e.class} - #{e.message}"
      raise
    ensure
      stmt&.close
      db&.close
    end
  end
end
