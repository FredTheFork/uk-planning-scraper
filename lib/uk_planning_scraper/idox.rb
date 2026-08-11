# frozen_string_literal: true
require 'addressable/uri'
require 'mechanize'
require 'openssl'
require 'set'
require 'pp'
require 'timeout'

module UKPlanningScraper
  class Authority
    private
    keywords = 'wooden window'
    ######################################################################
    # scrape_idox – PublicAccess / Idox
    # ------------------------------------------------------------------
    # * First try with full TLS verification (secure agent).
    # * If the host’s cert chain is broken we fall back to a host‑scoped
    #   `VERIFY_NONE` agent.  We remember each problematic host so the
    #   warning appears **only once per run & per host**.  Set the env‑var
    #   `IDOX_TLS_VERBOSE=1` if you actually want to see those warnings.
    ######################################################################

    # global registries shared across Authority instances
    @@insecure_hosts    = Set.new        # hosts already demoted to VERIFY_NONE
    @@insecure_agents   = {}             # host → cached insecure Mechanize
    @@warned_hosts      = Set.new        # hosts we have displayed a warning for
    TLS_VERBOSE         = ENV['IDOX_TLS_VERBOSE'] == '1'

    # helper ─ fetch with retry / host‑scoped VERIFY_NONE
    def fetch_page(url, secure_agent)
      host = URI(url).host

      # Short‑circuit if this host is known-broken
      if @@insecure_hosts.include?(host)
        return (@@insecure_agents[host] ||= build_insecure_agent(secure_agent)).get(url)
      end

      # optimistic secure fetch
      secure_agent.get(url)
    rescue OpenSSL::SSL::SSLError => e
      unless @@warned_hosts.include?(host)
        puts "⚠️  TLS validation failed for #{host} – falling back to VERIFY_NONE (insecure)" if TLS_VERBOSE
        @@warned_hosts << host
      end
      @@insecure_hosts << host
      (@@insecure_agents[host] ||= build_insecure_agent(secure_agent)).get(url)
    rescue Mechanize::ResponseCodeError => e
      warn "HTTP error: #{e.response_code} – skipping #{url}"
      return nil
    rescue SocketError, StandardError => e
      warn "⚠️  Failed to fetch #{url}: #{e.class} – #{e.message}"
      return nil
    end

    # Build a VERIFY_NONE agent, cloning only the UA string
    def build_insecure_agent(template)
      mech = Mechanize.new
      mech.verify_mode = OpenSSL::SSL::VERIFY_NONE
      if (ua = template.request_headers['User-Agent'])
        mech.request_headers['User-Agent'] = ua
      else
        mech.user_agent_alias = 'Linux Firefox'
      end
      mech
    end

    def scrape_idox(params, options)
      puts 'Using Idox scraper.'
      base_url = @url[/^(https?:\/\/[^\/]+)/, 1]

      # secure agent
      agent = Mechanize.new
      agent.verify_mode = OpenSSL::SSL::VERIFY_PEER
      agent.ca_file     = ENV['SSL_CERT_FILE'] if ENV['SSL_CERT_FILE'] && File.exist?(ENV['SSL_CERT_FILE'])

      apps = []

      begin
        Timeout.timeout(900) do  # 15 minutes = 900 seconds
          puts "Getting: #{@url}"
          page = fetch_page(@url, agent)
          return [] unless page

          # ensure form present
          unless (form = page.form('searchCriteriaForm'))
            warn 'Error: search form not present – Idox internal error?'
            return []
          end

          # inject missing date fields
          %w[
            date(applicationReceivedStart)
            date(applicationReceivedEnd)
            date(applicationValidatedStart)
            date(applicationValidatedEnd)
          ].each { |f| form.add_field!(f) unless form.has_field?(f) }

          # === Date calculation (DAYS support) ===
          days_back = (ENV['DAYS'] || DAYS).to_i
          received_from = params[:received_from] || (Date.today - days_back)
          received_to   = params[:received_to]   || Date.today
          from_str = received_from.strftime('%d/%m/%Y')
          to_str   = received_to.strftime('%d/%m/%Y')

          puts "Searching for applications from #{from_str} to #{to_str}"

          # === Use Received Date if present, otherwise Validated Date ===
          if form.has_field?('date(applicationReceivedStart)') && form.has_field?('date(applicationReceivedEnd)')
            puts "→ Using received date fields"
            form.send(:"date(applicationReceivedStart)", from_str)
            form.send(:"date(applicationReceivedEnd)",   to_str)
          elsif form.has_field?('date(applicationValidatedStart)') && form.has_field?('date(applicationValidatedEnd)')
            puts "→ Received date fields not found, using validated date fields instead"
            form.send(:"date(applicationValidatedStart)", from_str)
            form.send(:"date(applicationValidatedEnd)",   to_str)
          else
            warn "⚠️  No suitable date fields found – this authority may not support date-based search."
          end

          # Clear all other search filters to avoid interference
          %w[
            searchCriteria.description
            searchCriteria.caseStatus
            searchCriteria.applicantName
            searchCriteria.caseType
            searchCriteria.developmentType
          ].each do |f|
            form.field_with(name: f).value = '' if form.has_field?(f)
          end

          # === Submit search ===
          page = form.submit

          if page.at('.errors')&.inner_text&.match?(/Too many results found/i)
            raise TooManySearchResults, 'Scrape in smaller chunks.'
          end

          # === Pagination ===
          loop do
            items = page.search('li.searchresult')
            puts "Found #{items.size} apps on this page."

            items.each do |appnode|
              app = Application.new
              info = appnode.at('p.metaInfo').text.strip.split('|').map { _1.strip.delete("\r\n") }

              info.each do |bit|
                case bit
                when /Ref\. No:\s+(.+)/                                 then app.council_reference = Regexp.last_match(1)
                when /(Received|Registered):.*?(\d{2}\s\w{3}\s\d{4})/   then app.date_received    = Date.parse(Regexp.last_match(2))
                when /Validated:.*?(\d{2}\s\w{3}\s\d{4})/               then app.date_received  ||= Date.parse(Regexp.last_match(1)) # fallback
                when /Status:\s+(.+)/                                   then app.status           = Regexp.last_match(1)
                end
              end

              app.scraped_at   = Time.now
              app.info_url     = base_url + appnode.at('a')['href']
              app.address      = appnode.at('p.address').text.strip
              app.description  = appnode.at('a').text.strip
              apps << app
            end

            if (next_btn = page.at('a.next'))
              sleep options[:delay]
              next_url = base_url + next_btn[:href]
              puts "Getting: #{next_url}"
              page = fetch_page(next_url, agent)
              break unless page
            else
              break
            end
          end

          # === Individual application pages ===
          apps.each_with_index do |app, idx|
            puts "#{idx + 1} of #{apps.size}: #{app.info_url}"
            puts "------------------------------------------------------------"
            puts "  Ref:        #{app.council_reference}"
            puts "  Address:    #{app.address}"
            puts "  Description:#{app.description}"
            puts "  Date:       #{app.date_received}"
            puts "  Link:       #{app.info_url}"
            puts "------------------------------------------------------------"

            res = fetch_page(app.info_url, agent)
            next unless res && res.code == '200'

            app.documents_count = 0
            if (dl = res.at('.associateddocument a') || res.at('#tab_documents')) && dl.text =~ /(\d+)/
              app.documents_count = Regexp.last_match(1).to_i
              app.documents_url   = base_url + dl[:href]
            end

            res.search('#simpleDetailsTable tr').each do |row|
              key   = row.at('th')&.text&.strip
              value = row.at('td')&.text&.strip
              next unless key && value

              case key
              when 'Reference'                         then app.council_reference   = value
              when 'Application Received', 'Application Registered'     then app.date_received  = Date.parse(value) if value =~ /\d/
              when 'Application Validated'              then app.date_received  ||= Date.parse(value) if value =~ /\d/ # fallback for councils lacking received date
              when 'Address'                            then app.address        = value unless value.empty?
              when 'Proposal'                           then app.description    = value unless value.empty?
              when 'Status'                             then app.status         = value unless value.empty?
              when 'Decision'                           then app.status       = value unless value.empty?
              end
            end

            # === Fallback: Reference missing in Babergh-style layouts ===
            if app.council_reference.nil?
              begin
                alt_ref = res.at('#simpleDetailsTable tr th:contains("Reference") + td')
                if alt_ref
                  app.council_reference = alt_ref.text.strip
                  puts "✅ Filled missing reference from detail table: #{app.council_reference}"
                end
              rescue => e
                puts "⚠️ Error while fetching fallback reference: #{e.class} - #{e.message}"
              end
            end
            puts "  Description:#{app.description}"
          end
        end
      rescue Timeout::Error
        puts "❌ Timeout after 15 minutes for authority: #{@name}. Returning partial results (#{apps.size} applications scraped)."
      end

      apps
    end

  end # Authority
end # UKPlanningScraper