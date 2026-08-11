# frozen_string_literal: true
require_relative 'playwright_compat'
require 'uri'
require 'timeout'
require_relative 'application'

DAYS = 7 unless defined?(DAYS)

module UKPlanningScraper
  class AdvancedsearchScraper
    def self.scrape(authority, params = {}, options = {})
      new(authority, params, options).scrape
    end

    def initialize(authority, params, options)
      @authority = authority
      @params = params
      @options = options
      @base_url = authority.url
    end

    def scrape
      puts "🔍 Scraping AdvancedSearch system for #{@authority.name}"

      apps = []
      begin
        Timeout.timeout(900) do   # 15 minutes = 900 seconds
          page_number = 1

          Playwright.create(playwright_cli_executable_path: 'npx playwright') do |playwright|
            browser = playwright.chromium.launch(headless: false)
            context = browser.new_context
            page = context.new_page
            page.goto(@base_url)

            # --- BCP needs a short delay for cookies to load ---
            if @authority.name.downcase.include?("bournemouth christchurch and poole")
              sleep 2
            end
            if @authority.name.downcase.include?("welwyn hatfield")
              sleep 2
            end

            # Handle cookie/disclaimer popups if present
            begin
              if page.query_selector('button#ccc-notify-accept') # ✅ BCP cookie banner
                page.click('button#ccc-notify-accept', force: true)
                page.wait_for_timeout(500)
                puts "✔️ Clicked BCP cookie accept button"
              end
              if page.query_selector('button#ccc-recommended-settings') # ✅ welwyn cookie banner
                page.click('button#ccc-recommended-settings', force: true)
                page.wait_for_timeout(500)
                puts "✔️ Clicked BCP cookie accept button"
              end
              if @authority.name.downcase.include?("welwyn hatfield") && page.query_selector('button#ccc-recommended-settings')
                sleep 1 # ✅ Welwyn Hatfield cookie banner
                page.click('button#ccc-recommended-settings', force: true)
                page.wait_for_timeout(500)
                puts "✔️ Clicked Welwyn Hatfield cookie accept button"
              end
              
              if page.query_selector('button#ccc-recommended-settings')
                page.click('button#ccc-recommended-settings', force: true)
                page.wait_for_timeout(500)
                puts "✔️ Clicked Welwyn Hatfield cookie accept button"
              end
              
              if page.query_selector('input.disclaimer-agreement')
                page.check('input.disclaimer-agreement', force: true)
                puts "✔️ Disclaimer checkbox ticked"
              end

              if page.query_selector('input.accept-disclaimer, input[value="Agree"]')
                page.click('input.accept-disclaimer, input[value="Agree"]', force: true)
                page.wait_for_timeout(500)
                puts "✔️ Clicked disclaimer button"
              end

              if page.query_selector('input[value="Accept & Continue"]') # ✅ Vale of Glamorgan
                page.click('input[value="Accept & Continue"]', force: true)
                page.wait_for_timeout(500)
                puts "✔️ Clicked Vale disclaimer button"
              end
            rescue => e
              puts "⚠️ Error handling disclaimer/cookie: #{e.message}"
            end

            sleep 1

            # --- Special handling for Fylde ---
            if @authority.name.downcase.include?("fylde")
              puts "⚙️ Applying Fylde-specific adjustments"
              raw_from = @params[:decided_from] || Date.today - DAYS
              raw_to   = @params[:decided_to]   || Date.today

              begin
                page.evaluate("window.scrollBy(0, document.body.scrollHeight/2)")
                page.wait_for_timeout(1000)
                puts "🖱️ Scrolled down for Fylde to ensure search loads"
              rescue => e
                puts "⚠️ Failed to scroll for Fylde: #{e.message}"
              end

              fill_date = lambda do |selector, value|
                begin
                  if page.query_selector(selector)
                    js = %Q{
                      (function(){
                        var el = document.querySelector("#{selector}");
                        if (!el) return false;
                        try { el.focus(); } catch(e){}
                        el.value = "#{value}";
                        el.dispatchEvent(new Event('input', {bubbles:true}));
                        el.dispatchEvent(new Event('change', {bubbles:true}));
                        try { el.blur(); } catch(e){}
                        if (window.jQuery && jQuery(el).datepicker) {
                          try { jQuery(el).datepicker('setDate', "#{value}"); jQuery(el).trigger('change'); } catch(e){}
                        }
                        return true;
                      })();
                    }
                    page.evaluate(js) rescue nil
                    puts "✔️ Filled #{selector} with #{value}"
                    return true
                  else
                    false
                  end
                rescue => e
                  puts "⚠️ Date fill error for #{selector}: #{e.class} - #{e.message}"
                  false
                end
              end

              from_val = raw_from.strftime("%d/%m/%Y")
              to_val   = raw_to.strftime("%d/%m/%Y")

              date_from_selectors = ['#DateReceivedFrom', 'input#DateReceivedFrom', 'input[name="DateReceivedFrom"]']
              date_to_selectors   = ['#DateReceivedTo',   'input#DateReceivedTo',   'input[name="DateReceivedTo"]']

              filled_from = false
              date_from_selectors.each { |s| filled_from = true and break if fill_date.call(s, from_val) }
              puts "⚠️ Fylde date-from not found" unless filled_from

              filled_to = false
              date_to_selectors.each { |s| filled_to = true and break if fill_date.call(s, to_val) }
              puts "⚠️ Fylde date-to not found" unless filled_to

              page.wait_for_timeout(400)

            # --- Special handling for Welwyn Hatfield ---
            elsif @authority.name.downcase.include?("welwyn hatfield")
              from_date = (@params[:received_from] || Date.today - DAYS).strftime("%Y-%m-%d")
              to_date   = (@params[:received_to]   || Date.today).strftime("%Y-%m-%d")

              begin
                page.fill("input#DateReceivedFrom", from_date)
                page.fill("input#DateReceivedTo", to_date)
                puts "✔️ Filled Welwyn Hatfield received date fields: #{from_date} → #{to_date}"
              rescue => e
                puts "⚠️ Could not fill Welwyn Hatfield dates: #{e.message}"
              end

              begin
                if page.query_selector('input#SearchAppeals')
                  begin
                    page.uncheck('input#SearchAppeals', force: true)
                    puts "✔️ Unchecked Appeals (input#SearchAppeals)"
                  rescue
                    page.evaluate(%Q{
                      (function(){
                        var el = document.querySelector('input#SearchAppeals');
                        if(!el) return false;
                        el.checked = false;
                        el.dispatchEvent(new Event('change', {bubbles:true}));
                        return true;
                      })();
                    }) rescue nil
                    puts "✔️ Unchecked Appeals via JS fallback"
                  end
                else
                  puts "ℹ️ SearchAppeals checkbox not present"
                end
              rescue => e
                puts "⚠️ Failed handling Appeals checkbox: #{e.class} - #{e.message}"
              end

              begin
                if page.query_selector('input#SearchBuildingControl')
                  begin
                    page.uncheck('input#SearchBuildingControl', force: true)
                    puts "✔️ Unchecked Building Control (input#SearchBuildingControl)"
                  rescue
                    page.evaluate(%Q{
                      (function(){
                        var el = document.querySelector('input#SearchBuildingControl');
                        if(!el) return false;
                        el.checked = false;
                        el.dispatchEvent(new Event('change', {bubbles:true}));
                        return true;
                      })();
                    }) rescue nil
                    puts "✔️ Unchecked Building Control via JS fallback"
                  end
                else
                  puts "ℹ️ SearchBuildingControl checkbox not present"
                end
              rescue => e
                puts "⚠️ Failed handling Building Control checkbox: #{e.class} - #{e.message}"
              end

            else
              raw_from = @params[:decided_from] || Date.today - DAYS
              date_fields = {
                'input[name="DateReceivedFrom"]' => raw_from.strftime('%d/%m/%Y'),
                'input#DateReceivedFrom' => raw_from.strftime('%d/%m/%Y'),
                'input[name="DateValidFrom"]' => raw_from.strftime('%d/%m/%Y'),
                'input#DateValidFrom' => raw_from.strftime('%d/%m/%Y'),
                'input[name="daterec_from:PARAM"]' => raw_from.strftime('%Y-%m-%d'),
                'input[name="date-from"]' => raw_from.strftime('%Y-%m-%d'),
                'input#DateIssuedFrom' => raw_from.strftime('%d/%m/%Y'),
                'input[name="DateIssuedFrom"]' => raw_from.strftime('%d/%m/%Y'),
                'input#DateDeterminedFrom' => raw_from.strftime('%Y-%m-%d')
              }

              filled = false
              date_fields.each do |sel, formatted|
                if page.query_selector(sel)
                  page.fill(sel, formatted)
                  puts "✔️ Filled date field #{sel} with #{formatted}"
                  filled = true
                  break
                end
              end
              puts "⚠️ No recognised date-from field found" unless filled
            end

            # --- PLANNING CHECKBOX HANDLING ---
            checkbox_selectors = [
              'input#SearchPlanning',
              'input[name="SearchPlanning"]',
              'input[aria-label*="Search planning"]',
              'input[aria-label*="Search Planning"]',
              'input[SearchPlanning]'
            ]

            checked = false
            checkbox_selectors.each do |sel|
              if page.query_selector(sel)
                begin
                  page.check(sel, force: true)
                  puts "✔️ Ticked planning checkbox #{sel}"
                  checked = true
                  break
                rescue => e
                  puts "⚠️ Failed to tick planning checkbox #{sel}: #{e.message}"
                end
              end
            end

            # Special handling for West Northamptonshire
            if !checked && @authority.name.downcase.include?("west northamptonshire")
              checked = true
              checkbox = page.locator("input#SearchPlanning")
              box = checkbox.bounding_box
              sleep 5
              if box
                page.mouse.click(box["x"] + box["width"]/2, box["y"] + box["height"]/2)
                puts "✔️ Clicked Planning checkbox by coordinates (West Northamptonshire fallback)"
                checked = true
              end
            end

            unless checked
              puts "❌ Planning checkbox could not be selected"
            end

            # --- SEARCH BUTTON HANDLING ---
            if @authority.name.downcase.include?("welwyn hatfield")
              # ✅ Use the specific PlanningButton for Welwyn Hatfield
              if page.query_selector('input.button.PlanningButton')
                page.click('input.button.PlanningButton', force: true)
                puts "✔️ Clicked Welwyn Hatfield Planning Search button"
              else
                raise "❌ Could not find Welwyn Hatfield PlanningButton search"
              end
            else
              button_selectors = [
                'button#submitBtn',
                'button#submitBtn2',
                'button#Search',
                'button.submitBtn#Search',
                'input[value="Search"]',
                'input[aria-label*="Search"]'
              ]
              clicked = false
              button_selectors.each do |sel|
                if page.query_selector(sel)
                  page.click(sel)
                  clicked = true
                  puts "✔️ Clicked search button #{sel}"
                  break
                end
              end
              raise "❌ Could not find a Search button" unless clicked
            end

            # Wait for results table to appear
            results_selectors = [
              'div#Planning-news_results_list table.tblResults tbody tr',
              'div#results table.tblResults tbody tr',
              'table.searchresultstbl tbody tr',
              'table.tblResults tbody tr',
              'table#results tbody tr',
              'div#Planning-news_results_list table.tblResults',
              'div#results table.tblResults',
              'table.searchresultstbl',
              'table.tblResults',
              'table#results',
              'results'
            ]

            results_query = if @authority.name.downcase.include?("welwyn hatfield")
              'ul#results li.search-results-item'
            else
              results_selectors.join(', ')
            end

            page.wait_for_selector(results_query, timeout: 15000)

            loop do
              rows = page.query_selector_all(results_query)
              puts "Found #{rows.size} applications on page #{page_number}."
              page_number += 1

              rows.each do |row|
                link = row.query_selector('a[href*="/Planning/Display/"], a[href*="/Application/Details/"]')
                unless link
                  puts "⚠️ No planning application link found in row, skipping."
                  next
                end

                app = Application.new
                app.scraped_at = Time.now
                app.authority_name = @authority.name

                app.council_reference = link.text_content.strip rescue nil
                href = link.get_attribute('href')
                app.info_url = href.start_with?('http') ? href : URI.join(@base_url, href).to_s

                begin
                  detail_page = context.new_page
                  detail_page.goto(app.info_url)
                  detail_page.wait_for_selector('tbody', timeout: 5000)

                  # =============================
                  # 📍 CHERWELL-SPECIFIC SCRAPING
                  # =============================
                  if @authority.name.downcase.include?('cherwell')
                    puts "🔎 Using Cherwell-specific detail extraction logic."

                    # 1️⃣ Extract Address (Location block)
                    location_td = detail_page.query_selector('td.fullwidth:has-text("Location") div.singlerowsize span')
                    if location_td
                      app.address = location_td.inner_text.strip.gsub(/\s+/, ' ')
                    end

                    # 2️⃣ Extract Description (Proposal block)
                    proposal_td = detail_page.query_selector('td.fullwidth:has-text("Proposal") div.singlerowsize span')
                    if proposal_td
                      app.description = proposal_td.inner_text.strip.gsub(/\s+/, ' ')
                    end

                    # 3️⃣ Extract Received Date
                    received_td = detail_page.query_selector('td.halfwidth:has-text("Received Date") div.twinrowsize span')
                    if received_td
                      begin
                        app.date_received = Date.parse(received_td.inner_text.strip)
                      rescue ArgumentError
                        puts "⚠️ Could not parse Received Date for Cherwell."
                      end
                    end


                  # ======================================
                  # 🏡 WELWYN HATFIELD–SPECIFIC SCRAPING
                  # ======================================
                  elsif @authority.name.downcase.include?('welwyn') || @authority.name.downcase.include?('hatfield')
                    puts "🔎 Using Welwyn Hatfield–specific detail extraction logic."

                    # 1️⃣ Extract Address (Location block)
                    location_field = detail_page.query_selector('td.halfWidth label.form__label:has-text("Location") + div.form__field span')
                    if location_field
                      app.address = location_field.inner_text.strip.gsub(/\s+/, ' ')
                    else
                      puts "⚠️ No Location found for Welwyn Hatfield."
                    end

                    # 2️⃣ Extract Description (Proposal block)
                    proposal_field = detail_page.query_selector('td.halfWidth label.form__label:has-text("Proposal") + div.form__field span')
                    if proposal_field
                      app.description = proposal_field.inner_text.strip.gsub(/\s+/, ' ')
                    else
                      puts "⚠️ No Proposal found for Welwyn Hatfield."
                    end

                    # 3️⃣ Extract Received Date
                    received_field = detail_page.query_selector('td label.form__label:has-text("Date Received") + div.form__field span')
                    if received_field
                      begin
                        date_text = received_field.inner_text.strip
                        app.date_received = Date.strptime(date_text, '%d/%m/%Y')
                      rescue ArgumentError
                        puts "⚠️ Could not parse Date Received (#{date_text}) for Welwyn Hatfield."
                      end
                    else
                      puts "⚠️ No Date Received found for Welwyn Hatfield."
                    end
                  # =============================================
                  # 🏙️ WEST NORTHAMPTONSHIRE–SPECIFIC SCRAPING
                  # =============================================
                  elsif @authority.name.downcase.include?('northamptonshire') || @authority.name.downcase.include?('wnc')
                    puts "🔎 Using West Northamptonshire–specific detail extraction logic."

                    # 1️⃣ Extract Address (Location block)
                    location_span = detail_page.query_selector('td.fullwidth:has-text("Location") div.singlerowsize span')
                    if location_span
                      app.address = location_span.inner_text.strip.gsub(/\s+/, ' ')
                    else
                      puts "⚠️ No Location found for West Northamptonshire."
                    end

                    # 2️⃣ Extract Description (Proposal block)
                    proposal_span = detail_page.query_selector('td.fullwidth:has-text("Proposal") div.singlerowsize span')
                    if proposal_span
                      app.description = proposal_span.inner_text.strip.gsub(/\s+/, ' ')
                    else
                      puts "⚠️ No Proposal found for West Northamptonshire."
                    end

                    # 3️⃣ Extract Received Date
                    received_span = detail_page.query_selector('td.halfwidth:has-text("Received Date") div.twinrowsize span')
                    if received_span
                      begin
                        date_text = received_span.inner_text.strip
                        app.date_received = Date.strptime(date_text, '%d/%m/%Y')
                      rescue ArgumentError
                        puts "⚠️ Could not parse Received Date (#{date_text}) for West Northamptonshire."
                      end
                    else
                      puts "⚠️ No Received Date found for West Northamptonshire."
                    end

                    # 4️⃣ Extract Validated Date (if available)
                    validated_span = detail_page.query_selector('td.halfwidth:has-text("Valid Date") div.twinrowsize span')
                    if validated_span
                      begin
                        val_text = validated_span.inner_text.strip
                        app.date_validated = Date.strptime(val_text, '%d/%m/%Y')
                      rescue ArgumentError
                        puts "⚠️ Could not parse Valid Date (#{val_text}) for West Northamptonshire."
                      end
                    end
                  


                  else
                    # ====================================================
                    # 🔧 DEFAULT GENERIC FIELD EXTRACTION (all other sites)
                    # ====================================================
                    rows = detail_page.query_selector_all('tbody tr')
                    rows.each do |tr|
                      tds = tr.query_selector_all('td')
                      next unless tds.size == 2

                      field = tds[0].inner_text.strip
                      value = tds[1].inner_text.strip

                      case field
                      when 'Location Address'
                        app.address = value
                      when 'Proposal'
                        app.description = value
                      when 'Status'
                        app.status = value
                      end
                    end

                    # === FLEXIBLE FIELD RECOVERY SECTION ===

                    # 1️⃣ Bournemouth / Poole-style summaryTbl tables
                    if app.address.nil? || app.date_received.nil?
                      summary_tables = detail_page.query_selector_all('table.summaryTbl, table.summaryTbl.table')
                      summary_tables.each do |table|
                        trs = table.query_selector_all('tr')
                        trs.each do |tr|
                          cells = tr.query_selector_all('td')
                          next if cells.empty?

                          label = cells[0]&.inner_text&.strip&.downcase
                          value = cells[1]&.inner_text&.strip rescue nil
                          next unless label && value

                          if app.address.nil? && label.include?("location address")
                            app.address = value
                          elsif app.date_received.nil? && label.include?("application received")
                            app.date_received = Date.parse(value) rescue nil
                          end
                        end
                      end
                    end

                    # 2️⃣ Generic Proposal text
                    if app.description.nil?
                      proposal_div = detail_page.query_selector('td.fullwidth div.singlerowsize span, td.fullwidth span')
                      app.description = proposal_div.inner_text.strip if proposal_div
                    end

                    # 3️⃣ Received Date (generic)
                    if app.date_received.nil?
                      received_field = detail_page.query_selector('td:has-text("Received Date") + td span, td:has-text("Received Date") div span')
                      if received_field
                        app.date_received = Date.parse(received_field.inner_text.strip) rescue nil
                      end
                    end

                    # 4️⃣ Fallback Address
                    if app.address.nil?
                      alt_addr = detail_page.query_selector('td:has-text("Location") + td, td:has-text("Address") + td')
                      app.address = alt_addr.inner_text.strip if alt_addr
                    end

                    # 5️⃣ Fallback Proposal & Dates (form__label structure)
                    if app.description.nil?
                      proposal_field = detail_page.query_selector('label.form__label:has-text("Proposal") + div.form__field span')
                      app.description = proposal_field.inner_text.strip if proposal_field
                    end
                    if app.date_received.nil?
                      received_field = detail_page.query_selector('label.form__label:has-text("Date Received") + div.form__field span')
                      app.date_received = Date.parse(received_field.inner_text.strip) rescue nil
                    end
                    if app.date_validated.nil?
                      validated_field = detail_page.query_selector('table.progressBarTbl td')
                      if validated_field
                        value = validated_field.inner_text.strip
                        app.date_validated = Date.parse(value) rescue nil
                      end
                      app.date_received ||= app.date_validated
                    end
                  end

                  # === END FLEXIBLE FIELD RECOVERY ===
                  detail_page.close

                rescue => e
                  puts "⚠️ Failed to fetch details for #{app.council_reference}: #{e.message}"
                end

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

                if app.valid?
                  apps << app
                  puts "✅ Valid app: #{app.to_hash}"
                else
                  puts "⛔ Skipping invalid app: #{app.council_reference.inspect}"
                end
              end

              next_link = page.query_selector('a[aria-label="Next Page."], a[aria-label="Next"]')
              break unless next_link

              begin
                page.evaluate("el => el.click()", arg: next_link)
                page.wait_for_selector(results_query, timeout: 5000)
                page.wait_for_timeout(1000)
              rescue StandardError
                puts "⚠️ Timeout or no more results during next page navigation."
                break
              end
            end

            browser.close

          end
        end
      rescue Timeout::Error
        puts "❌ Timeout after 15 minutes while scraping #{@authority.name} (AdvancedSearch). " \
            "Returning partial results (#{apps.size} applications already collected)."
      rescue StandardError => e
        puts "❌ Unexpected error in AdvancedSearch scraper for #{@authority.name}: #{e.class} - #{e.message}"
      end

      puts "  → #{apps.size} applications found."
      apps        
    end
  end
end
