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
      authority_id = AUTHORITIES.keys.find { |k| @authority.name.include?(k) }
      raise "Unrecognized authority for #{@authority.name}" unless authority_id

      date_to = Date.today
      date_from = @params[:received_from] || (date_to - DAYS)

      apps = []
      begin
        Timeout.timeout(900) do   # 15 minutes = 900 seconds
          Playwright.create(playwright_cli_executable_path: Playwright::CLI_EXECUTABLE_PATH) do |playwright|
            playwright.chromium.launch(headless: false) do |browser|
              browser.new_context do |context|
                page = context.new_page
                page.goto(BASE_URL)
                page.wait_for_load_state
                page.click('button:has-text("Continue")')
                sleep 1
                # ✅ Authority selection using keyboard navigation
                page.click('button[name="authority-button"]', timeout: 10_000)
                sleep 1

                # Wait for dropdown to open
                page.wait_for_selector('.MultiSearchSelectstyles__DropDownSearchFilter-kdm30m-1', timeout: 10_000)

                # Get the authority value (1-10) from the hash
                authority_key = AUTHORITIES.keys.find { |k| @authority.name.include?(k) }
                if authority_key
                  authority_value = AUTHORITIES[authority_key]
                  # Click the label containing the specific checkbox input by value
                  page.click("label:has(input[value=\"#{authority_value}\"])")
                  puts "✅ Selected authority: #{authority_key} (value #{authority_value})"
                else
                  puts "⚠️ Could not determine authority for #{@authority.name}"
                end
                # === Fill Received From / To with robust fallbacks ===
                from_str = (date_from || Date.today - DAYS).strftime('%d %b %Y') # safe fallback if date_from missing
                to_str   = (date_to   || Date.today).strftime('%d %b %Y')

                filled_from = false
                filled_to   = false

                begin
                  # 1) Primary: explicit ids
                  if page.locator('#field-14').count > 0 && page.locator('#field-15').count > 0
                    page.locator('#field-14').fill(from_str)
                    page.locator('#field-15').fill(to_str)
                    filled_from = filled_to = true
                    puts "✅ Filled dates via #field-14 / #field-15 => #{from_str} → #{to_str}"
                  end
                rescue => e
                  warn "⚠️ Primary id fill failed: #{e.class} - #{e.message}"
                end

                unless filled_from && filled_to
                  begin
                    # 2) aria-labelledby fallback
                    if !filled_from && page.locator('input[aria-labelledby="dateFrom"]').count > 0
                      page.locator('input[aria-labelledby="dateFrom"]').fill(from_str)
                      filled_from = true
                      puts "✅ Filled From via aria-labelledby=dateFrom"
                    end
                    if !filled_to && page.locator('input[aria-labelledby="dateTo"]').count > 0
                      page.locator('input[aria-labelledby="dateTo"]').fill(to_str)
                      filled_to = true
                      puts "✅ Filled To via aria-labelledby=dateTo"
                    end
                  rescue => e
                    warn "⚠️ aria-labelledby fallback failed: #{e.class} - #{e.message}"
                  end
                end

                unless filled_from && filled_to
                  begin
                    # 3) placeholder-based fallback (DD MMM YYYY / DD MMM)
                    placeholders = page.locator('input[placeholder]')
                    placeholders.count.times do |i|
                      el = placeholders.nth(i)
                      ph = (el.get_attribute('placeholder') || '').to_s
                      next if ph.empty?
                      if !filled_from && ph.match?(/DD\s*MMM/i)
                        el.fill(from_str)
                        filled_from = true
                        puts "✅ Filled From via placeholder: #{ph}"
                      elsif !filled_to && ph.match?(/DD\s*MMM/i)
                        # if we accidentally pick the same placeholder twice, ensure we don't overwrite the from
                        unless filled_to
                          el.fill(to_str)
                          filled_to = true
                          puts "✅ Filled To via placeholder: #{ph}"
                        end
                      end
                      break if filled_from && filled_to
                    end
                  rescue => e
                    warn "⚠️ placeholder fallback failed: #{e.class} - #{e.message}"
                  end
                end

                unless filled_from && filled_to
                  begin
                    # 4) generic last-resort search for inputs that look like dates
                    inputs = page.locator('input')
                    inputs.count.times do |i|
                      next if filled_from && filled_to
                      el = inputs.nth(i)
                      next unless (attr = el.get_attribute('placeholder') || el.get_attribute('aria-label') || el.get_attribute('id') || '').to_s.match?(/DD|dd|MMM|yyyy|Date|date/i)
                      if !filled_from
                        el.fill(from_str) rescue nil
                        filled_from = true
                        puts "✅ Filled From via generic input fallback (matched #{attr.inspect})"
                      elsif !filled_to
                        el.fill(to_str) rescue nil
                        filled_to = true
                        puts "✅ Filled To via generic input fallback (matched #{attr.inspect})"
                      end
                    end
                  rescue => e
                    warn "⚠️ generic input fallback failed: #{e.class} - #{e.message}"
                  end
                end

                # final check
                unless filled_from && filled_to
                  warn "❌ Could not find date inputs for Received From / To. Tried multiple fallbacks."
                else
                  # blur active element and click body to trigger any JS validation
                  begin
                    page.evaluate("() => { if (document.activeElement) document.activeElement.blur(); }")
                  rescue
                  end
                  begin
                    page.click('body') rescue nil
                  rescue
                  end
                  page.wait_for_timeout(700)
                end

                # === Fill dummy search term to enable search button (only if present) ===
                begin
                  ref_input = page.locator('input[aria-label="Reference number-input"], input[id*="reference"], input[name*="reference"]')
                  if ref_input.count > 0
                    ref_input.first.fill('2') rescue nil
                    puts "✅ Filled dummy reference to enable search"
                  else
                    puts "ℹ️ No reference input found to fill."
                  end
                rescue => e
                  warn "⚠️ Failed to fill dummy reference: #{e.class} - #{e.message}"
                end

                # short pause for UI to react
                page.wait_for_timeout(1000)

                sleep 5

                # Click the SECOND Search button (index 2)
                search_buttons = page.query_selector_all('button:has-text("Search")')
                if search_buttons.size >= 2
                  search_buttons[2].click
                  puts "✅ Clicked the second Search button"
                else
                  puts "⚠️ Could not find the second Search button, clicking the first instead"
                  search_buttons.first&.click
                end

                page.wait_for_selector('.ApplicationCard__StyledLink-sc-1oe3v7i-0', timeout: 30_000)
                sleep 5
                def click_all_show_more(page)
                  buttons = page.query_selector_all('button.tqc-button.css-dlbz8t')
                  puts "🟢 Found #{buttons.size} 'Show more' buttons."
                  buttons.each_with_index do |btn, i|
                    begin
                      puts "➡️ Clicking 'Show more' button #{i + 1}..."
                      btn.click
                      sleep 1.5
                    rescue => e
                      puts "⚠️ Could not click button #{i + 1}: #{e.message}"
                    end
                  end
                  puts "✅ All 'Show more' expansions complete."
                end

                loop do
                  cards = page.query_selector_all('.ApplicationCard__StyledLink-sc-1oe3v7i-0')
                  puts "Found #{cards.size} results on this page"

                  cards.each do |card|
                    begin
                      app = Application.new

                      # ✅ Extract reference number
                      app.council_reference = card.inner_text[/Application reference:\s*(\S+)/, 1]

                      # ✅ Extract address (first <p> in .css-ksgbky)
                      app.address = card.query_selector('.css-ksgbky p')&.inner_text&.strip

                      # ✅ Extract description (the actual proposal text)
                      app.description = card.query_selector('.css-pfuuyu p')&.inner_text&.strip

                      # 🧹 Clean up stray “Show more/less” text or badges if ever present
                      app.description&.gsub!(/Show\s+(more|less)/i, '')
                      app.description&.strip!

                      # ✅ Extract received date
                      app.date_received = card.inner_text[/Received:\s*(.+?)\n/, 1]

                      # ✅ Build info URL
                      href = card.query_selector('a')&.get_attribute('href')
                      app.info_url = "https://planningregister.planningsystemni.gov.uk#{href}"

                      # Debugging output
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



                  # pagination (if "Next" exists)
                  next_button = page.query_selector('button:has-text("Next")')
                  break unless next_button && !next_button.get_attribute('disabled')

                  next_button.click
                  page.wait_for_selector('.ApplicationCard__StyledLink-sc-1oe3v7i-0', timeout: 20_000)
                end
              end
            end
          end
        end
      rescue Timeout::Error
        puts "❌ Timeout after 15 minutes while scraping #{@authority.name} (SystemNI). " \
             "Returning partial results (#{apps.size} applications already collected)."
      rescue StandardError => e
        puts "❌ Unexpected error in SystemNI scraper for #{@authority.name}: #{e.class} - #{e.message}"
      end
      puts "✅ Collected #{apps.size} applications"
      apps
    end
  end
end
