# frozen_string_literal: true
require 'playwright'
require 'date'
require 'uri'
require 'timeout'                    # ← added
require 'set'                        # ← added (for Set.new)
require_relative 'application'

DAYS = 7 unless defined?(DAYS)

module UKPlanningScraper
  class AgileAppsScraper
    BASE_URLS = [
      'https://planning.agileapplications.co.uk/cannock/search-applications/',
      'https://planning.agileapplications.co.uk/dudley/search-applications/',
      'https://planning.agileapplications.co.uk/flintshire/search-applications/',
      'https://planning.agileapplications.co.uk/islington/search-applications/',
      'https://planning.agileapplications.co.uk/middlesbrough/search-applications/',
      'https://planning.agileapplications.co.uk/mole/search-applications/',
      'https://planning.agileapplications.co.uk/pembrokeshire/search-applications/',
      'https://planning.agileapplications.co.uk/rugby/search-applications/',
      'https://planning.agileapplications.co.uk/slough/search-applications/',
      'https://planning.agileapplications.co.uk/tmbc/search-applications/',
      'https://planning.richmond.gov.uk/richmond/search-applications/',
      'https://planning.redbridge.gov.uk/redbridge/search-applications/'
    ]

    def self.scrape(authority, params = {}, options = {})
      new(authority, params, options).scrape
    end

    def initialize(authority, params, options = {})
      @authority = authority
      @params    = params
      @options   = options
      @url       = authority.url
    end

    def scrape
      puts "🔍 Scraping AgileApps for #{@authority.name}"

      from_date = (@params[:received_from] || Date.today - DAYS).strftime('%Y-%m-%d')
      to_date   = (@params[:received_to]   || Date.today).strftime('%Y-%m-%d')
      keyword   = @params[:keywords] || ''

      criteria = URI.encode_www_form_component({
        proposal: keyword,
        registrationDateFrom: from_date,
        registrationDateTo: to_date
      }.compact.to_json)

      apps = []
      seen_refs = Set.new

      begin
        Timeout.timeout(900) do  # 15 minutes = 900 seconds
          Playwright.create(playwright_cli_executable_path: 'npx playwright') do |playwright|
            browser = playwright.chromium.launch(headless: false)
            context = browser.new_context
            page = context.new_page

            page_number = 1

            loop do
              search_url = URI.join(@url, "results?criteria=#{criteria}&page=#{page_number}").to_s
              puts "Getting: #{search_url}"

              page.goto(search_url, timeout: 60_000)

              # ✅ Handle consent
              begin
                accept_button = page.query_selector('button.btn.btn-primary:has-text("Accept")')
                if accept_button
                  accept_button.click
                  puts "🟢 Clicked 'Accept' consent button."
                  page.wait_for_timeout(500)
                end
              rescue => e
                puts "⚠️ Error while handling 'Accept' button: #{e.class} - #{e.message}"
              end

              # Wait for table to load
              begin
                page.wait_for_selector('tr[ng-repeat="row in $data"]', timeout: 15_000)
              rescue Playwright::TimeoutError
                puts "No more results or page failed to load."
                break
              end

              rows = page.query_selector_all('tr[ng-repeat="row in $data"]')
              rows = rows.select do |r|
                tds = r.query_selector_all('td')
                tds && tds.size >= 3 && !tds[0].inner_text.to_s.strip.empty?
              end
              break if rows.empty?

              puts "  → #{rows.size} applications found on page #{page_number}."

              rows.each_with_index do |row, i|
                begin
                  tds = row.query_selector_all('td')
                  next unless tds && tds.size >= 3

                  # Extract ref only
                  link_node = tds[0].query_selector('a')
                  ref = link_node ? link_node.inner_text.to_s.strip : tds[0].inner_text.to_s.strip
                  next if ref.nil? || ref.empty?
                  next if seen_refs.include?(ref)

                  app = Application.new
                  app.scraped_at = Time.now
                  app.authority_name = @authority.name
                  app.council_reference = ref

                  # --- ✅ CLICK EACH ROW TO GET FULL DETAILS ---
                  begin
                    # Handle consent again (sometimes re-appears)
                    begin
                      accept_button = page.query_selector('button.btn.btn-primary:has-text("Accept")')
                      if accept_button
                        accept_button.click
                        puts "🟢 Clicked 'Accept' consent button."
                        page.wait_for_timeout(500)
                      end
                    rescue => e
                      puts "⚠️ Error while handling 'Accept' button: #{e.class} - #{e.message}"
                    end

                    # Re-acquire the row fresh (Angular may have re-rendered)
                    rows = page.query_selector_all('tr[ng-repeat="row in $data"]')
                    current_row = rows[i]
                    next unless current_row

                    current_row.scroll_into_view_if_needed
                    current_row.wait_for_element_state('stable', timeout: 5_000)
                    current_row.click(force: true)

                    # Wait for Angular details pane to appear
                    page.wait_for_selector('sas-textarea[label="APPLICATION.SUMMARY.location"], #summaryTab', timeout: 15_000)
                    page.wait_for_timeout(500) # settle animations

                    # Extract Address
                    address_field = page.query_selector('sas-textarea[label="APPLICATION.SUMMARY.location"] textarea')
                    if address_field
                      app.address = address_field.input_value.strip rescue address_field.inner_text.strip
                    end

                    # Extract Description
                    desc_field = page.query_selector('sas-textarea[label="APPLICATION.SUMMARY.fullProposal"] textarea')
                    if desc_field
                      app.description = desc_field.input_value.strip rescue desc_field.inner_text.strip
                    end

                    # Extract Registration Date
                    date_field = page.query_selector('sas-input-text[label="APPLICATION.SUMMARY.registrationDate"] input')
                    if date_field
                      raw_date = date_field.input_value.strip
                      app.date_received = Date.parse(raw_date) rescue nil
                    end

                    # Try to capture info URL if available
                    app.info_url = page.url rescue nil

                    puts "✅ Scraped full details for #{ref}"
                  rescue Playwright::TimeoutError => e
                    puts "⚠️ Timed out loading details for #{ref}: #{e.message}"
                  rescue => e
                    puts "⚠️ Failed to scrape full detail for #{ref}: #{e.class} - #{e.message}"
                  ensure
                    # Return to search results
                    begin
                      if page.query_selector('#backLink')
                        page.click('#backLink')
                      else
                        page.go_back(timeout: 20_000)
                      end

                      page.wait_for_selector('tr[ng-repeat="row in $data"]', timeout: 20_000)
                      page.wait_for_timeout(500)
                    rescue => e
                      puts "⚠️ Error returning to results: #{e.class} - #{e.message}"
                      # Last resort: reload
                      begin
                        page.reload(timeout: 30_000)
                        page.wait_for_selector('tr[ng-repeat="row in $data"]', timeout: 20_000)
                      rescue => reload_error
                        puts "❌ Reload recovery failed: #{reload_error.class} - #{reload_error.message}"
                      end
                    end
                  end
                  # --- END DETAIL SCRAPE BLOCK ---

                  # Fallbacks in case detail page fails
                  if (app.address.nil? || app.address.empty?) && tds[2]
                    app.address = tds[2].inner_text.to_s.strip
                  end
                  if (app.description.nil? || app.description.empty?) && tds[1]
                    app.description = tds[1].inner_text.to_s.strip
                  end

                  # Ultra-robust date fallback
                  if app.date_received.nil?
                    begin
                      date_field = page.query_selector('td[data-title*="Registration date"] span.ng-binding, td[data-title*="Received date"] span.ng-binding')
                      if date_field
                        raw_date = date_field.inner_text.strip
                        app.date_received = Date.parse(raw_date) rescue nil
                        puts "✅ Filled date_received from fallback: #{raw_date}"
                      end
                    rescue => e
                      puts "⚠️ Error while parsing AgileApps date: #{e.class} - #{e.message}"
                    end
                  end

                  # Logging
                  puts "------------------------------------------------------------"
                  puts "  Ref:        #{app.council_reference}"
                  puts "  Address:    #{app.address}"
                  puts "  Description:#{app.description}"
                  puts "  Date:       #{app.date_received}"
                  puts "  Link:       #{app.info_url}"
                  puts "------------------------------------------------------------"

                  if app.valid?
                    apps << app
                    seen_refs << app.council_reference
                    puts "  → Added #{app.council_reference}"
                  else
                    puts "⚠️ Skipped invalid app for row #{i + 1} (ref: #{ref.inspect})"
                  end

                  sleep @options[:delay] if @options[:delay]
                rescue => e
                  puts "⚠️ Error processing row #{i + 1}: #{e.class} - #{e.message}"
                end
              end

              page_number += 1
            end

            context.close
            browser.close
          end
        end
      rescue Timeout::Error
        puts "❌ Timeout after 15 minutes while scraping #{@authority.name} (AgileApps). " \
             "Returning partial results (#{apps.size} applications already collected)."
      rescue Playwright::Error, StandardError => e
        puts "❌ Unexpected error in AgileApps scraper for #{@authority.name}: #{e.class} - #{e.message}"
      end

      puts "  → Total: #{apps.size} applications found."
      apps
    end
  end
end