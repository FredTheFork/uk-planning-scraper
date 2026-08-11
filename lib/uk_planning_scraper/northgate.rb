# frozen_string_literal: true
require 'net/http'
require 'uri'
require 'nokogiri'
require 'cgi'
require 'openssl'
require 'zlib'
require 'stringio'
require 'brotli'
require 'playwright'
require 'timeout'                    # ← added for the 15-minute timeout
require_relative 'application'

DAYS = 7 unless defined?(DAYS)

module UKPlanningScraper
  class NorthgateScraper
    def self.scrape(authority)
      new(authority).scrape
    end

    def initialize(authority)
      @authority = authority
      @url = authority.url.chomp('/')
      @uri = URI.parse(@url)
      ENV['SSL_CERT_FILE'] = File.expand_path('../../cacert.pem', __dir__)
    end

    def scrape
      puts "🔍 Scraping Northgate system for #{@authority.name}: #{@url}"

      keywords_required = false
      south_tyneside = false

      case @authority.name.downcase
      when /blackburn/, /stafford/
        keywords_required = true
      when /south tyneside/
        south_tyneside = true
      end

      form = nil
      initial_html = nil

      # First Playwright block: just to get the initial form (short-lived)
      Playwright.create(playwright_cli_executable_path: 'npx playwright') do |playwright|
        browser = playwright.chromium.launch(headless: false)
        begin
          context = browser.new_context
          page = context.new_page
          page.goto(@url, timeout: 60_000)
          initial_html = page.content
          doc = Nokogiri::HTML(initial_html)
          form = extract_form_from_doc(doc)
        rescue => e
          warn "⚠️ Playwright initial fetch failed: #{e.message}. Falling back to Net::HTTP."
          raw_doc = fetch_initial_via_net_http
          if raw_doc
            form = extract_form_from_doc(raw_doc)
            initial_html = raw_doc.to_html
          else
            raise "Failed to fetch initial Northgate page for #{@authority.name}"
          end
        ensure
          browser.close if browser
        end
      end

      unless form
        puts "❌ Could not extract form for #{@authority.name}"
        File.write("debug_northgate_error.html", initial_html || '')
        return []
      end

      post_data = build_post_data(form, keywords_required, south_tyneside)

      # ✨ Main scraping logic with timeout protection
      apps = []

      begin
        Timeout.timeout(900) do   # 15 minutes = 900 seconds
          Playwright.create(playwright_cli_executable_path: 'npx playwright') do |playwright|
            browser = playwright.chromium.launch(headless: false)
            context = browser.new_context
            page = context.new_page

            begin
              page.goto(@url, timeout: 60_000)
              action_url = resolve_action_url(form[:action])

              payload = { action: action_url, data: post_data }
              response_html = page.evaluate(<<~JS, arg: payload)
                async function(payload) {
                  const buildBody = (obj) => {
                    return Object.keys(obj).map(k => encodeURIComponent(k) + '=' + encodeURIComponent(obj[k])).join('&');
                  };
                  const opts = {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
                    body: buildBody(payload.data),
                    credentials: 'same-origin'
                  };
                  const resp = await fetch(payload.action, opts);
                  const txt = await resp.text();
                  return txt;
                }
              JS

              page.set_content(response_html || '')
              first_apps = parse_results_from_html(page.content)
              apps.concat(first_apps)
              puts "  → Page 1: #{first_apps.size} applications"
              sleep 30
              # pagination loop
              page_index = 1
              loop do
                numeric_links = page.query_selector_all('a.results_page_number')
                break if numeric_links.empty?

                next_page_link = numeric_links.find do |a|
                  txt = a.inner_text.strip rescue ''
                  txt =~ /^\d+$/ && txt.to_i == (page_index + 1)
                end
                break unless next_page_link

                href = next_page_link.get_attribute('href')
                full_url = URI.join(@url + '/Generic/', href).to_s
                puts "➡️ Navigating to page #{page_index + 1}: #{full_url}"

                begin
                  page.goto(full_url, timeout: 30_000)
                  page.wait_for_load_state('domcontentloaded', timeout: 30_000)
                rescue => e
                  warn "⚠️ Navigation failed for page #{page_index + 1}: #{e.message}"
                  break
                end

                new_apps = parse_results_from_html(page.content)
                break if new_apps.empty?
                apps.concat(new_apps)
                puts "  → Page #{page_index + 1}: #{new_apps.size} applications"
                page_index += 1
              end

              puts "✅ Total collected for #{@authority.name}: #{apps.size}"
            rescue => e
              warn "⚠️ Error during Playwright scraping: #{e.message}"
            ensure
              browser.close if browser
            end
          end
        end
      rescue Timeout::Error
        puts "❌ Timeout after 15 minutes while scraping #{@authority.name} (Northgate). " \
             "Returning partial results (#{apps.size} applications already collected)."
      rescue Playwright::Error, StandardError => e
        puts "❌ Unexpected error in Northgate scraper for #{@authority.name}: #{e.class} - #{e.message}"
      end

      apps
    end

    private

    def resolve_action_url(action)
      return @url if action.nil? || action.strip.empty?
      URI.join(@url + '/', action).to_s rescue action
    end

    def fetch_initial_via_net_http
      uri = @uri
      req = Net::HTTP::Get.new(uri)
      req['User-Agent'] = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'
      req['Accept-Encoding'] = 'gzip, deflate, br'
      req['Accept'] = 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8'
      req['Accept-Language'] = 'en-GB,en;q=0.9'

      resp = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https', verify_mode: OpenSSL::SSL::VERIFY_PEER, cert_store: OpenSSL::X509::Store.new.add_file(ENV['SSL_CERT_FILE'])) do |http|
        http.request(req)
      end

      if resp.code.to_i == 200
        body = case resp['Content-Encoding']
               when 'br' then Brotli.inflate(resp.body)
               when 'gzip' then Zlib::GzipReader.new(StringIO.new(resp.body)).read
               else resp.body
               end
        Nokogiri::HTML(body)
      end
    rescue => e
      warn "⚠️ Net::HTTP initial fetch failed: #{e.message}"
      nil
    end

    def build_post_data(form, keywords_required = false, south_tyneside = false)
      if south_tyneside
        return {
          '__EVENTTARGET' => '',
          '__EVENTARGUMENT' => '',
          '__VIEWSTATE' => form[:viewstate],
          '__VIEWSTATEGENERATOR' => form[:viewstategenerator],
          '__EVENTVALIDATION' => form[:eventvalidation],
          'vrDays' => DAYS.to_s,
          'csbtnSearch' => 'Search'
        }
      end

      data = {
        '__EVENTTARGET' => '',
        '__EVENTARGUMENT' => '',
        '__VIEWSTATE' => form[:viewstate],
        '__VIEWSTATEGENERATOR' => form[:viewstategenerator],
        '__EVENTVALIDATION' => form[:eventvalidation],
        'cboSelectDateValue' => 'DATE_REGISTERED',
        'rbGroup' => 'rbDay',
        'rbDay' => 'rbDay',
        'cboDays' => DAYS.to_s,
        'csbtnSearch' => 'Search'
      }

      if keywords_required || @authority.name.downcase.include?('blackburn')
        data['txtProposal'] = ' '
      end

      data
    end

    def submit_form_raw(action, data)
      uri = @uri.merge(action)
      request = Net::HTTP::Post.new(uri)
      request.body = URI.encode_www_form(data)
      request['Content-Type'] = 'application/x-www-form-urlencoded'
      request['User-Agent'] = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'
      request['Accept-Encoding'] = 'gzip, deflate, br'
      request['Accept'] = 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8'
      request['Accept-Language'] = 'en-GB,en;q=0.9'
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https', verify_mode: OpenSSL::SSL::VERIFY_PEER, cert_store: OpenSSL::X509::Store.new.add_file(ENV['SSL_CERT_FILE'])) do |http|
        http.request(request)
      end
      body = case response['Content-Encoding']
             when 'br' then Brotli.inflate(response.body)
             when 'gzip' then Zlib::GzipReader.new(StringIO.new(response.body)).read
             else response.body
             end
      Nokogiri::HTML(body)
    end

    def extract_form_from_doc(doc)
      doc = doc.respond_to?(:at) ? doc : Nokogiri::HTML(doc.to_s)
      {
        action: doc.at('form#M3Form')&.[]('action') || doc.at('form')&.[]('action') || @uri.path,
        viewstate: doc.at("input[name='__VIEWSTATE']")&.[]('value'),
        viewstategenerator: doc.at("input[name='__VIEWSTATEGENERATOR']")&.[]('value'),
        eventvalidation: doc.at("input[name='__EVENTVALIDATION']")&.[]('value')
      }
    end

    def parse_results_from_html(html)
      doc = Nokogiri::HTML(html)
      table = doc.at('table.display_table')
      return [] unless table
      rows = table.css('tr')[1..] || []
      rows.each_with_object([]) do |row, apps|
        cells = row.css('td')
        next unless cells.size >= 5 && (link = cells[0].at('a'))
        app = Application.new
        app.council_reference = link.text.strip
        app.info_url = URI.join(@url + '/', link['href']).to_s.gsub('GeneralSearch.aspx', 'Generic')
        app.address = cells[1].text.strip.gsub("\n", ", ")
        app.description = cells[2].text.strip
        app.status = cells[3].text.strip
        app.date_received = Date.parse(cells[4].text.strip)
##############################################################################
        # Print debugging info
        puts "------------------------------------------------------------"
        puts "  Ref:        #{app.council_reference}"
        puts "  Address:    #{app.address}"
        puts "  Description:#{app.description}"
        puts "  Date:       #{app.date_received}"
        puts "  Link:       #{app.info_url}"
        puts "------------------------------------------------------------"
##############################################################################
        apps << app
      end
    end

    def parse_date(text)
      Date.strptime(text, '%d-%m-%Y') rescue nil
    end
  end
end