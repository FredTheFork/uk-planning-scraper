# frozen_string_literal: true
require_relative 'playwright_compat'
require 'date'
require 'time'
require 'uri'
require 'timeout'

DAYS = 7 unless defined?(DAYS)

module UKPlanningScraper
  class OcellaScraper
    def self.scrape(authority, params = {}, options = {})
      new(authority, params, options).scrape
    end

    def initialize(authority, params, options)
      @authority = authority
      @params = params
      @options = options
      @url = authority.url
    end

    def scrape
      puts "🧭 Using Ocella scraper for #{@authority.name}"
      base_url = @url
      apps = []

      begin
        Timeout.timeout(900) do   # 15 minutes = 900 seconds
          Playwright.create(playwright_cli_executable_path: Playwright::CLI_EXECUTABLE_PATH) do |playwright|
            browser = playwright.chromium.launch(headless: false)
            context = browser.new_context
            page = context.new_page

            puts "🌐 Getting: #{base_url}"
            page.goto(base_url, timeout: 60_000)

            # Wait for search form
            page.wait_for_selector('input[name="receivedFrom"]', timeout: 30_000)

            from_date = (@params[:received_from] || Date.today - DAYS).strftime('%d-%m-%y')
            to_date   = (@params[:received_to] || Date.today).strftime('%d-%m-%y')

            puts "📅 From: #{from_date} To: #{to_date}"
            page.fill('input[name="receivedFrom"]', from_date)
            page.fill('input[name="receivedTo"]', to_date)

            sleep 1
            page.click('input[type="submit"][value="Search"]')

            puts "⏳ Waiting for results..."
            begin
              page.wait_for_selector('table tbody tr', timeout: 30_000)
            rescue StandardError
              puts "⚠️ Timeout waiting for results — writing debug_output.html"
              File.write("debug_output.html", page.content)
              context.close
              browser.close
              return []
            end

            rows = page.query_selector_all('table tbody tr')
            puts "✅ Found #{rows.size} rows."

            if rows.empty?
              puts "⚠️ No rows found. Saving page for inspection..."
              File.write("debug_output.html", page.content)
              context.close
              browser.close
              return []
            end

            rows.each_with_index do |row, i|
              link = row.query_selector('td a')
              next unless link

              href = link.get_attribute('href')
              next unless href

              detail_url = URI.join(base_url, href).to_s

              # Open detail page in a new tab
              begin
                detail_page = context.new_page
                detail_page.goto(detail_url, timeout: 60_000)
                detail_page.wait_for_selector('table', timeout: 20_000)
              rescue => e
                puts "⚠️ Error loading detail page #{detail_url}: #{e.message}"
                next
              end

              app = Application.new
              app.authority_name = @authority.name
              app.info_url = detail_url

              # Extract fields from the detail table
              rows_detail = detail_page.query_selector_all('table tr')
              next if rows_detail.empty?

              rows_detail.each do |r|
                cells = r.query_selector_all('td')
                next unless cells.size >= 2
                label = cells[0].inner_text.strip rescue ''
                value = cells[1].inner_text.strip rescue ''
                case label.downcase
                when 'reference'
                  app.council_reference = value
                when 'proposal'
                  app.description = value
                when 'location'
                  app.address = value
                when 'received'
                  app.date_received = parse_date(value)
                end
              end

##############################################################################
              # Print debugging info
              puts "------------------------------------------------------------"
              puts "🧾 Row ##{i + 1}"
              puts "  Ref:        #{app.council_reference}"
              puts "  Address:    #{app.address}"
              puts "  Description:#{app.description}"
              puts "  Date:       #{app.date_received}"
              puts "  Link:       #{app.info_url}"
              puts "------------------------------------------------------------"
##############################################################################

              if @options[:keywords]&.any?
                unless @options[:keywords].any? { |kw| app.description.to_s.downcase.include?(kw.downcase) }
                  puts "  🚫 Skipping #{app.council_reference} — no keyword match"
                  detail_page.close rescue nil
                  next
                end
              end

              if app.valid?
                puts "  ✅ Added application: #{app.council_reference}"
                apps << app
              else
                puts "  ⚠️ Invalid application (missing key fields)"
              end

              detail_page.close rescue nil
              sleep @options[:delay] if @options[:delay]
            end

            context.close
            browser.close
          end
        end
      rescue Timeout::Error
        puts "❌ Timeout after 15 minutes while scraping #{@authority.name} (Ocella). " \
             "Returning partial results (#{apps.size} applications already collected)."
      rescue StandardError => e
        puts "❌ Unexpected error in Ocella scraper for #{@authority.name}: #{e.class} - #{e.message}"
      end

      if apps.empty?
        puts "⚠️ No valid applications found. Writing debug_output.html for inspection."
        File.write("debug_output.html", "<!-- No valid apps -->\n" + Time.now.to_s)
      end

      puts "🧮 Total valid apps: #{apps.size}"
      apps
    end

    def parse_date(str)
      return nil unless str && str.match(/\d{2}-\d{2}-\d{2}/)
      Date.strptime(str.strip, '%d-%m-%y') rescue nil
    end
  end
end