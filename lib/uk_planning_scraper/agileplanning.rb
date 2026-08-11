# frozen_string_literal: true

require 'playwright'
require 'date'
require 'time'
require 'uri'
require 'timeout'                    # ← added for the 15-minute timeout
require_relative 'application'

module UKPlanningScraper
  class AgilePlanningScraper
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
      puts "Using Agileplanning scraper."
      base_url = @url
      apps = []

      begin
        Timeout.timeout(900) do  # 15 minutes = 900 seconds
          Playwright.create(playwright_cli_executable_path: 'npx playwright') do |playwright|
            browser = playwright.chromium.launch(headless: false)
            context = browser.new_context
            page = context.new_page

            puts "Getting: #{base_url}"
            page.goto(base_url, timeout: 60_000)
            page.wait_for_selector('input[name="received_date_from"]', timeout: 30_000)

            from_date = (@params[:validated_from] || @params[:received_from] || Date.today - DAYS).strftime('%d-%m-%Y')
            to_date = (@params[:validated_to] || @params[:received_to] || Date.today).strftime('%d-%m-%Y')

            puts "From: #{from_date} To: #{to_date}"
            page.fill('input[name="received_date_from"]', from_date)
            page.fill('input[name="received_date_to"]', to_date)

            sleep 1

            puts "Clicking Search button via JS..."
            page.evaluate("document.querySelector('form.application-search-form').requestSubmit()")

            puts "Waiting for AJAX-loaded results..."
            begin
              page.wait_for_function(<<~JS, timeout: 30_000)
                () => {
                  const rows = document.querySelectorAll("#application_results_table tbody tr");
                  return rows.length > 0;
                }
              JS
            rescue Playwright::TimeoutError
              puts "Timeout waiting for results."
              File.write("debug_output.html", page.content)
              context.close
              browser.close
              return []
            end

            loop do
              rows = page.query_selector_all('#application_results_table tbody tr')
              puts "Found #{rows.size} apps on this page."

              rows.each do |row|
                app = Application.new
                app.scraped_at = Time.now
                app.authority_name = @name

                cells = row.query_selector_all('td')
                app.council_reference = cells[0]&.inner_text&.strip
                app.description = cells[3]&.inner_text&.strip
                app.address = cells[2]&.inner_text&.strip
                app.status = cells[6]&.inner_text&.strip rescue nil

                # Fallback only: we skip detail pages completely
                app.info_url = base_url

                # Optional keyword filtering
                if @options[:keywords]&.any? && app.description
                  next unless @options[:keywords].any? { |kw| app.description.downcase.include?(kw.downcase) }
                end
                
    ##############################################################################
                # Print debugging info
                puts "------------------------------------------------------------"
                puts "  Ref:        #{app.council_reference}"
                puts "  Address:    #{app.address}"
                puts "  Description:#{app.description}"
                puts "  Date:       #{app.date_decision}"
                puts "  Link:       #{app.info_url}"
                puts "------------------------------------------------------------"
    ##############################################################################
                apps << app
                sleep @options[:delay] if @options[:delay]
              end

              next_link = page.query_selector('a[aria-label="Next"]')
              break unless next_link && !next_link.get_attribute('class').to_s.include?('disabled')

              puts "Clicking next page..."
              next_link.click
              page.wait_for_selector('#application_results_table tbody tr', timeout: 30_000)
              sleep @options[:delay] if @options[:delay]
            end

            context.close
            browser.close
          end
        end
      rescue Timeout::Error
        puts "❌ Timeout after 15 minutes while scraping #{@authority.name} (AgilePlanning). " \
             "Returning partial results (#{apps.size} applications already collected)."
      rescue Playwright::Error, StandardError => e
        puts "❌ Unexpected error in AgilePlanning scraper for #{@authority.name}: #{e.class} - #{e.message}"
      end

      apps
    end

    def parse_date(str)
      return nil unless str && str.strip.match(/\d{2}-\d{2}-\d{4}/)
      Date.strptime(str.strip, '%d-%m-%Y') rescue nil
    end

    def random_user_agent
      [
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/123.0.0.0 Safari/537.36",
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Version/14.1 Safari/605.1.15",
        "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/120.0.0.0 Safari/537.36"
      ].sample
    end
  end
end