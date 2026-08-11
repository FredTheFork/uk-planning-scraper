# frozen_string_literal: true
require 'playwright'
require 'date'
require 'time'
require 'uri'
require 'tmpdir'
require 'timeout'
#ENV['PLAYWRIGHT_BROWSERS_PATH'] = File.expand_path('../playwright-browsers', __dir__)

DAYS = 7 unless defined?(DAYS)

module UKPlanningScraper
  class ServletScraper
    def self.scrape(authority, params = {}, options = {})
      new(authority, params, options).scrape
    end

    def initialize(authority, params, options)
      @authority = authority
      @params = params
      @options = options
    end

    def scrape
      puts "🔍 Scraping Servlet system for #{@authority.name}"

      apps = []
      begin
        Timeout.timeout(900) do  # 15 minutes = 900 seconds
          Playwright.create(playwright_cli_executable_path: 'npx playwright') do |playwright|
            user_data_dir = Dir.mktmpdir
            browser = playwright.chromium.launch_persistent_context(user_data_dir, headless: false)
            page = browser.pages.first || browser.new_page

            # --- Headers just for North Warwickshire ---
            if @authority.name =~ /North Warwickshire/i
              begin
                page.set_extra_http_headers(
                  {
                    "User-Agent" => "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.0.0 Safari/537.36",
                    "Accept-Language" => "en-GB,en;q=0.9",
                    "Origin" => "http://planning.northwarks.gov.uk",
                    "Referer" => "http://planning.northwarks.gov.uk/portal/servlets/ApplicationSearchServlet"
                  }
                )
              rescue => e
                puts "⚠️ Could not set headers: #{e.message}"
              end
            end

            begin
              page.goto(@authority.url, timeout: 60_000)
            rescue => e
              puts "❌ Failed to load page: #{e.message}"
              File.write("debug_output.html", page.content)
              return []
            end

            begin
              if @authority.name.to_s.strip =~ /Hartlepool/i
                page.eval_on_selector('input[name="ValidDateFrom"]', 'el => el.removeAttribute("readonly")')
                page.eval_on_selector('input[name="ValidDateTo"]', 'el => el.removeAttribute("readonly")')
              else
                page.eval_on_selector('input[name="ReceivedDateFrom"]', 'el => el.removeAttribute("readonly")')
                page.eval_on_selector('input[name="ReceivedDateTo"]', 'el => el.removeAttribute("readonly")')
              end
            rescue => e
              puts "❌ Could not remove readonly attributes: #{e.message}"
              File.write("debug_output.html", page.content)
              return []
            end

            from = (@params[:validated_from] || Date.today - DAYS).strftime('%d-%m-%Y')
            to   = (@params[:validated_to]   || Date.today).strftime('%d-%m-%Y')

            # Normalize authority name just to be safe
            authority_name = @authority.name.to_s.strip

            # Wait for at least one of the expected fields before proceeding
            page.wait_for_selector('input[name="ValidDateFrom"], input[name="ReceivedDateFrom"]', timeout: 10_000)

            if authority_name =~ /Hartlepool/i
              begin
                page.fill('input[name="ValidDateFrom"]', from)
                page.fill('input[name="ValidDateTo"]', to)
              rescue => e
                puts "⚠️ Could not fill ValidDate fields: #{e.message}"
              end
            else
              begin
                page.fill('input[name="ReceivedDateFrom"]', from)
                page.fill('input[name="ReceivedDateTo"]', to)
              rescue => e
                puts "⚠️ Could not fill ReceivedDate fields: #{e.message}"
              end
            end

            if @authority.name =~ /North Warwickshire/i
              # Find all search buttons, click the second one (index 1)
              search_buttons = page.query_selector_all('input[type="submit"][value="Search"]')
              if search_buttons.size >= 2
                search_buttons[1].click
              else
                puts "⚠️ Could not find second 'Search' button, clicking first instead."
                search_buttons.first&.click
              end
            else
              page.click('input[type="submit"][value="Search"]')
            end
            sleep 2
            loop do
              begin
                selector = if @authority.name =~ /North Warwickshire/i
                            'table'
                          else
                            'table'
                          end
                page.wait_for_selector(selector, timeout: 30_000)
              rescue => e
                puts "❌ No results table found: #{e.message}"
                File.write("debug_output.html", page.content)
                break
              end

              # Get the right table for the authority
              table_locator = page.locator('table')
              rows = table_locator.locator('tr').all.drop(1)

              rows.each_with_index do |row, i|
                begin
                  cells = row.locator('td').all
                  next if cells.empty?

                  app = Application.new
                  app.scraped_at = Time.now
                  app.authority_name = @authority.name

                  case @authority.name
                  when /Hartlepool/i
                    app.council_reference = cells[0].locator('a').first.inner_text.strip rescue nil
                    href = cells[0].locator('a').first.get_attribute('href') rescue nil
                    app.info_url = URI.join(@authority.url, href).to_s rescue nil
                    app.address = cells[1].inner_text.strip.gsub(/\s+/, ' ').gsub('<br>', ', ') rescue nil
                    app.description = cells[2].inner_text.strip.gsub(/\s+/, ' ') rescue nil

                  when /High Peak|Staffordshire Moorlands/i
                    app.council_reference = cells[0].locator('a').first.inner_text.strip rescue nil
                    app.info_url = cells[0].locator('a').first.get_attribute('href') rescue nil
                    app.date_received = parse_date(cells[1].inner_text) rescue nil
                    app.date_validated = parse_date(cells[2].inner_text) rescue nil
                    app.address = cells[3].inner_text.strip.gsub(/\s+/, ' ') rescue nil
                    app.description = cells[4].inner_text.strip.gsub(/\s+/, ' ') rescue nil
                    app.decision = cells[5].inner_text.strip rescue nil

                  when /North Warwickshire/i
                    # Updated parsing based on the provided HTML
                    app.council_reference = cells[0].locator('a').first.inner_text.strip rescue nil
                    href = cells[0].locator('a').first.get_attribute('href') rescue nil
                    app.info_url = URI.join(@authority.url, href).to_s rescue nil
                    app.date_validated = parse_date(cells[1].inner_text.strip) rescue nil
                    app.address = cells[2].inner_html.gsub(/&nbsp;|<br\s*\/?>/, ', ').gsub(/\s+/, ' ').strip rescue nil
                    app.description = cells[3].inner_text.strip.gsub(/\s+/, ' ') rescue nil
                    app.decision = cells[4].inner_text.strip rescue nil

                  else
                    puts "⚠️ Unknown authority format for #{@authority.name}, skipping row."
                    next
                  end

                  if app.valid?
                    apps << app
                    puts "  → Added application ##{apps.size}: #{app.council_reference}"
    ##############################################################################
                    # Print debugging info
                    puts "------------------------------------------------------------"
                    puts "  Ref:        #{app.council_reference}"
                    puts "  Address:    #{app.address}"
                    puts "  Description:#{app.description}"
                    puts "  Decision:   #{app.decision}"
                    puts "  Date:       #{app.date_decision}"
                    puts "  Link:       #{app.info_url}"
                    puts "------------------------------------------------------------"
    ##############################################################################
                  end
                rescue => e
                  puts "⚠️ Error processing row #{i + 1}: #{e.message}"
                end
              end

              # Handle pagination
              next_button = page.locator('input[name="forward"][value="Next Matching Results"]')
              break unless next_button.count > 0 && next_button.first.enabled?

              next_button.first.click
              page.wait_for_timeout(1000) # wait for next page to load
            end

            browser.close
          end
        end
      rescue Timeout::Error
        puts "❌ Timeout after 15 minutes while scraping #{@authority.name} (Servlet). " \
             "Returning partial results (#{apps.size} applications already collected)."
      rescue Playwright::Error, StandardError => e
        puts "❌ Unexpected error in Servlet scraper for #{@authority.name}: #{e.class} - #{e.message}"
      end
      apps
    end

    private

    def parse_date(text)
      Date.strptime(text.strip, '%d/%m/%Y') rescue Date.strptime(text.strip)
    end
  end
end
