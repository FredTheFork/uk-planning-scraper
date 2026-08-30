# frozen_string_literal: true
require_relative 'playwright_compat'
require 'date'
require 'timeout'
require_relative 'application'

DAYS = 7 unless defined?(DAYS)

module UKPlanningScraper
  class SystemNIScraper
    BASE_URL = 'https://planningregister.planningsystemni.gov.uk/advanced-search'

    AUTHORITIES = {
      'Antrim and Newtownabbey' => 1,
      'North Down and Ards' => 2,
      'Armagh Banbridge and Craigavon' => 3,
      'Belfast' => 4,
      'Causeway Coast' => 5,
      'Derry City and Strabane' => 6,
      'Fermanagh and Omagh' => 7,
      'Lisburn and Castlereagh' => 8,
      'Mid and East Antrim' => 9,
      'Newry Mourne and Down' => 10
    }.freeze

    def initialize(authority, params = {}, options = {})
      @authority = authority
      @params = params
      @options = options
    end

    def scrape
      authority_key = AUTHORITIES.keys.find { |k| @authority.name.include?(k) }
      unless authority_key
        puts "❌ Unrecognized authority for #{@authority.name}"
        return []
      end

      authority_value = AUTHORITIES[authority_key]
      puts "🔍 Scraping SystemNI for #{@authority.name} (authority value: #{authority_value})"

      date_to = Date.today
      date_from = @params[:received_from] || (date_to - DAYS)
      from_str = date_from.strftime('%d %b %Y')
      to_str   = date_to.strftime('%d %b %Y')

      puts "📅 Date range: #{from_str} → #{to_str}"

      apps = []
      begin
        Timeout.timeout(900) do
          Playwright.create(playwright_cli_executable_path: Playwright::CLI_EXECUTABLE_PATH) do |playwright|
            browser = playwright.chromium.launch(headless: false)
            context = browser.new_context
            page = context.new_page

            puts "🌐 Navigating to #{BASE_URL}"
            page.goto(BASE_URL, timeout: 60_000)
            page.wait_for_load_state
            puts "✅ Page loaded"

            # Click Continue button if present
            begin
              if page.query_selector('button:has-text("Continue")')
                page.click('button:has-text("Continue")')
                puts "✅ Clicked Continue button"
                sleep 1
              end
            rescue => e
              puts "ℹ️ No Continue button or already past it: #{e.message}"
            end

            # === Authority selection ===
            begin
              page.click('button[name="authority-button"]', timeout: 10_000)
              puts "✅ Clicked authority dropdown button"
              sleep 1

              page.wait_for_selector('.MultiSearchSelectstyles__DropDownSearchFilter-kdm30m-1', timeout: 10_000)
              page.click("label:has(input[value=\"#{authority_value}\"])")
              puts "✅ Selected authority: #{authority_key} (value #{authority_value})"
              sleep 0.5
            rescue => e
              puts "⚠️ Authority selection issue: #{e.class} - #{e.message}"
            end

            # === Fill date fields ===
            filled_from = false
            filled_to   = false

            # 1) Primary: explicit ids field-14 (from) and field-15 (to)
            begin
              if page.locator('#field-14').count > 0
                page.locator('#field-14').fill(from_str)
                filled_from = true
                puts "✅ Filled FROM date via #field-14 => #{from_str}"
              end
            rescue => e
              puts "⚠️ #field-14 fill failed: #{e.class} - #{e.message}"
            end

            begin
              if page.locator('#field-15').count > 0
                page.locator('#field-15').fill(to_str)
                filled_to = true
                puts "✅ Filled TO date via #field-15 => #{to_str}"
              end
            rescue => e
              puts "⚠️ #field-15 fill failed: #{e.class} - #{e.message}"
            end

            # 2) aria-labelledby fallback
            unless filled_from
              begin
                if page.locator('input[aria-labelledby="dateFrom"]').count > 0
                  page.locator('input[aria-labelledby="dateFrom"]').fill(from_str)
                  filled_from = true
                  puts "✅ Filled FROM via aria-labelledby=dateFrom"
                end
              rescue => e
                puts "⚠️ aria-labelledby dateFrom fill failed: #{e.message}"
              end
            end

            unless filled_to
              begin
                if page.locator('input[aria-labelledby="dateTo"]').count > 0
                  page.locator('input[aria-labelledby="dateTo"]').fill(to_str)
                  filled_to = true
                  puts "✅ Filled TO via aria-labelledby=dateTo"
                end
              rescue => e
                puts "⚠️ aria-labelledby dateTo fill failed: #{e.message}"
              end
            end

            # 3) placeholder-based fallback
            unless filled_from && filled_to
              begin
                placeholders = page.locator('input[placeholder]')
                placeholders.count.times do |i|
                  el = placeholders.nth(i)
                  ph = (el.get_attribute('placeholder') || '').to_s
                  next if ph.empty?
                  if !filled_from && ph.match?(/DD\s*MMM/i)
                    el.fill(from_str)
                    filled_from = true
                    puts "✅ Filled FROM via placeholder: #{ph}"
                  elsif !filled_to && ph.match?(/DD\s*MMM/i)
                    el.fill(to_str)
                    filled_to = true
                    puts "✅ Filled TO via placeholder: #{ph}"
                  end
                  break if filled_from && filled_to
                end
              rescue => e
                puts "⚠️ placeholder fallback failed: #{e.message}"
              end
            end

            unless filled_from && filled_to
              puts "❌ Could not fill all date fields (from=#{filled_from}, to=#{filled_to})"
            end

            # Blur to trigger JS validation
            begin
              page.evaluate("() => { if (document.activeElement) document.activeElement.blur(); }")
              page.click('body') rescue nil
              page.wait_for_timeout(700)
            rescue
            end

            # === Click Search button ===
            search_buttons = page.query_selector_all('button:has-text("Search")')
            puts "🔍 Found #{search_buttons.size} Search buttons"

            if search_buttons.empty?
              puts "❌ No Search button found"
              File.write("debug_output.html", page.content)
              context.close
              browser.close
              return []
            end

            # Click the last Search button (typically the form submit)
            search_buttons.last.click
            puts "✅ Clicked Search button (index #{search_buttons.size - 1})"

            # === Wait for results ===
            begin
              page.wait_for_selector('.ApplicationCard__StyledLink-sc-1oe3v7i-0', timeout: 30_000)
              puts "✅ Results page loaded"
            rescue => e
              puts "⚠️ No results found or timeout: #{e.message}"
              File.write("debug_output.html", page.content)
              context.close
              browser.close
              return []
            end

            sleep 2

            # === Parse results with pagination ===
            loop do
              cards = page.query_selector_all('.ApplicationCard__StyledLink-sc-1oe3v7i-0')
              puts "Found #{cards.size} results on this page"

              cards.each do |card|
                begin
                  app = Application.new
                  app.authority_name = @authority.name

                  app.council_reference = card.inner_text[/Application reference:\s*(\S+)/, 1]
                  app.address = card.query_selector('.css-ksgbky p')&.inner_text&.strip
                  app.description = card.query_selector('.css-pfuuyu p')&.inner_text&.strip
                  app.description&.gsub!(/Show\s+(more|less)/i, '')
                  app.description&.strip!

                  app.date_received = card.inner_text[/Received:\s*(.+?)\n/, 1]

                  href = card.query_selector('a')&.get_attribute('href')
                  app.info_url = "https://planningregister.planningsystemni.gov.uk#{href}"

                  puts "------------------------------------------------------------"
                  puts "  Ref:        #{app.council_reference}"
                  puts "  Address:    #{app.address}"
                  puts "  Description:#{app.description}"
                  puts "  Date:       #{app.date_received}"
                  puts "  Link:       #{app.info_url}"
                  puts "------------------------------------------------------------"

                  apps << app
                rescue => e
                  puts "Error parsing card: #{e}"
                end
              end

              # Pagination
              next_button = page.query_selector('button:has-text("Next")')
              break unless next_button && !next_button.get_attribute('disabled')

              next_button.click
              page.wait_for_selector('.ApplicationCard__StyledLink-sc-1oe3v7i-0', timeout: 20_000)
            end

            context.close
            browser.close
          end
        end
      rescue Timeout::Error
        puts "❌ Timeout after 15 minutes while scraping #{@authority.name} (SystemNI). " \
             "Returning partial results (#{apps.size} applications already collected)."
      rescue StandardError => e
        puts "❌ Unexpected error in SystemNI scraper for #{@authority.name}: #{e.class} - #{e.message}"
        puts e.backtrace.first(5).join("\n")
      end

      puts "✅ Collected #{apps.size} applications"
      apps
    end
  end
end
