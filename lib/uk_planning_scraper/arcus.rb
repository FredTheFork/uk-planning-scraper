# frozen_string_literal: true
require_relative 'playwright_compat'
require 'date'
require 'time'
require 'uri'
require 'set'
require 'timeout'
#ENV['PLAYWRIGHT_BROWSERS_PATH'] = File.expand_path('../playwright-browsers', __dir__)

DAYS = 7 unless defined?(DAYS)

module UKPlanningScraper
  class ArcusScraper
    def self.scrape(authority, params = {}, options = {})
      new(authority, params, options).scrape
    end

    def initialize(authority, params, options)
      @authority = authority
      @params = params
      @options = options
    end

    def scrape
      puts "🔍 Scraping Arcus system for #{@authority.name}"

      apps = []
      seen_references = Set.new
      begin
        Timeout.timeout(900) do
          Playwright.create(playwright_cli_executable_path: 'npx playwright') do |playwright|
            browser = playwright.chromium.launch(headless: false)
            context = browser.new_context
            page = context.new_page

            page.goto(@authority.url, timeout: 60_000)

            # -----------------
            # Handle advanced search
            # -----------------
            begin
              page.wait_for_selector('button.pr-buttonLink.slds-m-bottom_xx-large', timeout: 15_000)
              page.click('button.pr-buttonLink.slds-m-bottom_xx-large')
            rescue => e
              puts "❌ Could not click Advanced Search button: #{e.message}"
              return []
            end

            # -----------------
            # Handle dropdown (select "Planning Applications")
            # -----------------
            begin
              page.wait_for_selector('button[role="combobox"]', timeout: 20_000).click
              dropdown_element = page.locator('button[role="combobox"]')
              current_value = dropdown_element.locator('span.slds-truncate').inner_text.strip rescue nil

              authority_lc = @authority.name.to_s.downcase

              no_change_authorities = %w[ashford folkestone salford bromley]
              two_down_authorities = ['bracknell forest', 'erewash', 'haringey', 'milton keynes', 'reading', 'rochdale', 'wrexham']
              if no_change_authorities.any? { |a| authority_lc.include?(a) }
                puts "ℹ️ #{@authority.name}: dropdown already correct — skipping selection."
              elsif ['epping forest', 'bracknell forest'].any? { |a| authority_lc.include?(a) }
                page.keyboard.press('ArrowDown')
                sleep 0.1
                page.keyboard.press('ArrowDown')
                sleep 0.3
                page.keyboard.press('Enter')
                sleep 0.5
                puts "✔️ Epping Forest: selected 'Planning Applications' with double cycle."
              else
                if current_value != 'Planning Applications'
                  down_count = two_down_authorities.any? { |a| authority_lc.include?(a) } ? 2 : 1
                  down_count.times do
                    page.keyboard.press('ArrowDown')
                    sleep 0.4
                  end
                  page.keyboard.press('Enter')
                  puts "✔️ #{@authority.name}: selected 'Planning Applications' (#{down_count} x ArrowDown + Enter)."
                else
                  puts "ℹ️ Planning Applications already selected (dropdown shows: #{current_value.inspect})."
                end
              end
              
              # Wait for form to be ready after dropdown selection
              page.wait_for_timeout(1000)
              page.wait_for_selector('input.slds-input[placeholder="dd/mm/yyyy"]', timeout: 15_000)
            rescue => e
              puts "⚠️ Dropdown selection error for #{@authority.name}: #{e.class} - #{e.message}"
            end

            # -----------------
            # Date input handling (Arcus LWC inputs, FROM only)
            # -----------------
            begin
              from_date_obj = (@params[:validated_from] || Date.today - (defined?(DAYS) ? DAYS : 7))
              from_str = from_date_obj.strftime('%d/%m/%Y')
              iso_from = from_date_obj.strftime('%Y-%m-%d')

              # 🟦 Special case: Haringey uses MM/DD/YYYY format
              if @authority.name.downcase.include?("haringey")
                from_str = from_date_obj.strftime('%m/%d/%Y')
                iso_from = from_date_obj.strftime('%Y-%m-%d')
                puts "🔧 Adjusted Haringey date format to MM/DD/YYYY → #{from_str}"
              end
              # 🟦 Special case: Rochdale uses MM/DD/YYYY format
              if @authority.name.downcase.include?("rochdale")
                from_str = from_date_obj.strftime('%m/%d/%Y')
                iso_from = from_date_obj.strftime('%Y-%m-%d')
                puts "🔧 Adjusted Rochdale date format to MM/DD/YYYY → #{from_str}"
              end
              # 🟦 Special case: Epping Forest uses MM/DD/YYYY format
              if @authority.name.downcase.include?("epping forest")
                from_str = from_date_obj.strftime('%m/%d/%Y')
                iso_from = from_date_obj.strftime('%Y-%m-%d')
                puts "🔧 Adjusted Epping Forest date format to MM/DD/YYYY → #{from_str}"
              end
              set_from_date = lambda do |human_val, iso_val|
                # Detect if using date type input (ISO format) or text input (dd/mm/yyyy format)
                date_input = page.locator('input[type="date"]').first
                is_date_type = date_input.count > 0
                
                if is_date_type
                  # Handle input[type="date"] - use ISO format directly
                  begin
                    date_input.fill(iso_val)
                    date_input.evaluate('el => { el.dispatchEvent(new Event("change", { bubbles: true })); return el.value; }')
                    sleep 0.2
                    actual = date_input.input_value
                    success = actual == iso_val
                    puts "🔧 Using date-type input for #{@authority.name}, set to #{actual}" if success
                    return [success, actual]
                  rescue => e
                    puts "⚠️ Date-type input failed: #{e.message}"
                  end
                end
                
                # Fallback to original text input handling
                js_set = <<~JS
                  (() => {
                    const els = Array.from(document.querySelectorAll('input.slds-input[placeholder="dd/mm/yyyy"]'));
                    const el = els[0];
                    if (!el) return null;
                    try { el.focus(); } catch(e){}
                    try { el.value = "#{human_val}"; } catch(e){}
                    try { el.setAttribute('value', "#{human_val}"); } catch(e){}
                    try { el.dispatchEvent(new Event('input', { bubbles: true })); } catch(e){}
                    try { el.dispatchEvent(new Event('change', { bubbles: true })); } catch(e){}
                    try { el.blur(); } catch(e){}
                    return el.value || null;
                  })();
                JS

                actual = page.evaluate(js_set) rescue nil
                if actual.to_s.strip != human_val
                  begin
                    input_loc = page.locator('input.slds-input[placeholder="dd/mm/yyyy"]').nth(0)
                    input_loc.click rescue nil
                    input_loc.fill('') rescue nil
                    input_loc.type(human_val, delay: 30) rescue nil

                    if @authority.name.downcase.include?("epping forest")
                      page.keyboard.press('Tab') rescue nil
                      page.wait_for_timeout(100)
                      page.keyboard.press('Tab') rescue nil
                    else
                      page.keyboard.press('Enter') rescue nil
                    end

                    page.wait_for_timeout(250)
                    actual = page.evaluate(js_set) rescue actual
                  rescue => _e
                  end
                end

                # --- ISO fallback ---
                if actual.to_s.strip != human_val
                  js_set_iso = <<~JS
                    (() => {
                      const els = Array.from(document.querySelectorAll('input.slds-input[placeholder="dd/mm/yyyy"]'));
                      const el = els[0];
                      if (!el) return null;
                      try { el.focus(); } catch(e){}
                      try { el.value = "#{iso_val}"; } catch(e){}
                      try { el.setAttribute('value', "#{iso_val}"); } catch(e){}
                      try { el.dispatchEvent(new Event('input', { bubbles: true })); } catch(e){}
                      try { el.dispatchEvent(new Event('change', { bubbles: true })); } catch(e){}
                      try { el.blur(); } catch(e){}
                      return el.value || null;
                    })();
                  JS
                  actual = page.evaluate(js_set_iso) rescue actual
                end

                page.wait_for_timeout(200)
                final = actual.to_s.strip
                success = final == human_val || final == iso_val || final.include?(human_val.split('/').last)
                [success, final]
              end

              # Try multiple selectors for date inputs (different Arcus councils use different structures)
              lwc_inputs = page.locator('input.slds-input[placeholder="dd/mm/yyyy"]')
              count = lwc_inputs.count

              if count == 0
                lwc_inputs = page.locator('input[placeholder="dd/mm/yyyy"]')
                count = lwc_inputs.count
              end
              
              if count == 0
                # Allerdale and newer Arcus councils use date type inputs
                lwc_inputs = page.locator('input[type="date"].slds-input')
                count = lwc_inputs.count
              end
              
              if count == 0
                # Try any date input
                lwc_inputs = page.locator('input[type="date"]')
                count = lwc_inputs.count
              end

              if count == 0
                puts "❌ No Arcus date inputs found. Continuing without date filters."
              else
                # --- Standard attempt for all councils ---
                ok, actual_val = set_from_date.call(from_str, iso_from)
                if ok
                  puts "✔️ Set FROM date to #{actual_val} (requested #{from_str})"
                else
                  puts "⚠️ FROM date might not have stuck; actual value: #{actual_val.inspect} (requested #{from_str} or #{iso_from})"
                end
              end
            rescue => e
              puts "❌ Error filling FROM date input for #{@authority.name}: #{e.class} - #{e.message}"
              File.write("debug_output.html", page.content)
              return []
            end




            # -----------------
            # Keyword handling
            # -----------------
            if @params[:keywords]
              keyword_box = page.locator('textarea.slds-textarea') rescue nil
              keyword_box&.fill(@params[:keywords]) if keyword_box
            end

            # -----------------
            # Search button
            # -----------------
            search_button = page.locator('button.slds-button.slds-button_brand').all.find { |btn| btn.inner_text.strip == 'Search' }
            if search_button.nil?
              puts "❌ Search button not found."
              File.write("debug_output.html", page.content)
              return []
            end
            search_button.click
            page.wait_for_timeout(300)
            # -----------------
            # SPECIAL HANDLING: Epping Forest Table View (with pagination)
            # -----------------
            if eppingforest?
              puts "Epping Forest detected — scraping directly from table results (no detail pages)"

              begin
                # Switch to table view
                page.wait_for_selector('div[arcuscommunity-pr_result_pr_result] button', timeout: 30_000)
                page.locator('div[arcuscommunity-pr_result_pr_result] button').click
                page.wait_for_selector('tbody.pr-table__body tr', timeout: 30_000)
                puts "Switched to table view"

                page_number = 1
                stop_scraping = false

                loop do
                  break if stop_scraping

                  rows = page.locator('tbody.pr-table__body tr')
                  row_count = rows.count
                  puts "Page #{page_number}: Found #{row_count} results in table view."

                  (0...row_count).each do |i|
                    tr = rows.nth(i)
                    tds = tr.locator('td')
                    next unless tds.count >= 6

                    ref_text = tds.nth(0).text_content.strip rescue nil
                    href = tds.nth(0).locator('a').get_attribute('href') rescue nil
                    valid_date_str = tds.nth(5).text_content.strip rescue nil
                    valid_date = parse_date(valid_date_str)
                    address = tds.nth(1).text_content.strip rescue nil
                    proposal = tds.nth(2).text_content.strip rescue nil
                    next if ref_text.nil? || href.nil?

                    if valid_date && valid_date < from_date_obj
                      puts "Stopping — valid date #{valid_date} < cutoff #{from_str}"
                      stop_scraping = true
                      break
                    end

                    info_url = href.start_with?('http') ? href : URI.join(@authority.url, href).to_s
                    next if seen_references.include?(ref_text)

                    # === Expand the row to reveal Address and Proposal ===
                    expander = tr.locator('td.pr-table__row-expander button, button[title="Show more"]')
                    if expander.count > 0
                      expander.first.click(force: true)
                      page.wait_for_timeout(400) # let it expand
                    end

                    # === Build Application object (no detail page!) ===
                    app = Application.new
                    app.authority_name    = @authority.name
                    app.council_reference = ref_text
                    app.date_received     = valid_date  # from table column 5
                    app.decision          = nil
                    app.info_url          = info_url
                    app.address           = address
                    app.description       = proposal
                    app.documents_count   = 0
                    app.documents_url     = nil

                    # Optional: collapse row again to keep UI clean
                    if expander.count > 0
                      expander.first.click(force: true)
                      page.wait_for_timeout(100)
                    end

                    if app.valid?
                      puts "------------------------------------------------------------"
                      puts "  Ref:        #{app.council_reference}"
                      puts "  Address:    #{app.address}"
                      puts "  Description: #{app.description&.gsub(/\s+/, ' ')&.strip}"
                      puts "  Date:       #{app.date_received}"
                      puts "  Link:       #{app.info_url}"
                      puts "------------------------------------------------------------"

                      seen_references << ref_text
                      apps << app
                      puts "  Added application #{ref_text}"
                    else
                      puts "Skipped invalid application (#{ref_text}) — missing data"
                    end

                    page.wait_for_timeout(200)
                  end

                  # === PAGINATION (unchanged) ===
                  break if stop_scraping

                  next_button = page.locator('li.pr-pagination__item__next a.pr-pagination__link')
                  if next_button.count > 0 && next_button.first.evaluate('el => el && el.offsetParent !== null')
                    puts "Moving to next page (#{page_number + 1})..."
                    next_button.first.click
                    page.wait_for_timeout(4000)
                    page.wait_for_selector('tbody.pr-table__body tr', timeout: 30_000)
                    page_number += 1
                  else
                    puts "No more pages found after page #{page_number}."
                    break
                  end
                end

              rescue => e
                puts "Epping Forest table scrape error: #{e.class} - #{e.message}"
                puts e.backtrace.first(10).join("\n")
              ensure
                context.close
                browser.close
              end

              return apps  # keep your original return here
            end


            # -----------------
            # RESULTS LOOP
            # -----------------
            page_number = 1
            stop_scraping = false

            loop do
              break if stop_scraping

              begin
                # Wait for results container (handles Allerdale and other Arcus councils)
                page.wait_for_selector('div[arcuscommunity-pr_result_pr_result], .pr-result-header', timeout: 60_000)
                
                # Try multiple selectors for app blocks to handle different Arcus layouts
                app_blocks = page.locator('div.slds-form.slds-box')
                block_count = app_blocks.count
                
                # Fallback for Allerdale-style nested structure
                if block_count == 0
                  app_blocks = page.locator('c-pr_articles div.slds-form.slds-box')
                  block_count = app_blocks.count
                  puts "🔧 Using Allerdale-style nested selector, found #{block_count} blocks" if block_count > 0
                end
                
                puts "📄 Page #{page_number}: Found #{block_count} application blocks."

                (0...block_count).each do |bi|
                  block = app_blocks.nth(bi)

                  begin
                    # --- Date filtering by authority ---
                    if eppingforest?
                      tds = block.locator('td')
                      valid_date_str = tds.nth(5).text_content.strip rescue nil
                      valid_date = parse_date(valid_date_str)
                      if valid_date && valid_date < from_date_obj
                        puts "⏹️ Stopping — valid date #{valid_date} is before cutoff (#{from_str})."
                        stop_scraping = true
                        break
                      end
                    elsif haringey?
                      decision_label = block.locator('label:has-text("Decision Notice Sent Date")')
                      decision_value = decision_label.count > 0 ? decision_label.first.evaluate('el => el.nextElementSibling?.innerText || ""') : nil
                      decision_date = parse_date(decision_value)
                      next if decision_date && decision_date < from_date_obj
                    end

                    # --- Reference link extraction ---
                    ref_link = if block.locator('lightning-formatted-url a').count > 0
                                block.locator('lightning-formatted-url a').first
                              else
                                anchors = block.locator('a')
                                chosen = nil
                                (0...anchors.count).each do |ai|
                                  ahref = anchors.nth(ai).get_attribute('href') rescue nil
                                  if ahref && (ahref.include?('/s/detail/') || ahref.include?('/pr/') || ahref.match?(/\/s\/detail/i))
                                    chosen = anchors.nth(ai)
                                    break
                                  end
                                end
                                chosen
                              end

                    unless ref_link && ref_link.count > 0
                      puts "⚠️ No detail link found for block #{bi+1}, skipping."
                      next
                    end

                    ref_text = ref_link.text_content&.strip rescue nil
                    href = ref_link.get_attribute('href') rescue nil
                    info_url = if href && !href.to_s.empty?
                                href.start_with?('http') ? href : URI.join(@authority.url, href).to_s
                              end

                    next if ref_text.nil? || info_url.nil? || seen_references.include?(ref_text)

                    puts "➡️ Opening details for #{ref_text} (#{info_url})"

                    detail_page = context.new_page
                    begin
                      detail_page.goto(info_url, timeout: 60_000)
                      detail_page.wait_for_load_state
                    rescue => e
                      puts "⚠️ Failed to open detail page for #{ref_text}: #{e.class} - #{e.message}"
                      detail_page.close rescue nil
                      next
                    end

                    # --- Extract details ---
                    summary_map = {}
                    rows_locator = detail_page.locator('dl[class*="pr-summary-list"] .pr-summary-list__row')
                    rows_locator = detail_page.locator('div.pr-summary-list__row, .pr-summary-list__row') if rows_locator.count == 0

                    (0...rows_locator.count).each do |ri|
                      r = rows_locator.nth(ri)
                      key = r.locator('dt').first&.text_content&.strip rescue nil
                      val = r.locator('dd').first&.text_content&.strip rescue nil
                      summary_map[key] = val if key && val
                    end

                    if summary_map.empty?
                      dt_locator = detail_page.locator('dt')
                      (0...dt_locator.count).each do |i|
                        dt = dt_locator.nth(i)
                        key = dt.text_content&.strip rescue nil
                        next unless key && !key.empty?
                        val = dt.evaluate('d => { const sib = d.nextElementSibling; return sib ? sib.innerText : null }') rescue nil
                        val = val.strip if val
                        summary_map[key] = val if val && !val.empty?
                      end
                    end

                    # --- Assign fields ---
                    description    = summary_map['Description'] || summary_map['Proposal'] || summary_map['Proposal Description']
                    address        = summary_map['Site address'] || summary_map['Site Address'] || summary_map['Address']
                    status         = summary_map['Status']&.strip
                    date_validated = parse_date(summary_map['Valid date'] || summary_map['Valid Date'] || summary_map['Date Valid'])
                    date_received  = parse_date(summary_map['Received Date'] || summary_map['Date Received'])
                    decision_date  = parse_date(summary_map['Decision Date'] || summary_map['Decision date'] || summary_map['Decision Notice Sent Date'])

                    # --- Skip if before cutoff ---
                    comparison_date = date_validated || decision_date
                    if comparison_date && comparison_date < from_date_obj
                      puts "⚠️ Skipping #{ref_text} — comparison date #{comparison_date} before cutoff #{from_str}"
                      detail_page.close rescue nil
                      next
                    end

                    # --- Build Application object ---
                    app = Application.new
                    app.scraped_at        = Time.now
                    app.authority_name    = @authority.name
                    app.council_reference = ref_text
                    app.date_received     = date_received
                    app.date_validated    = date_validated
                    app.status            = status
                    app.decision          = nil
                    app.date_decision     = decision_date
                    app.info_url          = info_url
                    app.address           = address
                    app.description       = description
                    app.documents_count   = 0
                    app.documents_url     = nil
                    sleep 1
                ## === BEGIN: OPTIONAL DETAIL FILL-IN SECTION ===
                    # 📄 Arcus: Fill missing description (robust version)
                    # 🏠 Arcus: Fill missing address
                    if app.address.nil?
                      addr_field = detail_page.query_selector('div.pr-summary-list__row:has(dt:has-text("Site address")) dd.pr-summary-list__value')
                      app.address = addr_field.inner_text.strip if addr_field
                    end

                    # 📄 Arcus: Fill missing description
                    if app.description.nil?
                      desc_field = detail_page.query_selector('div.pr-summary-list__row:has(dt:has-text("Description")) dd.pr-summary-list__value')
                      app.description = desc_field.inner_text.strip if desc_field
                    end

                    # 📄 Arcus: Fill missing description
                    if app.description.nil?
                      desc_field = detail_page.query_selector('div.pr-summary-list__row:has(dt:has-text("Proposed W")) dd.pr-summary-list__value')
                      app.description = desc_field.inner_text.strip if desc_field
                    end

                    # 📅 Arcus: Fill missing received/valid date (ultra-robust version)
                    if app.date_received.nil?
                      puts 'peper'
                      begin
                        # Try main Arcus structure (semantic match)
                        date_field = detail_page.query_selector('div.pr-summary-list__row:has(dt:has-text("Valid date")) dd.pr-summary-list__value')

                        # Fallbacks for variant markup or nested structure
                        if date_field.nil?
                          date_field = detail_page.query_selector('dl.pr-summary-list div:has(dt:has-text("Valid date")) dd, div:has(dt:has-text("Valid date")) dd')
                        end

                        # Extra safeguard — match any dt containing "Valid" or "Received"
                        if date_field.nil?
                          date_field = detail_page.query_selector('div.pr-summary-list__row:has(dt:has-text("Valid")) dd.pr-summary-list__value, div.pr-summary-list__row:has(dt:has-text("Received")) dd.pr-summary-list__value')
                        end

                        if date_field
                          raw_date = date_field.inner_text.strip.gsub(/\s+/, '')
                          app.date_received = Date.parse(raw_date) rescue nil
                          puts "✅ Filled date_received from Arcus detail: #{raw_date}"
                        else
                          puts "⚠️ Could not locate Valid/Received date field in Arcus detail."
                        end
                        # 📝 Arcus: Fill missing description
                        if app.description.to_s.strip.empty?
                          begin
                            desc_field = detail_page.query_selector('div.pr-summary-list__row:has(dt:has-text("Proposal")) dd.pr-summary-list__value')
                            # Fallback: some Arcus sites nest it differently
                            if desc_field.nil?
                              desc_field = detail_page.query_selector('dl.pr-summary-list div:has(dt:has-text("Proposal")) dd, div:has(dt:has-text("Proposal")) dd')
                            end

                            if desc_field
                              app.description = desc_field.inner_text.strip
                              puts "✅ Filled description from Arcus detail: #{app.description[0..80]}..."
                            else
                              puts "⚠️ Could not locate Proposal/Description field in Arcus detail."
                            end
                          rescue => e
                            puts "⚠️ Error while parsing Arcus description: #{e.class} - #{e.message}"
                          end
                        end
                        # 🏠 Arcus: Fill missing address
                        if app.address.to_s.strip.empty?
                          begin
                            addr_field = detail_page.query_selector('div.pr-summary-list__row:has(dt:has-text("Address")) dd.pr-summary-list__value')
                            addr_field ||= detail_page.query_selector('dl.pr-summary-list div:has(dt:has-text("Address")) dd, div:has(dt:has-text("Address")) dd')
                            if addr_field
                              app.address = addr_field.inner_text.strip
                              puts "✅ Filled address: #{app.address}"
                            else
                              puts "⚠️ Could not locate Address field."
                            end
                          rescue => e
                            puts "⚠️ Error while parsing Arcus address: #{e.class} - #{e.message}"
                          end
                        end
                        # 📝 Arcus: Fill missing description
                        if app.description.to_s.strip.empty?
                          begin
                            desc_field = detail_page.query_selector('div.pr-summary-list__row:has(dt:has-text("Proposal")) dd.pr-summary-list__value')
                            desc_field ||= detail_page.query_selector('dl.pr-summary-list div:has(dt:has-text("Proposal")) dd, div:has(dt:has-text("Proposal")) dd')
                            if desc_field
                              app.description = desc_field.inner_text.strip
                              puts "✅ Filled description: #{app.description[0..80]}..."
                            else
                              puts "⚠️ Could not locate Proposal/Description field."
                            end
                          rescue => e
                            puts "⚠️ Error while parsing Arcus description: #{e.class} - #{e.message}"
                          end
                        end
                        # 📅 Arcus: Fill missing received date
                        if app.date_received.nil?
                          begin
                            date_field = detail_page.query_selector('div.pr-summary-list__row:has(dt:has-text("Received Date")) dd.pr-summary-list__value')
                            date_field ||= detail_page.query_selector('dl.pr-summary-list div:has(dt:has-text("Received Date")) dd, div:has(dt:has-text("Received Date")) dd')
                            if date_field
                              date_text = date_field.inner_text.strip
                              app.date_received = Date.parse(date_text) rescue nil
                              puts "✅ Filled received date: #{app.date_received}"
                            else
                              puts "⚠️ Could not locate Received Date field."
                            end
                          rescue => e
                            puts "⚠️ Error while parsing Arcus date: #{e.class} - #{e.message}"
                          end
                        end

                      rescue => e
                        puts "⚠️ Error while parsing Arcus date: #{e.class} - #{e.message}"
                      end
                    end


                  # === END: OPTIONAL DETAIL FILL-IN SECTION ===

                    if app.valid?
                      seen_references << ref_text
                      puts "✅ Valid app: #{app.to_hash}"
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
                      puts "  → Added application #{app.council_reference}"
                    else
                      puts "⚠️ Skipped invalid application (#{ref_text})"
                    end

                  rescue => e
                    puts "⚠️ Error extracting detail block #{bi+1}: #{e.class} - #{e.message}"
                  ensure
                    detail_page.close rescue nil
                    page.wait_for_timeout(200)
                  end
                end
              rescue => e
                puts "❌ Could not load results: #{e.message}"
                File.write("debug_output.html", page.content)
                break
              end

              break if stop_scraping
              next_button = page.locator('li.pr-pagination__item__next a.pr-pagination__link')
              break unless next_button.count > 0 && next_button.first.evaluate('el => el && el.offsetParent !== null')
              puts "➡️ Moving to next page..."
              next_button.first.click
              page.wait_for_timeout(4000)
              page_number += 1
            end


            context.close
            browser.close
          end
        end
      rescue Timeout::Error
        puts "❌ Timeout after 15 minutes while scraping #{@authority.name} (Arcus). " \
             "Returning partial results (#{apps.size} applications already collected)."
      rescue StandardError => e
        puts "❌ Unexpected error in Arcus scraper for #{@authority.name}: #{e.class} - #{e.message}"
      end

      apps
    end


    private


    def parse_date(str)
      return nil if str.nil? || str.empty?
      s = str.to_s.strip.gsub("\u00A0", ' ').strip
      Date.strptime(s, '%d/%m/%Y') rescue nil
    end


    def eppingforest?
      @authority.name.downcase.include?("epping forest")
    end


    def haringey?
      @authority.name.downcase.include?("haringey")
    end
  end
end
