# frozen_string_literal: true
require 'addressable/uri'
require 'mechanize'
require 'date'
require 'playwright'
require_relative 'utils'
require_relative 'application'

module UKPlanningScraper
  class Randoms2Scraper

    # ============================================================
    #  ENTRY POINT — Called by Authority#scrape_randoms1
    # ============================================================
    def self.scrape(authority, params = {}, options = {})
      puts "🛠 Running Randoms2Scraper for #{authority.name} (#{authority.url})"

      case authority.name.strip
      when /Ipswich/i
        scrape_ipswich(authority, params)
      when /Isle of Anglesey/i
        scrape_isle_of_anglesey(authority, params)
      when /Isles of Scilly/i
        scrape_isles_of_scilly(authority, params)
      when /Kensington and Chelsea/i
        scrape_kensington_and_chelsea(authority, params)
      when /Kirklees/i
        scrape_kirklees(authority, params)
      when /Leicester/i
        scrape_leicester(authority, params)
      when /Mole Valley/i
        scrape_mole_valley(authority, params)
      when /East Staffordshire/i
        scrape_mole_valley(authority, params)
      when /North Lincolnshire/i
        scrape_north_lincolnshire(authority, params)
      when /Nuneaton and Bedworth/i
        scrape_nuneaton_and_bedworth(authority, params)
      when /Preston/i
        scrape_preston(authority, params)
      when /Redcar and Cleveland/i
        scrape_redcar_and_cleveland(authority, params)
      when /Ribble Valley/i
        scrape_ribble_valley(authority, params)
      when /Rochford/i
        scrape_rochford(authority, params)
      when /Rotherham/i
        scrape_rotherham(authority, params)
      when /Sedgemoor/i
        scrape_sedgemoor(authority, params)
      when /Somerset West and Taunton/i
        scrape_somerset_west_and_taunton(authority, params)

      else
        puts "⚠️ No Randoms1 scraper implementation for #{authority.name}"
        []
      end

    rescue => e
      puts "❌ Randoms1Scraper error for #{authority.name}: #{e.class} - #{e.message}"
      puts e.backtrace.first
      []
    end



    def self.scrape_ipswich(authority, params)
      puts "➡️ Launching Playwright for Ipswich"
      results = []
      from = params[:validated_from] || params[:received_from] || (Date.today - DAYS)
      to   = params[:validated_to]   || params[:received_to]   || Date.today

      from_str = from.strftime('%d/%m/%Y')
      to_str   = to.strftime('%d/%m/%Y')
      begin
        Timeout.timeout(900) do 
          Playwright.create(playwright_cli_executable_path: 'npx playwright') do |playwright|
            browser = playwright.chromium.launch(headless: false)
            context = browser.new_context
            page = context.new_page
            page.goto(authority.url)

            # --- SEARCH FORM ---
            puts "⏳ Waiting for Advanced Search toggle"
            page.wait_for_selector('img#imgBasic', timeout: 10000)
            page.click('img#imgBasic')

            puts "⏳ Waiting for date fields"
            page.wait_for_selector('input[name="txtValStartDate"]', timeout: 10000)
            page.wait_for_selector('input[name="txtValEndDate"]', timeout: 10000)

            puts "📝 Filling in dates: #{from_str} → #{to_str}"
            page.fill('input[name="txtValStartDate"]', from_str)
            page.fill('input[name="txtValEndDate"]', to_str)

            puts "🔍 Clicking search"
            page.click('input#imgSubmit')

            # --- Helper lambdas ---
            pw_get_field = lambda do |p, sel|
              loc = p.locator(sel)
              return nil if loc.count == 0
              begin
                loc.input_value
              rescue StandardError
                loc.text_content&.strip
              end
            end

            parse_normalised_date = lambda do |raw|
              return nil if raw.nil?
              s = raw.to_s.strip
              s = s.gsub(/(\d+)(?:st|nd|rd|th)/i, '\1') # remove ordinals
              UKPlanningScraper::Utils.parse_date(s)
            end

            # --- RESULTS LOOP ---
            loop do
              puts "⏳ Waiting for results table"
              page.wait_for_selector('table#dgSearchResults tr:nth-child(2)', timeout: 15000)

              rows = page.locator('table#dgSearchResults tr').all
              puts "📋 Found #{[rows.length - 1, 0].max} result rows"

              rows[1..].each_with_index do |row, idx|
                begin
                  link = row.locator('a[href*="appndetails.asp"]')
                  next unless link.count > 0

                  onclick_attr = link.get_attribute('onclick') rescue nil
                  target_attr  = link.get_attribute('target') rescue nil
                  href_attr    = link.get_attribute('href') rescue nil

                  puts "➡️ Opening application #{idx + 1}"

                  detail_page = nil

                  if (onclick_attr && onclick_attr.include?('openWindowByName')) || (target_attr && target_attr.downcase == '_blank')
                    new_page_promise = context.expect_page do
                      link.click
                    end
                    detail_page = new_page_promise.value
                    detail_page.wait_for_load_state
                  else
                    info_url = URI.join(authority.url, href_attr).to_s
                    detail_page = context.new_page
                    detail_page.goto(info_url)
                    detail_page.wait_for_load_state
                  end

                  detail_page.wait_for_selector('#txtAppNo', timeout: 10000)

                  # --- Build Application object ---
                  app = Application.new
                  app.authority_name    = authority.name
                  app.council_reference = pw_get_field.call(detail_page, '#txtAppNo')
                  app.address           = pw_get_field.call(detail_page, '#txtAddress')
                  app.description       = pw_get_field.call(detail_page, '#txtProposal')
                  app.status            = pw_get_field.call(detail_page, '#txtStatus')
                  app.info_url          = detail_page.url
                  app.decision          = pw_get_field.call(detail_page, '#txtDecision')


                  # Expand "Important Dates" panel
                  if detail_page.locator('#imgMid').count > 0
                    begin
                      detail_page.click('#imgMid')
                      detail_page.wait_for_selector('#txtAppRec', timeout: 5000)

                      app.date_received  = parse_normalised_date.call(pw_get_field.call(detail_page, '#txtAppRec'))
                      app.date_validated = parse_normalised_date.call(pw_get_field.call(detail_page, '#txtAppVal'))
                    rescue StandardError => e
                      puts "  ⚠️ Could not expand date panel: #{e.class}: #{e.message}"
                    end
                  end

                  # --- Documents page (robust open) ---
                  if detail_page.locator('a:has(img[alt="View application documents"])').count > 0
                    docs_page = nil
                    begin
                      docs_anchor = detail_page.locator('a:has(img[alt="View application documents"])').first
                      href_attr = docs_anchor.get_attribute('href') rescue nil
                      onclick   = docs_anchor.get_attribute('onclick') rescue nil

                      docs_url = nil
                      if href_attr && href_attr.to_s !~ /^\s*javascript/i
                        docs_url = URI.join(detail_page.url, href_attr).to_s
                      elsif onclick && (m = onclick.match(/openWindowByName\(['"]([^'"]+)['"]/))
                        docs_url = URI.join(detail_page.url, m[1]).to_s
                      end

                      if docs_url
                        docs_page = context.new_page
                        docs_page.goto(docs_url)
                      else
                        docs_promise = context.expect_page do
                          docs_anchor.click
                        end
                        docs_page = docs_promise.value
                      end

                      docs_page.wait_for_selector('table.resulttable tr:nth-child(2)', timeout: 10000)

                      doc_rows = docs_page.locator('table.resulttable tr').all[1..] || []
                      documents = []

                      doc_rows.each do |drow|
                        begin
                          doc_href = nil
                          anchor = drow.locator('td:nth-child(6) a')
                          if anchor.count > 0
                            ahref = anchor.first.get_attribute('href') rescue nil
                            doc_href = ahref && ahref.to_s !~ /^\s*javascript/i ? URI.join(docs_page.url, ahref).to_s : nil
                          end

                          documents << {
                            type:        drow.locator('td:nth-child(1)').text_content&.strip,
                            reference:   drow.locator('td:nth-child(2)').text_content&.strip,
                            description: drow.locator('td:nth-child(3)').text_content&.strip,
                            date:        drow.locator('td:nth-child(4)').text_content&.strip,
                            size:        drow.locator('td:nth-child(5)').text_content&.strip,
                            url:         doc_href
                          }
                        rescue => inner_e
                          puts "    ⚠️ Failed to parse a document row: #{inner_e.class} - #{inner_e.message}"
                          next
                        end
                      end

                      app.documents_count = documents.length
                      app.documents_url   = docs_url || (docs_page.url rescue nil) if documents.any?
                    rescue StandardError => e
                      puts "  ⚠️ Documents page failed to open or parse: #{e.class}: #{e.message}"
                    ensure
                      begin
                        docs_page.close if docs_page && !docs_page.closed?
                      rescue
                      end
                    end
                  end

                  if app.valid?
                    puts "------------------------------------------------------------"
                    puts "  Ref:        #{app.council_reference}"
                    puts "  Address:    #{app.address}"
                    puts "  Description:#{app.description}"
                    puts "  Date:       #{app.date_received}"
                    puts "  Docs:       #{app.documents_count}"
                    puts "  Link:       #{app.info_url}"
                    puts "------------------------------------------------------------"
                    results << app
                    puts "  → Added application #{app.council_reference}"
                  else
                    puts "  ⚠️ Skipped invalid application (#{app.council_reference || 'no ref'})"
                  end

                  detail_page.close if detail_page && !detail_page.closed?
                rescue => e
                  puts "❌ Error parsing row #{idx + 1}: #{e.class}: #{e.message}"
                  puts e.backtrace.first(5)
                end
              end

              # --- Pagination (Ipswich robust) ---
              begin
                current_page_count = [rows.length - 1, 0].max
                if current_page_count == 10
                  next_page_link = page.locator('a:has(img[alt="Next Page"], img[title="Next Page"])')

                  if next_page_link.count > 0
                    puts "➡️ Moving to next results page (#{results.size} scraped so far)"
                    href = next_page_link.first.get_attribute('href') rescue nil

                    if href && !href.empty?
                      page.goto(URI.join(authority.url, href).to_s)
                    else
                      next_page_link.first.click rescue nil
                    end

                    page.wait_for_load_state
                    begin
                      page.wait_for_selector('table#dgSearchResults tr:nth-child(2)', timeout: 10000)
                      puts "✅ Next page loaded"
                    rescue
                      puts "⚠️ Next page loaded but results table did not appear; stopping pagination."
                      break
                    end
                  else
                    puts "ℹ️ No next-page link found after page with #{current_page_count} results; stopping."
                    break
                  end
                else
                  puts "ℹ️ Current page has #{current_page_count} results (<10) — not paginating further."
                  break
                end
              rescue => e
                puts "⚠️ Pagination error: #{e.message}"
              end
            end

            browser.close
          end
        end
      end
      results
    end

    def self.scrape_isle_of_anglesey(authority, params)
      puts "🔍 Scraping Isle of Anglesey (randoms2)"

      results = []
      from = params[:validated_from] || params[:received_from] || (Date.today - DAYS)
      to   = params[:validated_to]   || params[:received_to]   || Date.today

      from_str = from.strftime('%d/%m/%Y')
      to_str   = to.strftime('%d/%m/%Y')
            begin
        Timeout.timeout(900) do 
          Playwright.create(playwright_cli_executable_path: 'npx playwright') do |playwright|
            browser = playwright.chromium.launch(headless: false)
            page = browser.new_page

            # Go to base URL
            page.goto(authority.url)
            page.wait_for_load_state

            # === Fill "Week Commencing" field ===
            from_str = from.strftime('%d/%m/%Y')
            input = page.locator('input.slds-input.input')
            input.click
            input.press('Control+A')
            input.press('Backspace')
            page.keyboard.type(from_str)

            # === Click the second Search button (if multiple) ===
            search_buttons = page.locator('button[name="submit"].slds-button_brand')
            count = search_buttons.count

            if count > 0
              puts "🔘 Found #{count} search buttons, clicking the second one"
              search_buttons.nth(1).click   # 0 = first, 1 = second
            else
              raise "❌ No search button found"
            end

            # Wait for results to load
            page.wait_for_selector('#PApplication table tbody tr', timeout: 15_000)

            # === Change to 100 results per page ===
            if page.locator('select.slds-select').count > 0
              page.select_option('select.slds-select', value: '100')
              page.wait_for_selector('#PApplication table tbody tr', timeout: 15_000)
            end

            # === Scrape results ===
            loop do
              rows = page.locator('#PApplication table tbody tr')
              row_count = rows.count
              puts "📋 Found #{row_count} rows"

              row_count.times do |i|
                row = rows.nth(i)

                ref_link = row.locator('td:nth-child(2) a')
                next unless ref_link.count > 0

                ref         = ref_link.text_content&.strip
                url         = ref_link.get_attribute('href')
                address     = row.locator('td:nth-child(3)').text_content&.strip
                description = row.locator('td:nth-child(4)').text_content&.strip
                date_text   = row.locator('td:nth-child(5)').text_content&.strip
                decision    = row.locator('td:nth-child(6)').text_content&.strip

                date_received = Date.parse(date_text) rescue nil

                # --- Build Application object ---
                app = Application.new
                app.authority_name    = authority.name
                app.council_reference = ref
                app.date_received     = date_received
                app.decision          = decision
                app.info_url          = url ? URI.join(authority.url, url).to_s : authority.url
                app.address           = address
                app.description       = description
                app.documents_count   = 0
                app.documents_url     = nil

                if app.valid?
                  puts "------------------------------------------------------------"
                  puts "  Ref:        #{app.council_reference}"
                  puts "  Address:    #{app.address}"
                  puts "  Description:#{app.description}"
                  puts "  Date:       #{app.date_received}"
                  puts "  Docs:       #{app.documents_count}"
                  puts "  Link:       #{app.info_url}"
                  puts "------------------------------------------------------------"
                  results << app
                  puts "  → Added application #{app.council_reference}"
                else
                  puts "  ⚠️ Skipped invalid application (#{ref})"
                end
              end

              # === Pagination (check for Next button) ===
              next_button = page.locator('button:has-text("Next")')
              if next_button.count > 0 && next_button.enabled?
                next_button.click
                page.wait_for_selector('#PApplication table tbody tr', timeout: 15_000)
                page.wait_for_timeout(500)
              else
                break
              end
            end

            browser.close
          end
        end
      end
      results
    end

    def self.scrape_isles_of_scilly(authority, params)
      puts "🔍 Scraping Isles of Scilly (Randoms2)"
      require 'set'

      results = []
      from = params[:validated_from] || params[:received_from] || (Date.today - DAYS)
      to   = params[:validated_to]   || params[:received_to]   || Date.today

      from_str = from.strftime('%d/%m/%Y')
      to_str   = to.strftime('%d/%m/%Y')
     begin
        Timeout.timeout(900) do 
          Playwright.create(playwright_cli_executable_path: 'npx playwright') do |playwright|
            browser = playwright.chromium.launch(headless: false)
            page = browser.new_page

            # global timeouts (ms)
            page.set_default_timeout(30_000)
            page.set_default_navigation_timeout(30_000)

            today  = Date.today
            cutoff = today - DAYS # only scrape apps newer than this
            puts "📅 Cutoff date: #{cutoff}"

            seen_refs = Set.new
            page_num = 0
            max_pages = 0
            nav_retry_limit = 3

            loop do
              break if page_num > max_pages

              list_url = page_num == 0 ? authority.url : "#{authority.url}?page=#{page_num}"
              puts "🌍 Navigating to #{list_url}"

              nav_ok = false
              nav_retry_limit.times do |attempt|
                begin
                  page.goto(list_url)
                  page.wait_for_selector('table.views-table tbody tr', timeout: 10_000)
                  nav_ok = true
                  break
                rescue => e
                  puts "  ⚠️ Navigation attempt #{attempt + 1} failed: #{e.class}: #{e.message}"
                  sleep(0.6)
                end
              end

              unless nav_ok
                puts "❌ Failed to load page #{page_num}, stopping pagination."
                break
              end

              # Query rows on the current list page
              rows = page.locator('table.views-table tbody tr')
              row_count = rows.count rescue 0
              puts "📋 Found #{row_count} rows on page #{page_num}"
              break if row_count == 0

              row_count.times do |i|
                begin
                  row = page.locator('table.views-table tbody tr').nth(i)
                  ref_link = row.locator('td.views-field-title a')
                  next unless ref_link.count > 0

                  ref_text = ref_link.text_content&.strip
                  if ref_text && seen_refs.include?(ref_text)
                    puts "  ↩️ Already seen #{ref_text}, skipping"
                    next
                  end

                  addr_text  = (row.locator('td.views-field-field-site-address').text_content&.strip) rescue nil
                  type_text  = (row.locator('td.views-field-field-planning-app-type').text_content&.strip) rescue nil
                  href       = ref_link.get_attribute('href') rescue nil
                  info_url   = href ? URI.join(authority.url, href).to_s : authority.url

                  # Open details in a new tab (keeps list page intact)
                  detail_page = browser.new_page
                  begin
                    detail_nav_ok = false
                    nav_retry_limit.times do |attempt|
                      begin
                        detail_page.goto(info_url)
                        detail_page.wait_for_selector('.group-right', timeout: 12_000)
                        detail_nav_ok = true
                        break
                      rescue => e
                        puts "    ⚠️ Detail navigation attempt #{attempt + 1} failed for #{ref_text}: #{e.class}: #{e.message}"
                        sleep(0.5)
                      end
                    end

                    unless detail_nav_ok
                      puts "    ❌ Could not open detail page for #{ref_text}, closing detail tab and continuing"
                      detail_page.close rescue nil
                      seen_refs << ref_text if ref_text
                      next
                    end

                    # Extract fields from the detail page
                    fields = {}
                    field_nodes = detail_page.locator('.group-right .field')
                    (field_nodes.count).times do |j|
                      fld = field_nodes.nth(j)
                      label = (fld.locator('.field-label').text_content&.strip&.gsub(/[:\u00A0]+$/, '')) rescue nil
                      value = (fld.locator('.field-item').text_content&.strip) rescue nil
                      fields[label] = value if label && value
                    end

                    # --- Extract & parse Valid Date from detailed view ---
                    valid_date_text = nil
                    begin
                      valid_node = detail_page.locator('div.field-name-field-date-received span.date-display-single')
                      if valid_node.count > 0
                        valid_date_text = valid_node.first.text_content&.strip
                        valid_date = Date.parse(valid_date_text) rescue nil
                      else
                        valid_date = nil
                      end
                    rescue => e
                      puts "    ⚠️ Failed to parse valid date for #{ref_text}: #{e.message}"
                      valid_date = nil
                    end

                    # Skip if valid_date exists and is older than cutoff
                    if valid_date && valid_date < cutoff
                      puts "  ⏩ Skipping #{ref_text} (Valid date #{valid_date}, older than cutoff #{cutoff})"
                      seen_refs << ref_text if ref_text
                      detail_page.close rescue nil
                      next
                    end

                    # Normal field assignments
                    date_received = valid_date || (Date.parse(fields['Valid date']) rescue nil)
                    status_text   = fields['Decision'] || nil
                    desc_text     = fields['Application type'] || type_text
                    address_text  = fields['Site address'] || addr_text

                    docs_count = 0
                    begin
                      docs_count = detail_page.locator('.field-name-field-documents table tbody tr').count rescue 0
                    rescue
                      docs_count = 0
                    end

                    # --- Build Application object ---
                    app = Application.new
                    app.authority_name    = authority.name
                    app.council_reference = ref_text
                    app.date_received     = date_received
                    app.status            = status_text
                    app.info_url          = info_url
                    app.address           = address_text
                    app.description       = desc_text
                    app.documents_count   = docs_count
                    app.documents_url     = docs_count > 0 ? info_url : nil

                    if app.valid?
                      puts "------------------------------------------------------------"
                      puts "  Ref:        #{app.council_reference}"
                      puts "  Address:    #{app.address}"
                      puts "  Description:#{app.description}"
                      puts "  Date:       #{app.date_received}"
                      puts "  Docs:       #{app.documents_count}"
                      puts "  Link:       #{app.info_url}"
                      puts "------------------------------------------------------------"
                      results << app
                      puts "  → Added application #{app.council_reference}"
                    else
                      puts "  ⚠️ Skipped invalid application (#{ref_text})"
                    end

                  ensure
                    seen_refs << ref_text if ref_text
                    detail_page.close rescue nil
                  end

                  # tiny pause to be gentle
                  page.wait_for_timeout(150)
                rescue => e
                  puts "  ❌ Error scraping row #{i + 1} on page #{page_num}: #{e.class}: #{e.message}"
                  puts e.backtrace.first(5)
                  begin
                    page.goto(list_url)
                    page.wait_for_selector('table.views-table tbody tr', timeout: 8_000)
                  rescue
                    puts "    ⚠️ Could not recover list state; moving on"
                    next
                  end
                end
              end

              page_num += 1
            end

            browser.close
          end
        end
      end
      results
    end
    def self.scrape_kensington_and_chelsea(authority, params) ###############################################################################################################
      puts "🔍 Scraping RBKC (randoms1)"

      results = []
      # Standard date logic — identical to Randoms1
      from = params[:validated_from] || params[:received_from] || (Date.today - DAYS)
      to   = params[:validated_to]   || params[:received_to]   || Date.today

      from_str = from.strftime('%d/%m/%Y')
      to_str   = to.strftime('%d/%m/%Y')
      begin
        Timeout.timeout(900) do 
          Playwright.create(playwright_cli_executable_path: 'npx playwright') do |playwright|
            browser = playwright.chromium.launch(headless: false)
            page = browser.new_page

            # Local helper for date picking
            pick_date = ->(page, label, date_str) do
              date  = Date.strptime(date_str, "%d/%m/%Y")
              year  = date.year.to_s
              month = date.strftime("%B") # e.g. "September"
              day   = date.day.to_s

              puts "📝 Selecting #{label}: #{date_str}"

              # Open the date picker popover
              container = page.locator("h3:has-text(\"#{label}\")").locator("..")
              input = container.locator('input[readonly]')
              input.click

              # Select year (if available)
              page.click("button:has-text(\"#{year}\")") rescue nil

              # Select month
              page.click("button:has-text(\"#{month}\")") rescue nil

              # Select day
              page.click("button:has-text(\"#{day}\")") rescue nil
            end

            # Go to base URL
            page.goto(authority.url)
            page.wait_for_load_state

            # ADVANCED SEARCH
            puts "⏳ Waiting for Advanced Search link"
            page.wait_for_selector('text=Advanced search', timeout: 15000)
            puts "📂 Clicking Advanced Search"
            page.click('text=Advanced search')

            # APPLICATION TYPE
            puts "⏳ Expanding Application Type dropdown"
            app_type_section = page.locator('h3:has-text("Application type")').locator('..')
            app_type_section.locator('p:text("Select")').click

            puts "📂 Clearing all options"
            app_type_section.locator('button:has-text("Select none")').click

            puts "✅ Selecting only 'Applications'"
            app_type_section.locator('label:has-text("Applications")').click

            # DATES
            puts "⏳ Waiting for date pickers"
            page.wait_for_selector('h3:has-text("Start from")', timeout: 10000)

            pick_date.call(page, "Start from", from_str)
            pick_date.call(page, "To", to_str)

            sleep 2

            # SEARCH
            puts "🔍 Clicking Search"
            page.locator('button.font-bold:has-text("Search")').click
            puts "✅ Submitted Kensington and Chelsea form"

            # Wait for search results list
            page.wait_for_selector('#results-list-container article')

            loop do
              rows = page.locator('#results-list-container article')
              row_count = rows.count

              row_count.times do |i|
                row = rows.nth(i)

                # Reference link
                ref_link = row.locator('a.case-view-link')
                next unless ref_link.count > 0

                ref_text = ref_link.text_content&.strip&.gsub(/^N°:\s*/, '')
                status_text = row.locator('section div.rounded-full h4')&.text_content&.strip
                desc_text = row.locator('section div.text-brand-text-dark.font-light')&.text_content&.strip
                date_text = row.locator('section div.font-bold.text-sm')&.text_content&.strip
                address_text = row.locator('section .line-clamp-1')&.text_content&.strip

                # Open detail page
                ref_link.click
                page.wait_for_load_state

                # Scrape detail fields
                proposal = page.locator('div.mt-1.mb-3.pb-4 p')&.text_content&.strip
                full_address = page.locator('h3.font-bold.text-brand-text-dark')&.text_content&.strip

                date_received = nil
                date_registered = nil
                date_decision = nil
                target_date = nil

                details = page.locator('section.mt-2 div.flex')
                details.count.times do |j|
                  label = details.nth(j).locator('div').text_content.strip rescue ''
                  value = details.nth(j).locator('span').text_content.strip rescue ''
                  case label
                  when /Date received/i
                    date_received = Date.parse(value) rescue nil
                  when /Registration date/i
                    date_registered = Date.parse(value) rescue nil
                  when /Target date/i
                    target_date = Date.parse(value) rescue nil
                  end
                end

                # Status (again for safety)
                status_detail = page.locator('section.mt-2 div span.rounded-full')&.text_content&.strip
                status_final = status_detail || status_text

                # Documents
                docs_url = page.locator('a:has-text("See documents")')&.get_attribute('href')
                docs_count = 0
                if docs_url
                  doc_page = browser.new_page
                  doc_page.goto(docs_url)
                  doc_page.wait_for_selector('#documents tbody tr', timeout: 5_000) rescue nil
                  docs_count = doc_page.locator('#documents tbody tr').count rescue 0
                  doc_page.close
                end

                record = UKPlanningScraper::Record.build(
                  scraped_at:        Time.now,
                  authority_name:    authority.name,
                  council_reference: ref_text,
                  date_received:     date_received,
                  date_validated:    date_registered,
                  status:            status_final,
                  decision:          nil, # not clearly exposed
                  date_decision:     date_decision,
                  info_url:          page.url,
                  address:           full_address || address_text,
                  description:       proposal || desc_text,
                  documents_count:   docs_count,
                  documents_url:     docs_url
                )

                if UKPlanningScraper::Record.valid?(record)
                  results << record
                  puts "  → Added application #{record[:council_reference]}"
                else
                  puts "  ⚠️ Skipped invalid record (#{ref_text})"
                end

                # Back to results
                page.go_back
                page.wait_for_selector('#results-list-container article')
              end

              # Pagination handling
              next_button = page.locator('button:has-text("Next")')
              if next_button.count > 0 && next_button.is_enabled
                next_button.click
                page.wait_for_selector('#results-list-container article')
                page.wait_for_timeout(500)
              else
                break
              end
            end

            browser.close
          end
        end
      end
      results
    end
    def self.scrape_kirklees(authority, params)
      puts "🔍 Scraping Kirklees (randoms2)"

      results = []
      from = params[:validated_from] || params[:received_from] || (Date.today - DAYS)
      to   = params[:validated_to]   || params[:received_to]   || Date.today

      from_str = from.strftime('%d/%m/%Y')
      to_str   = to.strftime('%d/%m/%Y')
      begin
        Timeout.timeout(900) do 
          Playwright.create(playwright_cli_executable_path: 'npx playwright') do |playwright|
            browser = playwright.chromium.launch(headless: false)
            page = browser.new_page

            # Go to base URL
            page.goto(authority.url)
            page.wait_for_load_state

            # === Fill in date range (use pre-computed from_str / to_str) ===
            puts "📝 Filling in date range: #{from_str} → #{to_str}"
            page.click('input[name="ctl00$ctl00$cphPageBody$cphContent$txtDateFrom"]')
            page.keyboard.press('Control+A')
            page.keyboard.press('Backspace')
            page.keyboard.type(from_str)

            page.click('input[name="ctl00$ctl00$cphPageBody$cphContent$txtDateTo"]')
            page.keyboard.press('Control+A')
            page.keyboard.press('Backspace')
            page.keyboard.type(to_str)
            sleep 5
            # Submit search
            page.click('input[name="ctl00$ctl00$cphPageBody$cphContent$btnAdvSearch"]')
            page.wait_for_selector('#searchResults')

            loop do
              puts "📄 Scraping current results page..."

              apps = page.locator('#searchResults ul.filter-list li')
              app_count = apps.count

              app_count.times do |i|
                app_row = apps.nth(i)

                ref_text  = app_row.locator('h4 span').text_content&.strip
                desc_text = app_row.locator('p span[id*="lblSearchApplicationDescription"]').text_content&.strip
                addr_text = app_row.locator('p.small span[id*="lblSearchApplicationAddress1"]').text_content&.strip
                recd_text = app_row.locator('p.small span[id*="lblSearchApplicationReceived"]').text_content&.strip
                stat_text = app_row.locator('p.small span[id*="lblSearchApplicationStatus"]').text_content&.strip
                link      = app_row.locator('a')
                href      = link.get_attribute('href')

                puts "➡️ Opening application #{ref_text}"
                link.click
                page.wait_for_selector('h2:has-text("Application details")')

                # === Detail page scrape ===
                app_number = page.locator('#ctl00_ctl00_cphPageBody_cphContent_lbl_number_formatted').text_content&.strip || ref_text
                decision_text = page.locator('#ctl00_ctl00_cphPageBody_cphContent_lbl_decision_text').text_content&.strip

                # Parse dates safely
                date_received  = Date.parse(recd_text) rescue nil

                # === Documents ===
                docs_count = 0
                docs_url   = URI.join(authority.url, href).to_s
                begin
                  doc_buttons = page.locator('button.govuk-accordion__section-button')
                  doc_buttons.all.each(&:click)
                  sleep 1
                  docs_count = page.locator('a.documentTitle').count
                rescue => e
                  puts "⚠️ No documents found: #{e}"
                end

                # --- Build Application object ---
                app = Application.new
                app.authority_name    = authority.name
                app.council_reference = app_number
                app.date_received     = date_received
                app.status            = stat_text
                app.decision          = decision_text
                app.info_url          = docs_url
                app.address           = addr_text
                app.description       = desc_text
                app.documents_count   = docs_count
                app.documents_url     = docs_url

                if app.valid?
                  puts "------------------------------------------------------------"
                  puts "  Ref:        #{app.council_reference}"
                  puts "  Address:    #{app.address}"
                  puts "  Description:#{app.description}"
                  puts "  Date:       #{app.date_received}"
                  puts "  Docs:       #{app.documents_count}"
                  puts "  Link:       #{app.info_url}"
                  puts "------------------------------------------------------------"                
                  results << app
                  puts "  → Added application #{app.council_reference}"
                else
                  puts "  ⚠️ Skipped invalid application (#{ref_text})"
                end

                # Return to search results
                page.go_back
                page.wait_for_selector('#searchResults')
              end

              # === Pagination (use bottom pager only) ===
              next_link = page.locator('#ctl00_ctl00_cphPageBody_cphContent_dpSearchResultsBelow a:has-text("Next ›")')
              if next_link.count > 0 && !next_link.get_attribute('disabled')
                puts "➡️ Moving to next page of results..."
                next_link.first.click
                page.wait_for_selector('#searchResults')
              else
                puts "✅ No more pages."
                break
              end
            end

            browser.close
          end
        end
      end
      results
    end
    def self.scrape_leicester(authority, params)
      puts "🔍 Scraping Leicester (randoms2)"

      results = []
      from = params[:validated_from] || params[:received_from] || (Date.today - DAYS)
      to   = params[:validated_to]   || params[:received_to]   || Date.today

      from_str = from.strftime('%d/%m/%Y')
      to_str   = to.strftime('%d/%m/%Y')
      begin
        Timeout.timeout(900) do 
          Playwright.create(playwright_cli_executable_path: 'npx playwright') do |playwright|
            browser = playwright.chromium.launch(headless: false)
            context = browser.new_context
            page = context.new_page

            begin
              # === Go to base URL ===
              page.goto(authority.url)
              page.wait_for_load_state

              # === Accept terms if present ===
              begin
                page.click('input[value="Agree"]', timeout: 2000)
                page.wait_for_load_state
                puts "✅ Agreed to terms"
              rescue
                puts "ℹ️ No terms page to agree"
              end

              # Close cookies if present
              begin
                page.click('button:has-text("Close")', timeout: 2000)
                puts "🍪 Closed cookie banner"
              rescue
                puts "ℹ️ No cookie banner"
              end

              # Open Advanced Search
              page.click('a.tab-button:has-text("Advanced")')
              page.wait_for_selector('#DateReceivedFrom')

              # === Fill in date range ===
              puts "📝 Filling in date range: #{from_str} → #{to_str}"
              page.fill('#DateReceivedFrom', from_str)
              page.fill('#DateReceivedTo', to_str)

              # Submit search
              page.click('input[type="submit"][value="Search"], button[aria-label="Button: Search."]')
              page.wait_for_selector('.news_results_list table.tblResults', timeout: 30_000)

              page_index = 1
              loop do
                puts "📄 Scraping results page ##{page_index}..."

                # Wait for rows to be present and stable
                page.wait_for_selector('.news_results_list table.tblResults tbody tr', timeout: 10_000) rescue nil
                apps = page.locator('.news_results_list table.tblResults tbody tr')
                app_count = apps.count
                puts "📋 Found #{app_count} applications on page #{page_index}"

                break if app_count == 0

                (0...app_count).each do |i|
                  app_row = apps.nth(i)

                  # === Summary fields ===
                  ref   = app_row.locator('td').nth(0).text_content&.strip rescue nil
                  addr  = app_row.locator('td').nth(2).text_content&.strip rescue nil
                  desc  = app_row.locator('td.search-description').text_content&.strip rescue nil
                  validated = app_row.locator('td').nth(4).text_content&.strip rescue nil
                  decision  = app_row.locator('td').nth(5).text_content&.strip rescue nil
                  stat      = app_row.locator('td').nth(6).text_content&.strip rescue nil

                  puts "➡️ Opening application #{ref}"

                  anchor = app_row.locator('td a').first
                  href_abs = nil
                  begin
                    href_abs = anchor.evaluate('el => el.href') rescue nil
                    href_abs = nil if href_abs.to_s.strip == '' || href_abs.to_s.strip.downcase.start_with?('javascript:')
                  rescue
                    href_abs = nil
                  end

                  # Open details in a new page
                  detail_page = nil
                  same_tab_fallback = false
                  if href_abs
                    detail_page = context.new_page
                    detail_page.goto(href_abs)
                  else
                    begin
                      anchor.click
                      page.wait_for_selector('h1, #importantdate, .application-details', timeout: 10_000)
                      detail_page = page
                      same_tab_fallback = true
                    rescue => e
                      puts "⚠️ Failed to open detail for #{ref}: #{e.class} - #{e.message}"
                      next
                    end
                  end

                  # Wait for expected detail selectors
                  begin
                    detail_page.wait_for_selector('h1, #importantdate, .application-details', timeout: 10_000) unless same_tab_fallback
                  rescue
                    detail_page.wait_for_timeout(500) rescue nil
                  end

                  # === Important dates ===
                  recd       = nil

                  begin
                    recd = detail_page.locator('tr:has-text("Application Received Date") td').nth(1).text_content&.strip rescue nil
                  rescue
                    recd = nil
                  end

                  date_received  = Date.parse(recd) rescue nil
                  # === Documents ===
                  docs_count = 0
                  begin
                    begin
                      detail_page.click('a.tab-button:has-text("Documents")', timeout: 3000)
                      detail_page.wait_for_selector('#documentsdata', timeout: 3000)
                      docs_count = detail_page.locator('#documentsdata tr.datarow.appdoc').count rescue 0
                    rescue
                      docs_count = detail_page.locator('table#documentsdata tbody tr').count rescue docs_count
                    end
                  rescue => e
                    puts "⚠️ No documents found for #{ref}: #{e.class} - #{e.message}"
                  end

                  info_url = (href_abs || (detail_page.url rescue authority.url))

                  # === Build Application object ===
                  app = Application.new
                  app.authority_name    = authority.name
                  app.council_reference = ref
                  app.date_received     = date_received
                  app.status            = stat
                  app.decision          = nil
                  app.info_url          = info_url
                  app.address           = addr
                  app.description       = desc
                  app.documents_count   = docs_count
                  app.documents_url     = info_url

                  if app.valid?
                    puts "------------------------------------------------------------"
                    puts "  Ref:        #{app.council_reference}"
                    puts "  Address:    #{app.address}"
                    puts "  Description:#{app.description}"
                    puts "  Date:       #{app.date_received}"
                    puts "  Docs:       #{app.documents_count}"
                    puts "  Link:       #{app.info_url}"
                    puts "------------------------------------------------------------"                    
                    results << app
                    puts "  → Added application #{app.council_reference}"
                  else
                    puts "  ⚠️ Skipped invalid application (#{ref})"
                  end

                  if detail_page && !same_tab_fallback && !detail_page.closed?
                    detail_page.close rescue nil
                  end

                  if same_tab_fallback
                    begin
                      page.go_back
                      page.wait_for_selector('.news_results_list table.tblResults', timeout: 10_000)
                    rescue
                      puts "⚠️ go_back failed; reloading results page"
                      page.goto(authority.url)
                      page.wait_for_selector('#DateReceivedFrom', timeout: 10_000)
                      page.fill('#DateReceivedFrom', from_str) rescue nil
                      page.fill('#DateReceivedTo', to_str) rescue nil
                      page.click('input[type="submit"][value="Search"], button[aria-label="Button: Search."]') rescue nil
                      page.wait_for_selector('.news_results_list table.tblResults', timeout: 30_000) rescue nil

                      (1...page_index).each do |_|
                        begin
                          nxt = page.locator('a[aria-label="Next Page."]').first
                          break unless nxt && nxt.count > 0
                          nxt.click
                          page.wait_for_selector('.news_results_list table.tblResults', timeout: 10_000)
                        rescue
                          break
                        end
                      end
                    end
                  end

                  page.wait_for_timeout(250)
                end

                # --- Pagination ---
                begin
                  prev_first_href = nil
                  if page.locator('.news_results_list table.tblResults tbody tr td a').count > 0
                    prev_first_href = page.locator('.news_results_list table.tblResults tbody tr td a').first.get_attribute('href') rescue nil
                  end

                  next_link = page.locator('a[aria-label="Next Page."]').first rescue nil
                  if next_link && next_link.count > 0 && next_link.get_attribute('href').to_s.strip != ''
                    puts "➡️ Moving to next page..."
                    next_link.click
                    begin
                      if prev_first_href
                        page.wait_for_function(%Q{
                          () => {
                            const a = document.querySelector('.news_results_list table.tblResults tbody tr td a');
                            if (!a) return false;
                            return a.getAttribute('href') !== #{prev_first_href.inspect};
                          }
                        }, timeout: 12_000)
                      else
                        page.wait_for_selector('.news_results_list table.tblResults tbody tr', timeout: 12_000)
                      end
                    rescue
                      page.wait_for_timeout(1000)
                    end
                    page_index += 1
                    next
                  else
                    puts "✅ No more pages."
                    break
                  end
                rescue => e
                  puts "⚠️ Pagination error: #{e.class} - #{e.message}; stopping."
                  break
                end
              end

            rescue => e
              puts "❌ Error scraping Leicester: #{e.class} - #{e.message}"
              puts e.backtrace.first(5)
            ensure
              browser.close rescue nil
            end
          end
        end
      end
      results
    end
    def self.scrape_mole_valley(authority, params)
      puts "🌿 Launching headful browser for Mole Valley..."

      results = []
      from = params[:validated_from] || params[:received_from] || (Date.today - DAYS)
      to   = params[:validated_to]   || params[:received_to]   || Date.today

      from_str = from.strftime('%d/%m/%Y')
      to_str   = to.strftime('%d/%m/%Y')
      begin
        Timeout.timeout(900) do 
          Playwright.create(playwright_cli_executable_path: 'npx playwright') do |playwright|
            browser = playwright.chromium.launch(headless: false)
            context = browser.new_context
            page = context.new_page

            begin
              page.goto(authority.url)
              page.wait_for_load_state

              # --- Accept cookies ---
              if page.locator('button:has-text("Accept additional cookies")').count > 0
                page.click('button:has-text("Accept additional cookies")') rescue nil
                puts "🍪 Accepted cookies"
                page.wait_for_timeout(500)
              end

              # --- Switch to Planning Applications tab ---
              if page.locator('button:has-text("Planning Applications")').count > 0
                page.click('button:has-text("Planning Applications")')
                page.wait_for_timeout(500)
                puts "📋 Opened Planning Applications tab"
              end

              # --- Switch to Advanced tab ---
              if page.locator('button:has-text("Advanced")').count > 0
                page.click('button:has-text("Advanced")')
                page.wait_for_timeout(500)
                puts "⚙️ Switched to Advanced search"
              end

              # --- Enter Dates (Registered Date From only) ---
              from_date = Date.strptime(from_str, '%d/%m/%Y').strftime('%Y/%m/%d')

              if page.locator('#app-Received-Deadline-From').count > 0
                input = page.locator('#app-Received-Deadline-From')
                input.click
                input.fill('') # clear any placeholder text
                input.type(from_str)
                puts "📅 Entered Received Date From: #{from_date}"
              else
                puts "⚠️ Could not find 'Received Date From' input field"
              end

              # --- Submit Search (use SECOND search button) ---
              search_buttons = page.locator('button:has-text("Search")')
              if search_buttons.count >= 2
                search_buttons.nth(1).click
                puts "🔍 Clicked second Search button (Mole Valley)"
              else
                search_buttons.first.click rescue nil
                puts "⚠️ Only one Search button found; clicked first one"
              end
              sleep 2
              page.wait_for_selector('div[data-id][role="row"] a.entityTable__linkCell', timeout: 30_000)
              puts "✅ Results loaded for Mole Valley"

              # === Safe text helper ===
              safe_text = ->(page, label) do
                locator = page.locator("label:has-text('#{label}') + span.mirageFormControl__field--view")
                locator.first.text_content.strip rescue nil
              end

              loop do
                # --- RESULTS LOOP ---
                rows = page.locator('div[data-id][role="row"] a.entityTable__linkCell')
                total_rows = rows.count
                puts "📋 Found #{total_rows} applications on this page"

                total_rows.times do |i|
                  begin
                    row_link = rows.nth(i)
                    ref_text = row_link.text_content&.strip
                    puts "➡️ Opening application #{ref_text}"
                    sleep 1
                    row_link.click
                    page.wait_for_selector('label:has-text("Reference") + span.mirageFormControl__field--view', timeout: 20_000)

                    # === SCRAPE DETAIL PAGE ===
                    council_ref   = safe_text.call(page, 'Reference')
                    init_ref      = safe_text.call(page, 'Initial Reference')
                    proposal      = safe_text.call(page, 'Proposal Details')
                    status        = safe_text.call(page, 'Status')
                    decision      = safe_text.call(page, 'Decision')
                    address       = safe_text.call(page, 'Address')
                    received_str  = safe_text.call(page, 'Received Date')
                    received_date  = Date.strptime(received_str,  '%d/%m/%Y') rescue nil

                    # --- DOCUMENTS TAB ---
                    docs_url = nil
                    docs_count = 0
                    if page.locator('button:has-text("Documents")').count > 0
                      page.click('button:has-text("Documents")')
                      page.wait_for_selector('div[data-id][role="row"]', timeout: 15_000) rescue nil
                      docs_count = page.locator('div[data-id][role="row"]').count rescue 0
                      docs_url = page.url
                      puts "📄 Documents tab: #{docs_count} documents found"
                    end

                    # --- Build Application object (replaces Record.build) ---
                    app = Application.new
                    app.authority_name    = authority.name
                    app.council_reference = (council_ref || ref_text)
                    app.date_received     = received_date
                    app.status            = status
                    app.decision          = decision
                    app.info_url          = page.url
                    app.address           = address
                    app.description       = proposal
                    app.documents_count   = docs_count
                    app.documents_url     = docs_url

                    if app.valid?
                      puts "------------------------------------------------------------"
                      puts "  Ref:        #{app.council_reference}"
                      puts "  Address:    #{app.address}"
                      puts "  Description:#{app.description}"
                      puts "  Date:       #{app.date_received}"
                      puts "  Docs:       #{app.documents_count}"
                      puts "  Link:       #{app.info_url}"
                      puts "------------------------------------------------------------"
                      results << app
                      puts "  ✅ Added #{app.council_reference}"
                    else
                      puts "  ⚠️ Skipped invalid application (#{ref_text})"
                    end

                    # --- Return to results ---
                    page.go_back
                    page.wait_for_selector('div[data-id][role="row"] a.entityTable__linkCell', timeout: 15_000)
                    page.wait_for_timeout(500)
                  rescue => row_err
                    puts "❌ Error processing Mole Valley row #{i + 1}: #{row_err.class} - #{row_err.message}"
                    next
                  end
                end

                # --- PAGINATION HANDLING ---
                next_button = page.locator('button[aria-label="next"]')
                if next_button.count > 0 && !next_button.first.get_attribute('disabled')
                  puts "➡️ Moving to next results page..."
                  next_button.first.click
                  page.wait_for_load_state
                  page.wait_for_selector('div[data-id][role="row"] a.entityTable__linkCell', timeout: 15_000)
                  page.wait_for_timeout(1000)
                else
                  puts "🏁 No more pages."
                  break
                end
              end

            rescue => e
              puts "❌ Error scraping Mole Valley: #{e.class} - #{e.message}"
              puts e.backtrace.first
            ensure
              browser.close rescue nil
            end
          end
        end
      end
      results
    end
    def self.scrape_north_lincolnshire(authority, params)
      puts "🔍 Scraping North Lincolnshire (randoms2)"

      results = []
      from = params[:validated_from] || params[:received_from] || (Date.today - DAYS)
      to   = params[:validated_to]   || params[:received_to]   || Date.today

      # We stop when we see something older than 'from'
      # We assume results are shown most recent → oldest

      begin
        Timeout.timeout(900) do
          Playwright.create(playwright_cli_executable_path: 'npx playwright') do |playwright|
            browser = playwright.chromium.launch(headless: false)
            context = browser.new_context
            page    = context.new_page

            current_page = 1
            base_url     = authority.url   # e.g. https://apps.northlincs.gov.uk/

            loop do
              page_url = current_page == 1 ? base_url : "#{base_url}?page=#{current_page}"
              puts "📄 Loading page #{current_page}: #{page_url}"

              page.goto(page_url)
              page.wait_for_load_state
              page.wait_for_selector('a.application', timeout: 20_000)

              # Get all application links on this page
              app_links = page.locator('a.application')
              count = app_links.count
              puts "   → Found #{count} applications on page #{current_page}"

              break if count.zero?

              should_stop = false

              count.times do |i|
                begin
                  link = app_links.nth(i)

                  # Get "Valid From" date right from the list row (fast filter)
                  valid_text = link.locator('.col.val').text_content.strip rescue nil
                  date_valid = UKPlanningScraper::Utils.parse_date(valid_text) rescue nil

                  if date_valid && date_valid < from
                    puts "⏹️  Hit application from #{date_valid} — older than #{from}. Stopping scrape."
                    should_stop = true
                    break
                  end

                  href = link.get_attribute('href')
                  next unless href

                  detail_url = URI.join(base_url, href).to_s
                  puts "➡️  Opening application #{i+1}/#{count}: #{detail_url}"

                  # Open new tab/page for detail
                  detail_page = context.new_page
                  detail_page.goto(detail_url)
                  page.wait_for_load_state
                  detail_page.wait_for_selector('.app-content', timeout: 20_000)

                  ref = detail_page.locator('.application:has(.col.title:has-text("Reference")) .col.detail').first.text_content.strip rescue nil
                  description = detail_page.locator('.application:has(.col.title:has-text("Proposed Development")) .col.detail').first.text_content.strip rescue nil
                  address = detail_page.locator('.application:has(.col.title:has-text("Site Location")) .col.detail').first.text_content.strip rescue nil
                  decision = detail_page.locator('.application:has(.col.title:has-text("Decision")) .col.detail').first.text_content.strip rescue nil

                  # Count documents
                  docs_rows = detail_page.locator('table tbody tr')
                  docs_count = docs_rows.count
                  docs_url   = docs_count > 0 ? detail_url : nil   # or documents tab url if different

                  app = Application.new
                  app.authority_name    = authority.name
                  app.council_reference = ref
                  app.date_received     = date_valid
                  app.address           = address
                  app.description       = description
                  app.decision          = decision
                  app.info_url          = detail_url
                  app.documents_count   = docs_count
                  app.documents_url     = docs_url

                  if app.valid?
                    puts "------------------------------------------------------------"
                    puts "  Ref:        #{app.council_reference}"
                    puts "  Address:    #{app.address}"
                    puts "  Description:#{app.description}"
                    puts "  Date:       #{app.date_received}"
                    puts "  Docs:       #{app.documents_count}"
                    puts "  Link:       #{app.info_url}"
                    puts "------------------------------------------------------------"
                    results << app
                    puts "  → Added application #{app.council_reference}"
                  else
                    puts "  ⚠️ Skipped invalid application (ref: #{ref || 'missing'})"
                  end

                  detail_page.close

                rescue => e
                  puts "❌ Error on app #{i+1} (page #{current_page}): #{e.message}"
                end
              end

              break if should_stop

              current_page += 1

              # Optional: safety break if too many pages
              break if current_page > 60
            end

            browser.close
          end
        end
      rescue Timeout::Error
        puts "⚠️ Timeout after 15 minutes — partial results returned"
      rescue => e
        puts "❌ Fatal error during scrape: #{e.message}"
      end

      results
    end
    def self.scrape_nuneaton_and_bedworth(authority, params)
      puts "🔍 Scraping Nuneaton and Bedworth (keyboard-driven)"
      results = []
      from = params[:validated_from] || params[:received_from] || (Date.today - DAYS)
      to   = params[:validated_to]   || params[:received_to]   || Date.today

      from_str = from.strftime('%d/%m/%Y')
      to_str   = to.strftime('%d/%m/%Y')
      begin
        Timeout.timeout(900) do 
          Playwright.create(playwright_cli_executable_path: 'npx playwright') do |playwright|
            browser = playwright.chromium.launch(headless: false)
            context = browser.new_context
            page = context.new_page

            begin
              # How many weekly-list rows to attempt (first run -> first row, second run -> second row, ...)
              max_to_process = 7

              (0...max_to_process).each do |target_index|
                begin
                  puts "➡️ Iteration #{target_index + 1} — loading base page"
                  page.goto(authority.url)
                  page.wait_for_load_state

                  # close cookie banner if present
                  begin
                    if page.locator('#close-cookie-message').count > 0
                      puts "🍪 Closing cookie banner"
                      page.locator('#close-cookie-message').first.click
                      page.wait_for_timeout(500)
                    end
                  rescue => e
                    puts "⚠️ Cookie close attempt failed: #{e.message}"
                  end

                  # Wait a little to ensure the page interactive
                  page.wait_for_timeout(600)
                  sleep 3

                  # --- KEYBOARD NAV: Tab 10x then Enter ---
                  puts "⌨️ Pressing Tab x10 then Enter to reach selection page"
                  9.times do
                    page.keyboard.press('Tab')
                    page.wait_for_timeout(80)
                  end
                  page.keyboard.press('Enter')
                  page.wait_for_timeout(900)

                  # Now we should be on the selection stage. Do the modal trigger keys:
                  puts "⌨️ Pressing Tab x3 then ArrowDown x2 to open lookup modal"
                  3.times do
                    page.keyboard.press('Tab')
                    page.wait_for_timeout(120)
                  end
                  2.times do
                    page.keyboard.press('ArrowDown')
                    page.wait_for_timeout(150)
                  end

                  # give modal time to open
                  page.wait_for_timeout(2000)

                  # Wait for lookup modal table rows
                  begin
                    page.wait_for_selector('table.table.table-responsive tbody tr', timeout: 8_000)
                  rescue
                    puts "⚠️ Lookup modal rows did not appear immediately — trying a small wait and retry"
                    page.wait_for_timeout(1200)
                  end

                  rows_locator = page.locator('table.table.table-responsive tbody tr')
                  row_count = rows_locator.count
                  puts "📋 Lookup modal rows present: #{row_count}"

                  if row_count == 0
                    warn "⚠️ No lookup rows found — skipping this iteration"
                    next
                  end

                  # Bound target index if the modal doesn't contain that many rows
                  if target_index >= row_count
                    puts "⚠️ Requested row index #{target_index} is out of range (#{row_count} rows). Stopping iterations."
                    break
                  end

                  # Extract the target row data BEFORE clicking (ref / address / alt ref)
                  row = rows_locator.nth(target_index)
                  ref_text = (row.locator('td').nth(1).text_content&.strip rescue nil)
                  addr_text = (row.locator('td').nth(2).text_content&.strip rescue nil)

                  puts "➡️ Selecting lookup row ##{target_index} — #{ref_text} / #{addr_text}"

                  # Click the radio for the selected row (robust)
                  begin
                    radio = row.locator('input[type="radio"]')
                    if radio.count > 0
                      radio.first.click
                    else
                      # fallback: click label inside the row
                      row.locator('label').first.click rescue nil
                    end
                    page.wait_for_timeout(300)
                  rescue => e
                    puts "⚠️ Radio click failed: #{e.class} - #{e.message}; attempting JS click"
                    begin
                      page.evaluate(%Q{
                        (() => {
                          const rows = Array.from(document.querySelectorAll('table.table.table-responsive tbody tr'));
                          const ri = #{target_index};
                          if (rows[ri]) {
                            const r = rows[ri];
                            const inp = r.querySelector('input[type="radio"]');
                            if (inp) { inp.click(); return true; }
                            const lab = r.querySelector('label');
                            if (lab) { lab.click(); return true; }
                          }
                          return false;
                        })();
                      })
                      page.wait_for_timeout(300)
                    rescue
                    end
                  end

                  # Click the modal "Select" button (robust)
                  begin
                    if page.locator('a.modal_save_button, button:has-text("Select"), button:has-text("Next")').count > 0
                      page.locator('a.modal_save_button, button:has-text("Select"), button:has-text("Next")').first.click
                    else
                      page.keyboard.press('Tab')
                      page.wait_for_timeout(120)
                      page.keyboard.press('Enter')
                    end
                    page.wait_for_timeout(600)
                  rescue => e
                    puts "⚠️ Modal Select click failed: #{e.class} - #{e.message}; trying keyboard fallback"
                    begin
                      page.keyboard.press('Tab')
                      page.wait_for_timeout(120)
                      page.keyboard.press('Enter')
                      page.wait_for_timeout(600)
                    rescue
                    end
                  end

                  # Click View Application Details (PLsearch)
                  begin
                    if page.locator('button#PLsearch, button[name="PLsearch"]').count > 0
                      page.locator('button#PLsearch, button[name="PLsearch"]').first.click
                    else
                      5.times do
                        page.keyboard.press('Tab')
                        page.wait_for_timeout(100)
                      end
                      page.keyboard.press('Enter')
                    end
                    page.wait_for_timeout(900)
                  rescue => e
                    puts "⚠️ Could not click PLsearch directly: #{e.class} - #{e.message}; retrying"
                    page.wait_for_timeout(800)
                    begin
                      page.locator('button#PLsearch, button[name="PLsearch"]').first.click rescue nil
                      page.wait_for_timeout(400)
                    rescue
                    end
                  end

                  # Wait for the details textarea to appear
                  begin
                    page.wait_for_selector('textarea#concatDetails', timeout: 10_000)
                  rescue
                    puts "⚠️ concatDetails did not show immediately — continuing"
                  end

                  concat_text = nil
                  begin
                    concat_text = page.locator('textarea#concatDetails').text_content&.strip rescue nil
                    puts "ℹ️ concatDetails length: #{concat_text ? concat_text.length : 0}"
                  rescue => e
                    puts "⚠️ Could not read concatDetails: #{e.class} - #{e.message}"
                  end

                  # Scrape docs listed under #docs (radio inputs with URLs in value)
                  docs = []
                  begin
                    docs_count = page.locator('#docs input[type="radio"]').count
                    if docs_count > 0
                      (0...docs_count).each do |di|
                        val = page.locator('#docs input[type="radio"]').nth(di).get_attribute('value') rescue nil
                        label = page.locator('#docs label').nth(di).text_content&.strip rescue nil
                        docs << { url: (val if val && !val.empty?), title: label }
                      end
                    elsif concat_text
                      concat_text.scan(%r{https?://\S+}).each { |u| docs << { url: u, title: nil } }
                      docs.uniq! { |d| d[:url] }
                    end
                  rescue => e
                    puts "⚠️ Error while collecting docs: #{e.class} - #{e.message}"
                  end

                  docs_urls = docs.map { |d| d[:url] }.compact
                  docs_join = docs_urls.join(' | ')
                  docs_count_final = docs_urls.length

                  # --- Build Application object ---
                  app = Application.new
                  app.authority_name    = authority.name
                  app.council_reference = (ref_text && !ref_text.empty?) ? ref_text : (alt_ref && !alt_ref.empty? ? alt_ref : nil)
                  app.date_received     = nil
                  app.status            = nil
                  app.decision          = nil
                  app.info_url          = authority.url
                  app.address           = addr_text
                  app.description       = (concat_text && concat_text.strip.length > 0) ? concat_text.strip[0..2000] : nil
                  app.documents_count   = docs_count_final
                  app.documents_url     = (docs_count_final > 0 ? docs_join : nil)

                  if app.valid?
                    puts "------------------------------------------------------------"
                    puts "  Ref:        #{app.council_reference}"
                    puts "  Address:    #{app.address}"
                    puts "  Description:#{app.description}"
                    puts "  Date:       #{app.date_received}"
                    puts "  Docs:       #{app.documents_count}"
                    puts "  Link:       #{app.info_url}"
                    puts "------------------------------------------------------------"                    
                    results << app
                    puts "  → Added application #{app.council_reference} (docs: #{docs_count_final})"
                  else
                    puts "  ⚠️ Skipped invalid application (no council_reference or info_url)"
                  end

                  page.wait_for_timeout(600)
                rescue => iter_e
                  warn "⚠️ Iteration #{target_index} failed: #{iter_e.class} - #{iter_e.message}"
                  next
                end
              end

            rescue => e
              warn "❌ Fatal error scraping Nuneaton and Bedworth: #{e.class} - #{e.message}"
              warn e.backtrace.first(5)
            ensure
              browser.close rescue nil
            end
          end
        end
      end
      results
    end
    def self.scrape_preston(authority, params)
      puts "🔍 Scraping Preston (randoms1)"

      results = []
      from = params[:validated_from] || params[:received_from] || (Date.today - DAYS)
      to   = params[:validated_to]   || params[:received_to]   || Date.today

      from_str = from.strftime('%d/%m/%Y')
      to_str   = to.strftime('%d/%m/%Y')
      begin
        Timeout.timeout(900) do 
          Playwright.create(playwright_cli_executable_path: 'npx playwright') do |playwright|
            browser = playwright.chromium.launch(headless: false)
            context = browser.new_context
            page = context.new_page

            begin
              # Go to base URL
              page.goto(authority.url)
              page.wait_for_load_state

              puts "📝 Filling in date range: #{from_str} → #{to_str}"
              page.fill('#MainContent_txtDateRegisteredFrom', from_str)
              page.fill('#MainContent_txtDateRegisteredTo', to_str)

              puts "⏳ Waiting 16s for captcha solve..."
              sleep 16

              # Submit search
              page.click('#MainContent_btnSearch')
              page.wait_for_selector('#dvScroll div#applicationcontainer', timeout: 30_000)

              loop do
                apps = page.locator('#dvScroll div#applicationcontainer')
                app_count = apps.count
                puts "📋 Found #{app_count} applications on this page"

                app_count.times do |i|
                  begin
                    app_container = apps.nth(i)

                    # Try to find ApplicationView.aspx link
                    link_locator = app_container.locator('xpath=.//a[contains(@href,"ApplicationView.aspx")]').first
                    href = nil

                    if link_locator.count > 0
                      href = link_locator.get_attribute('href')
                    else
                      # fallback: any link containing "ApplicationView"
                      anchors = app_container.locator('a')
                      anchors.count.times do |ai|
                        h = anchors.nth(ai).get_attribute('href')
                        if h && h.to_s =~ /ApplicationView/i
                          href = h
                          break
                        end
                      end
                    end

                    ref_anchor = app_container.locator('a').first
                    ref_text   = ref_anchor.text_content&.strip rescue nil

                    # Build absolute detail URL if relative
                    detail_url = nil
                    if href && href.strip.length > 0
                      detail_url = href
                      unless detail_url =~ %r{^https?://}i
                        detail_url = URI.join(page.url, detail_url).to_s rescue detail_url
                      end
                    end

                    puts "➡️ Opening application #{ref_text} (#{detail_url || 'clicking in-page'})"

                    # Open details
                    detail_page = nil
                    if detail_url
                      detail_page = context.new_page
                      detail_page.goto(detail_url)
                      detail_page.wait_for_selector('#applicationdetails, #MainContent_pnlPlanningDetails, div.divRow', timeout: 20_000)
                    else
                      ref_anchor.click
                      page.wait_for_selector('#applicationdetails, #MainContent_pnlPlanningDetails, div.divRow', timeout: 20_000)
                      detail_page = page
                    end

                    # Helper: read label/value pairs
                    get_label_value = lambda do |dp, label|
                      begin
                        loc = dp.locator("div.divRow:has(b:has-text(\"#{label}\"))")
                        if loc.count > 0
                          if loc.locator('span').count > 0
                            return loc.locator('span').first.text_content&.strip
                          else
                            txt = loc.first.text_content || ''
                            return txt.gsub(/#{Regexp.escape(label)}/i, '').strip
                          end
                        end
                      rescue
                      end
                      nil
                    end

                    # Extract data
                    app_number = if detail_page.locator('#REF_NO').count > 0
                                    detail_page.locator('#REF_NO').text_content&.strip
                                  else
                                    ref_text
                                  end

                    address = if detail_page.locator('#APPADDRESS').count > 0
                                detail_page.locator('#APPADDRESS').text_content&.strip
                              else
                                get_label_value.call(detail_page, 'Address:') || get_label_value.call(detail_page, 'Location:')
                              end

                    description = get_label_value.call(detail_page, 'Description:')
                    reg_txt     = get_label_value.call(detail_page, 'Registration date:') || get_label_value.call(detail_page, 'Registration Date:')
                    date_received = (Date.parse(reg_txt) rescue nil)

                    decision_text = get_label_value.call(detail_page, 'Decision:')
                    # Documents
                    docs_count = 0
                    if detail_page.locator('#btnAssociatedDocumentationShowHide').count > 0
                      begin
                        detail_page.click('#btnAssociatedDocumentationShowHide') rescue nil
                        detail_page.wait_for_selector('#myTable, #dgListOfDocuments', timeout: 5_000) rescue nil
                        docs_count = detail_page.locator('#myTable tbody tr, #dgListOfDocuments tbody tr').count rescue 0
                      rescue
                        docs_count = 0
                      end
                    end

                    # --- Build Application object ---
                    app = Application.new
                    app.authority_name    = authority.name
                    app.council_reference = app_number
                    app.date_received     = date_received
                    app.decision          = decision_text
                    app.info_url          = detail_url || page.url
                    app.address           = address
                    app.description       = description
                    app.documents_count   = docs_count
                    app.documents_url     = detail_url || page.url

                    if app.valid?
                      puts "------------------------------------------------------------"
                      puts "  Ref:        #{app.council_reference}"
                      puts "  Address:    #{app.address}"
                      puts "  Description:#{app.description}"
                      puts "  Date:       #{app.date_received}"
                      puts "  Docs:       #{app.documents_count}"
                      puts "  Link:       #{app.info_url}"
                      puts "------------------------------------------------------------"                      
                      results << app
                      puts "  → Added application #{app.council_reference}"
                    else
                      puts "  ⚠️ Skipped invalid application (#{app_number})"
                    end

                    # Navigation cleanup
                    if detail_page && detail_page != page
                      detail_page.close
                      page.wait_for_timeout(250)
                    else
                      page.go_back
                      page.wait_for_selector('#dvScroll div#applicationcontainer', timeout: 15_000)
                      page.wait_for_timeout(250)
                    end

                  rescue => e
                    puts "❌ Error processing application #{i + 1}: #{e.class} - #{e.message}"
                    puts e.backtrace.first
                    begin
                      page.goto(authority.url)
                      page.wait_for_selector('#dvScroll div#applicationcontainer', timeout: 10_000)
                    rescue
                    end
                  end
                end

                # Pagination
                current_page = 1
                if page.locator('#MainContent_dlPager2 a.aspNetDisabled').count > 0
                  current_page = page.locator('#MainContent_dlPager2 a.aspNetDisabled').first.text_content.gsub(/[^\d]/, '').to_i rescue 1
                end

                next_link = nil
                pager_links = page.locator('#MainContent_dlPager2 a')
                pager_links.count.times do |pi|
                  link = pager_links.nth(pi)
                  txt = link.text_content&.strip
                  if txt == (current_page + 1).to_s
                    next_link = link
                    break
                  end
                end

                if next_link && next_link.count > 0
                  puts "➡️ Moving to page #{current_page + 1}"
                  next_link.click
                  page.wait_for_selector('#dvScroll div#applicationcontainer', timeout: 15_000)
                  page.wait_for_timeout(500)
                else
                  puts "✅ No more pages for Preston."
                  break
                end
              end

            rescue => e
              puts "❌ Error scraping Preston: #{e.class} - #{e.message}"
              puts e.backtrace.first
            ensure
              browser.close rescue nil
            end
          end
        end
      end
      results
    end
    def self.scrape_redcar_and_cleveland(authority, params)
      puts "🌊 Scraping Redcar and Cleveland (single-result-safe)"

      results = []
      from = params[:validated_from] || params[:received_from] || (Date.today - DAYS)
      to   = params[:validated_to]   || params[:received_to]   || Date.today

      from_str = from.strftime('%d/%m/%Y')
      to_str   = to.strftime('%d/%m/%Y')
      begin
        Timeout.timeout(900) do 
          Playwright.create(playwright_cli_executable_path: 'npx playwright') do |playwright|
            browser = playwright.chromium.launch(headless: false)
            page = browser.new_page

            begin
              # Go to base URL
              page.goto(authority.url)
              page.wait_for_load_state

              # === Accept disclaimer if shown ===
              if page.locator('form[action*="/Disclaimer/Accept"]').count > 0
                puts "🍪 Accepting disclaimer"
                page.click('form[action*="/Disclaimer/Accept"] input[type="submit"][value="Agree"]')
                page.wait_for_load_state
              else
                puts "ℹ️ No disclaimer page, continuing."
              end

              # === Fill in search dates ===
              page.click('input[name="DateReceivedFrom"]')
              page.keyboard.press('Control+A')
              page.keyboard.press('Backspace')
              page.keyboard.type(from_str)

              page.click('input[name="DateReceivedTo"]')
              page.keyboard.press('Control+A')
              page.keyboard.press('Backspace')
              page.keyboard.type(to_str)

              # === Submit search ===
              page.click('input.btn.btn-primary.px-5[value="Search"]')
              page.wait_for_load_state

              # === Detect if redirected straight to details page ===
              if page.locator('#searchResults-records').count == 0 && page.locator('.container .row:has-text("Proposal")').count > 0
                puts "🟢 Directly landed on single application detail page."
                # Extract data directly
                begin
                  # === Council Reference ===
                  ref_text = page.locator('h1.lgd-page-title-block__title').text_content.strip rescue nil

                  location   = page.locator('.row:has(.col-4:has-text("Location")) .col-8')&.text_content&.strip
                  proposal   = page.locator('.row:has(.col-4:has-text("Proposal")) .col-8')&.text_content&.strip
                  status     = page.locator('.row:has(.col-4:has-text("Status")) .col-8')&.text_content&.strip
                  date_received_txt = page.locator('.row:has(.col-4:has-text("Date Received")) .col-8')&.text_content&.strip
                  date_received = Date.parse(date_received_txt) rescue nil

                  docs_count = 0
                  docs_url   = page.url
                  if page.locator('a[aria-label="Tab heading: Documents."]').count > 0
                    page.click('a[aria-label="Tab heading: Documents."]') rescue nil
                    page.wait_for_selector('table.document-list', timeout: 8_000) rescue nil
                    docs_count = page.locator('table.document-list tbody tr').count rescue 0
                    docs_url   = page.url
                  end

                  app = Application.new
                  app.authority_name    = authority.name
                  app.council_reference = ref_text
                  app.date_received     = date_received
                  app.status            = status
                  app.info_url          = page.url
                  app.address           = location
                  app.description       = proposal
                  app.documents_count   = docs_count
                  app.documents_url     = docs_url

                  if app.valid?
                    puts "------------------------------------------------------------"
                    puts "  Ref:        #{app.council_reference}"
                    puts "  Address:    #{app.address}"
                    puts "  Description:#{app.description}"
                    puts "  Date:       #{app.date_received}"
                    puts "  Docs:       #{app.documents_count}"
                    puts "  Link:       #{app.info_url}"
                    puts "------------------------------------------------------------"
                    results << app
                  else
                    puts "⚠️ Single app invalid or missing fields."
                  end

                rescue => single_e
                  warn "⚠️ Error parsing single result: #{single_e.class} - #{single_e.message}"
                end

              else
                # === Normal results table flow ===
                puts "📄 Multiple results detected — proceeding normally."

                # Wait for results table
                page.wait_for_selector('#searchResults-records tbody tr', timeout: 30_000)

                # Prepare pagination loop
                page_num = 1
                max_pages = 200
                base_host = (authority.url[/^(https?:\/\/[^\/]+)/, 1] || authority.url)

                loop do
                  page.wait_for_selector('#searchResults-records tbody tr', timeout: 15_000) rescue nil
                  rows = page.locator('#searchResults-records tbody tr')
                  row_count = rows.count
                  puts "📋 Found #{row_count} applications on page #{page_num}"

                  (0...row_count).each do |i|
                    row = rows.nth(i)
                    ref_link = row.locator('th a')
                    next unless ref_link.count > 0

                    ref_text = ref_link.text_content&.strip
                    addr     = row.locator('td:nth-of-type(1)')&.text_content&.strip
                    desc     = row.locator('td:nth-of-type(2)')&.text_content&.strip
                    href     = ref_link.get_attribute('href')
                    info_url = href && !href.start_with?('http') ? URI.join(authority.url, href).to_s : href

                    puts "➡️ Opening application #{ref_text}"

                    begin
                      # Try clicking link, fallback to direct navigation
                      begin
                        ref_link.first.click
                      rescue
                        page.goto(info_url)
                      end

                      page.wait_for_selector('.container .row', timeout: 15_000)

                      location  = page.locator('.row:has(.col-4:has-text("Location")) .col-8')&.text_content&.strip
                      proposal  = page.locator('.row:has(.col-4:has-text("Proposal")) .col-8')&.text_content&.strip
                      status    = page.locator('.row:has(.col-4:has-text("Status")) .col-8')&.text_content&.strip
                      date_received_txt = page.locator('.row:has(.col-4:has-text("Date Received")) .col-8')&.text_content&.strip
                      date_received = Date.parse(date_received_txt) rescue nil

                      docs_count = 0
                      docs_url   = page.url
                      if page.locator('a[aria-label="Tab heading: Documents."]').count > 0
                        page.click('a[aria-label="Tab heading: Documents."]') rescue nil
                        page.wait_for_selector('table.document-list', timeout: 8_000) rescue nil
                        docs_count = page.locator('table.document-list tbody tr').count rescue 0
                        docs_url   = page.url
                      end

                      app = Application.new
                      app.authority_name    = authority.name
                      app.council_reference = ref_text
                      app.date_received     = date_received
                      app.status            = status
                      app.info_url          = info_url
                      app.address           = location || addr
                      app.description       = proposal || desc
                      app.documents_count   = docs_count
                      app.documents_url     = docs_url

                      if app.valid?
                        puts "------------------------------------------------------------"
                        puts "  Ref:        #{app.council_reference}"
                        puts "  Address:    #{app.address}"
                        puts "  Description:#{app.description}"
                        puts "  Date:       #{app.date_received}"
                        puts "  Docs:       #{app.documents_count}"
                        puts "  Link:       #{app.info_url}"
                        puts "------------------------------------------------------------"
                        results << app
                      else
                        puts "⚠️ Skipped invalid application (#{ref_text})"
                      end

                      # Return to results page
                      back_link = page.locator('a.service-cta-block__link--cta-action:has-text("Back to List")')
                      if back_link.count > 0
                        back_link.first.click
                        page.wait_for_selector('#searchResults-records tbody tr', timeout: 12_000)
                      else
                        page.goto("#{base_host}/Search/Results/#{page_num}")
                        page.wait_for_selector('#searchResults-records tbody tr', timeout: 12_000)
                      end

                    rescue => detail_err
                      warn "⚠️ Error scraping detail for #{ref_text}: #{detail_err.class} - #{detail_err.message}"
                      page.goto("#{base_host}/Search/Results/#{page_num}") rescue nil
                    ensure
                      page.wait_for_timeout(250)
                    end
                  end

                  # Pagination
                  next_anchor = page.locator('a[aria-label="Next Page."]').first rescue nil
                  if next_anchor && next_anchor.count > 0
                    next_href = next_anchor.get_attribute('href') rescue nil
                    break unless next_href
                    next_url = URI.join(authority.url, next_href).to_s
                    puts "➡️ Moving to next page: #{next_url}"
                    page.goto(next_url)
                    page.wait_for_selector('#searchResults-records tbody tr', timeout: 15_000)
                    page_num += 1
                    next
                  else
                    puts "✅ No more pages for Redcar and Cleveland."
                    break
                  end
                end
              end

              puts "✅ Finished scraping Redcar and Cleveland."

            rescue => e
              puts "❌ Error scraping Redcar and Cleveland: #{e.class} - #{e.message}"
              puts e.backtrace.first
            ensure
              browser.close rescue nil
            end
          end
        end
      end
      results
    end
    def self.scrape_ribble_valley(authority, params)
      puts "🔍 Scraping Ribble Valley"

      results = []
      from = params[:validated_from] || params[:received_from] || (Date.today - DAYS)
      to   = params[:validated_to]   || params[:received_to]   || Date.today

      from_str = from.strftime('%d/%m/%Y')
      to_str   = to.strftime('%d/%m/%Y')
      begin
        Timeout.timeout(900) do 
          Playwright.create(playwright_cli_executable_path: 'npx playwright') do |playwright|
            browser = playwright.chromium.launch(headless: false)
            page    = browser.new_page

            begin
              page.goto(authority.url)
              page.wait_for_load_state

              puts "📝 Setting decision date range: #{from_str} → #{to_str}"

              # Wait for the date dropdowns to appear
              page.wait_for_selector('select[name="fromDay"], select[name="fromMonth"], select[name="fromYear"]', timeout: 10_000)

              # === Fill FROM date
              page.locator('select[name="fromDay"]').select_option(value: from.day.to_s)
              page.locator('select[name="fromMonth"]').select_option(value: from.month.to_s)
              page.locator('select[name="fromYear"]').select_option(value: from.year.to_s)

              # === Fill TO date
              to_date = Date.parse(to_str)
              page.locator('select[name="toDay"]').select_option(value: to_date.day.to_s)
              page.locator('select[name="toMonth"]').select_option(value: to_date.month.to_s)
              page.locator('select[name="toYear"]').select_option(value: to_date.year.to_s)

              puts "✔️ Date range selected successfully"

              # Submit the form — prefer the form that contains the fromDay select
              form = page.locator('select[name="fromDay"]').locator('xpath=ancestor::form[1]')
              if form.count > 0
                submit = form.locator('input[type="submit"], button[type="submit"]').first
                if submit && submit.count > 0
                  submit.click
                elsif page.locator('input[type="submit"][value="Search"]').count > 0
                  page.click('input[type="submit"][value="Search"]')
                else
                  page.evaluate(%q{
                    () => {
                      const f = document.querySelector('select[name="fromDay"]')?.closest('form');
                      if (f) { f.submit(); return true; }
                      const anyForm = document.querySelector('form');
                      if (anyForm) { anyForm.submit(); return true; }
                      return false;
                    }
                  })
                end
              else
                if page.locator('input[type="submit"][value="Search"]').count > 0
                  page.click('input[type="submit"][value="Search"]')
                else
                  page.evaluate(%q{
                    () => {
                      const f = document.querySelector('form');
                      if (f) { f.submit(); return true; }
                      return false;
                    }
                  })
                end
              end

            # -------------------------
            # RESULTS SCRAPING
            # -------------------------
            page.wait_for_selector('form.basic_form table tbody tr', timeout: 30_000)

            loop do
              rows = page.locator('form.basic_form table tbody tr')
              total_rows = rows.count
              has_header = page.locator('form.basic_form table tbody tr th').count > 0
              start_index = has_header ? 1 : 0
              found_count = [total_rows - start_index, 0].max
              puts "📋 Found #{found_count} application rows on this page"

              (start_index...total_rows).each do |i|
                begin
                  row = rows.nth(i)

                  ref_link = row.locator('td a').first
                  next unless ref_link && ref_link.count > 0

                  ref_text = ref_link.text_content&.strip
                  href     = ref_link.get_attribute('href')
                  detail_url = href && !href.start_with?('http') ? URI.join(page.url, href).to_s : href

                  puts "➡️ Opening application #{ref_text} (#{detail_url})"

                  # click into details
                  ref_link.click
                  page.wait_for_selector('table.planningTable, table[summary="Planning Application Details"]', timeout: 15_000)

                  # helper for detail values
                  get_detail = lambda do |label|
                    begin
                      sel = %Q{table.planningTable tr:has(td:has-text("#{label}")) td:nth-of-type(2)}
                      val = page.locator(sel).first.text_content&.strip
                      val && !val.empty? ? val : nil
                    rescue
                      nil
                    end
                  end

                  # ✅ Extract description paragraph at top of details page
                  description_text = nil
                  begin
                    if page.locator('p.first').count > 0
                      raw_html = page.locator('p.first').first.inner_html
                      text = raw_html.gsub(/<br\s*\/?>/i, "\n").gsub(/<\/?[^>]*>/, '').strip
                      description_text = text unless text.empty?
                    end
                  rescue
                    description_text = nil
                  end

                  address_block = get_detail.call('Development address') || get_detail.call('Address') || ''

                  key_dates_block = get_detail.call('Key dates') || ''
                  rec_match   = key_dates_block&.match(/Received\s*[:\-]?\s*(\d{1,2}\/\d{1,2}\/\d{4})/i)
                  date_received = rec_match ? (Date.parse(rec_match[1]) rescue nil) : nil

                  status_text   = get_detail.call('Planning Status') || ''
                  decision_block = get_detail.call('Decision') || ''
                  decision_text = decision_block.gsub(/Date\s*[:\-]?\s*\d{1,2}\/\d{1,2}\/\d{4}/i, '').strip
                  decision_text = nil if decision_text == ''

                  info_url = detail_url || page.url

                  docs_count = 0
                  if page.locator('table.document-list, #documents, #myTable').count > 0
                    docs_count = page.locator('table.document-list tbody tr, #myTable tbody tr, #dgListOfDocuments tbody tr').count rescue 0
                  end

                  # --- Converted to Application.new ---
                  app = Application.new
                  app.authority_name    = authority.name
                  app.council_reference = ref_text
                  app.date_received     = date_received
                  app.status            = status_text
                  app.decision          = decision_text
                  app.info_url          = info_url
                  app.address           = address_block
                  app.description       = description_text || ''
                  app.documents_count   = docs_count
                  app.documents_url     = info_url

                  if app.valid?
                    puts "------------------------------------------------------------"
                    puts "  Ref:        #{app.council_reference}"
                    puts "  Address:    #{app.address}"
                    puts "  Description:#{app.description}"
                    puts "  Date:       #{app.date_received}"
                    puts "  Docs:       #{app.documents_count}"
                    puts "  Link:       #{app.info_url}"
                    puts "------------------------------------------------------------"                      
                    results << app
                    puts "  → Added application #{app.council_reference}"
                  else
                    puts "  ⚠️ Skipped invalid record (#{ref_text})"
                  end

                  page.go_back
                  page.wait_for_selector('form.basic_form table tbody tr', timeout: 10_000)
                  page.wait_for_timeout(250)

                rescue => e
                  puts "❌ Error processing row #{i}: #{e.class} - #{e.message}"
                  puts e.backtrace.first
                  begin
                    page.go_back
                    page.wait_for_selector('form.basic_form table tbody tr', timeout: 8_000)
                  rescue
                  end
                end
              end

              next_link = page.locator('p.center a:has-text("Next")')
              if next_link.count > 0
                puts "➡️ Moving to next page"
                next_link.click
                page.wait_for_selector('form.basic_form table tbody tr', timeout: 15_000)
                page.wait_for_timeout(500)
              else
                puts "✅ No more pages for Ribble Valley."
                break
              end
            end

            rescue => e
              puts "❌ Error using Playwright for Ribble Valley: #{e.class} - #{e.message}"
              puts e.backtrace.first
            ensure
              browser.close
            end
          end
        end
      end
      results
    end
    def self.scrape_rochford(authority, params)
      puts "🧀 Scraping Rochford (randoms1)"

      results = []
      from = params[:validated_from] || params[:received_from] || (Date.today - DAYS)
      to   = params[:validated_to]   || params[:received_to]   || Date.today

      from_str = from.strftime('%d/%m/%Y')
      to_str   = to.strftime('%d/%m/%Y')
      begin
        Timeout.timeout(900) do 
          Playwright.create(playwright_cli_executable_path: 'npx playwright') do |playwright|
            browser = playwright.chromium.launch(headless: false)
            page    = browser.new_page

            from = Date.parse(from_str)
            to   = Date.parse(to_str)

            # Go to search page
            page.goto(authority.url)
            page.wait_for_load_state

            # Fill FROM / TO dates
            from_str_fmt = from.strftime('%d/%m/%Y')
            to_str_fmt   = to.strftime('%d/%m/%Y')
            page.fill('input[name="DATEAPRECV:FROM:DATE"]', from_str_fmt)
            page.fill('input[name="DATEAPRECV:TO:DATE"]',   to_str_fmt)
            puts "📆 Date range: #{from_str_fmt} → #{to_str_fmt}"

            # Submit search
            page.click('#submit-advanced')
            page.wait_for_selector('#results dl dt a', timeout: 30_000)

            loop do
              app_links = page.query_selector_all('#results dl dt a')
              puts "📋 Found #{app_links.size} applications on this page"

              app_links.each_with_index do |link, idx|
                url = link.get_attribute('href')
                next unless url
                detail_url = URI.join(authority.url, url).to_s

                puts "🔗 (#{idx+1}/#{app_links.size}) Scraping detail: #{detail_url}"
                detail_page = browser.new_page
                detail_page.goto(detail_url)
                detail_page.wait_for_load_state

                # === Scrape main detail fields (robust XPath approach) ===
                details = {}

                # Collect all dt elements under the main definition list(s)
                dt_nodes = detail_page.query_selector_all('#results dl dt, dl.left dt, dl dt')
                dt_nodes.each do |dt|
                  begin
                    key = dt.inner_text.to_s.strip
                    # find the immediate following dd sibling (relative to this dt)
                    dd = dt.query_selector('xpath=following-sibling::dd[1]')
                    val = dd ? dd.inner_text.to_s.strip : nil
                    details[key] = val if key && !key.empty? && val && !val.empty?
                  rescue => _e
                    # ignore single dt failures and continue
                  end
                end

                # === Special handling: multiple "Proposal" entries ===
                begin
                  proposal_nodes = detail_page.query_selector_all(%q{xpath=//dl//dt[normalize-space(string())="Proposal" or normalize-space(string())="Proposal:"]})
                  if proposal_nodes && proposal_nodes.count >= 2
                    # use the second Proposal's following dd as the real description
                    second_dt = proposal_nodes[1]
                    real_proposal_dd = second_dt.query_selector('xpath=following-sibling::dd[1]')
                    if real_proposal_dd
                      details['Proposal: (second)'] = real_proposal_dd.inner_text.to_s.strip
                    end
                  end
                rescue
                  # ignore errors here
                end

                # === Important Dates (existing logic kept) ===
                dates_url = detail_page.query_selector('a:has-text("Important Dates")')&.get_attribute('href')
                if dates_url
                  dates_page = browser.new_page
                  dates_page.goto(URI.join(detail_url, dates_url).to_s)
                  dates_page.wait_for_load_state
                  dates_page.query_selector_all('dl dt').each do |dt|
                    begin
                      key = dt.inner_text.strip
                      dd  = dt.query_selector('xpath=following-sibling::dd[1]')&.inner_text&.strip
                      details[key] = dd if key && dd
                    rescue
                      next
                    end
                  end
                  dates_page.close
                end

                # === Plans and Documents (unchanged) ===
                docs_count = 0
                docs_url   = nil
                plans_url = detail_page.query_selector('a:has-text("Plans and Comments")')&.get_attribute('href')
                if plans_url
                  plans_page = browser.new_page
                  plans_page.goto(URI.join(detail_url, plans_url).to_s)
                  plans_page.wait_for_load_state

                  docs_link = plans_page.query_selector('a:has-text("Planning Documents")')&.get_attribute('href')
                  if docs_link
                    docs_url = URI.join(plans_url, docs_link).to_s
                    docs_page = browser.new_page
                    docs_page.goto(docs_url)
                    docs_page.wait_for_load_state
                    docs_count = docs_page.query_selector_all('.civica-doclistitem').count
                    docs_page.close
                  end

                  plans_page.close
                end

                # === Parse dates safely ===
                received_date  = (Date.parse(details["Date Application Received:"]) rescue nil)

                # --- Build Application object ---
                app = Application.new
                app.authority_name    = authority.name
                app.council_reference = details["Application Reference:"] || details["Application Ref:"] || details["Reference:"]

                # Address: prefer explicit "Address Of Proposal" or "Location" keys
                app.address = details["Address Of Proposal:"] ||
                              details["Address:"] ||
                              details["Location:"] ||
                              details["Site Address:"] ||
                              details["Location"] ||
                              details["Address Of Proposal"] ||
                              details["Location"]

                # Description: first try the second Proposal (if present), otherwise the usual Proposal key,
                # otherwise fall back to a generic Description/Details key.
                app.description = details['Proposal: (second)'] ||
                                  details['Proposal:'] ||
                                  details['Proposal'] ||
                                  details['Description:'] ||
                                  details['Details:'] ||
                                  details['Application type'] ||
                                  details['Application Type']

                app.status            = details["Status:"] || details["Current status"] || details["Status"]
                app.decision          = details["Decision:"] || details["Decision"]
                app.date_received     = received_date
                app.info_url          = detail_url
                app.documents_count   = docs_count
                app.documents_url     = docs_url


                if app.valid?
                  puts "------------------------------------------------------------"
                  puts "  Ref:        #{app.council_reference}"
                  puts "  Address:    #{app.address}"
                  puts "  Description:#{app.description}"
                  puts "  Date:       #{app.date_received}"
                  puts "  Docs:       #{app.documents_count}"
                  puts "  Link:       #{app.info_url}"
                  puts "------------------------------------------------------------"                       
                  results << app
                  puts "  → Added application #{app.council_reference}"
                else
                  puts "  ⚠️ Skipped invalid application (#{details["Application Reference:"]})"
                end

                detail_page.close
              end

              # === Pagination check ===
              # Stop if fewer than 10 applications found (last page)
              if app_links.size < 10
                puts "✅ Last page reached (#{app_links.size} apps)"
                break
              end

              next_button = page.locator('.atPagination li.next')
              if next_button.count > 0 && !next_button.get_attribute('class').to_s.include?('disabled')
                next_button.click
                page.wait_for_selector('#results dl dt a')
                page.wait_for_timeout(500)
              else
                break
              end
            end

            browser.close
          end
        end
      end
      results
    end
    def self.scrape_rotherham(authority, params)
      puts "🔍 Scraping Rotherham (FastWeb + ExtJS Docs)"

      results = []
      from = params[:validated_from] || params[:received_from] || (Date.today - DAYS)
      to   = params[:validated_to]   || params[:received_to]   || Date.today

      from_str = from.strftime('%d/%m/%Y')
      to_str   = to.strftime('%d/%m/%Y')
      begin
        Timeout.timeout(900) do 
          Playwright.create(playwright_cli_executable_path: 'npx playwright') do |playwright|
            browser = playwright.chromium.launch(headless: false)
            page = browser.new_page

            # Go to base URL
            page.goto(authority.url)
            page.wait_for_load_state
            puts "✅ Loaded Rotherham FastWeb search page"

            # Clear and type dates manually for reliability
            page.click('#DateReceivedStart')
            page.keyboard.press('Control+A')
            page.keyboard.press('Backspace')
            page.keyboard.type(from_str)

            page.click('#DateReceivedEnd')
            page.keyboard.press('Control+A')
            page.keyboard.press('Backspace')
            page.keyboard.type(to_str)
            puts "📅 Entered date range: #{from_str} → #{to_str}"

            # --- Sort by Received Date ---
            if page.locator('#Sort1').count > 0
              page.select_option('#Sort1', label: 'Received Date')
              puts "✅ Sorted by Received Date"
            end

            # --- Click Search ---
            page.click('#Submit')
            page.wait_for_load_state
            page.wait_for_selector('table', timeout: 15_000)
            puts "🔍 Submitted search and loaded results"

            # --- RESULTS PAGINATION LOOP ---
            loop do
              html = page.content
              doc = Nokogiri::HTML(html)
              app_tables = doc.css('td.RecordTitle:contains("App. No.")').map { |td| td.ancestors('table').first }.uniq
              puts "📋 Found #{app_tables.size} applications on this page"

              app_tables.each_with_index do |table, i|
                begin
                  ref_link = table.at_css('a[href*="detail.asp"]')
                  next unless ref_link

                  ref_text = ref_link.text.strip
                  href = ref_link['href']
                  next unless href

                  app_url = URI.join(authority.url, href).to_s
                  puts "➡️ Opening #{ref_text}..."

                  page.goto(app_url)
                  page.wait_for_load_state
                  page.wait_for_selector('table', timeout: 10_000)

                  # --- SCRAPE DETAILS ---
                  details = {}

                  detail_html = Nokogiri::HTML(page.content)

                  # Capture <th class="RecordTitle"> + <td class="RecordDetail">
                  detail_html.css('tr').each do |tr|
                    th = tr.at_css('th.RecordTitle')&.text&.strip
                    td = tr.at_css('td.RecordDetail')&.text&.strip
                    next unless th && td && !th.empty? && !td.empty?
                    details[th.gsub(/\s+/, " ")] = td.gsub(/\s+/, " ")
                  end

                  # Extract fields safely
                  council_ref = details['Planning Application Number:'] ||
                                details['Application Number:'] ||
                                ref_text

                  address     = details['Site Address:'] ||
                                details['Address:'] ||
                                details['Location:']

                  description = details['Description:'] ||
                                details['Proposal:'] ||
                                details['Development:']

                  raw_date    = details['Date Received:'] ||
                                details['Received Date:']

                  # Parse date safely (handles "27 October 2025" or "27/10/2025")
                  date_recv = nil
                  if raw_date
                    begin
                      if raw_date =~ /\d{1,2}\/\d{1,2}\/\d{4}/
                        date_recv = Date.strptime(raw_date.strip, '%d/%m/%Y')
                      else
                        date_recv = Date.parse(raw_date.strip)
                      end
                    rescue
                      date_recv = nil
                    end
                  end

                  status      = details['Application Status:'] ||
                                  details['Status:']

                  decision    = details['Decision Type:'] ||
                                  details['Decision:'] ||
                                  details['Decision Description:']

                  puts "📋 Parsed details for #{council_ref}:"
                  puts "    Address: #{address}"
                  puts "    Description: #{description}"
                  puts "    Received: #{date_recv}"

                  # --- DOCUMENTS (FastWeb + ExtJS variant) ---
                  docs_count = 0
                  docs_url = nil

                  begin
                    doc_link_locator = page.locator('a:has-text("Documents"), a:has-text("Plans")')
                    if doc_link_locator.count == 0
                      puts "ℹ️ No documents/plans link found on detail page."
                    else
                      link = doc_link_locator.first
                      href = link.get_attribute('href') rescue nil
                      href = href.to_s.strip if href

                      if href && href != '' && href != '#' && !href.start_with?('javascript:')
                        docs_url = URI.join(page.url, href).to_s rescue href
                        puts "📎 Opening documents page: #{docs_url}"
                        docs_page = browser.new_page
                        begin
                          docs_page.goto(docs_url)
                          docs_page.wait_for_load_state

                          # --- Rotherham ExtJS style grid detection ---
                          if docs_page.locator('#FilesGrid').count > 0
                            puts "✅ Detected ExtJS documents grid (#FilesGrid)"
                            begin
                              docs_page.wait_for_selector('#FilesGrid tbody tr', timeout: 10_000)
                              docs_count = docs_page.locator('#FilesGrid tbody tr').count rescue 0
                              puts "ℹ️ Counted #{docs_count} document rows in ExtJS grid"
                            rescue
                              puts "⚠️ Could not count ExtJS rows (may be dynamically loaded)"
                            end
                          else
                            # --- Normal FastWeb fallback ---
                            begin
                              docs_page.wait_for_selector('#searchResult_info, #searchResult tbody tr', timeout: 8_000)
                              info_text = (docs_page.locator('#searchResult_info').inner_text rescue '') || ''
                              if info_text =~ /of\s+(\d+)\s+entries/i
                                docs_count = $1.to_i
                                puts "ℹ️ Extracted docs count: #{docs_count}"
                              else
                                docs_count = docs_page.locator('#searchResult tbody tr').count rescue 0
                                puts "ℹ️ Counted #{docs_count} FastWeb-style docs"
                              end
                            rescue => fw_err
                              puts "⚠️ FastWeb fallback failed: #{fw_err.message}"
                            end
                          end
                        ensure
                          docs_page.close rescue nil
                        end
                      else
                        # Inline click variant
                        puts "📎 Clicking inline documents link..."
                        link.click
                        begin
                          page.wait_for_selector('#FilesGrid, #searchResult', timeout: 10_000)
                          if page.locator('#FilesGrid').count > 0
                            docs_count = page.locator('#FilesGrid tbody tr').count rescue 0
                            puts "ℹ️ Counted #{docs_count} inline ExtJS documents"
                            docs_url = page.url
                          else
                            docs_count = page.locator('#searchResult tbody tr').count rescue 0
                            puts "ℹ️ Counted #{docs_count} inline FastWeb documents"
                            docs_url = page.url
                          end
                        rescue => inline_err
                          puts "⚠️ Inline document count failed: #{inline_err.message}"
                        end
                      end
                    end
                  rescue => doc_err
                    puts "⚠️ Error scraping documents: #{doc_err.class} - #{doc_err.message}"
                  ensure
                    if page.url !~ /detail\.asp/i
                      page.go_back rescue nil
                      page.wait_for_selector('table', timeout: 10_000) rescue nil
                    end
                  end

                  # --- BUILD APPLICATION OBJECT ---
                  app = Application.new
                  app.authority_name    = authority.name
                  app.council_reference = council_ref
                  app.date_received     = date_recv
                  app.status            = status
                  app.decision          = decision
                  app.info_url          = app_url
                  app.address           = address
                  app.description       = description
                  app.documents_count   = docs_count
                  app.documents_url     = docs_url

                  if app.valid?
                    puts "------------------------------------------------------------"
                    puts "  Ref:        #{app.council_reference}"
                    puts "  Address:    #{app.address}"
                    puts "  Description:#{app.description}"
                    puts "  Date:       #{app.date_received}"
                    puts "  Docs:       #{app.documents_count}"
                    puts "  Link:       #{app.info_url}"
                    puts "------------------------------------------------------------"                         
                    results << app
                    puts "  ✅ Added #{app.council_reference}"
                  else
                    puts "  ⚠️ Skipped invalid application (#{council_ref})"
                  end

                  page.go_back
                  page.wait_for_selector('table', timeout: 10_000)
                rescue => row_err
                  puts "❌ Error on app #{i + 1}: #{row_err.class} - #{row_err.message}"
                  next
                end
              end

              # --- PAGINATION ---
              begin
                next_link = page.locator('a.dialog:has-text("Next")')
                if next_link.count > 0
                  puts "➡️ Moving to next page..."
                  next_link.first.click
                  page.wait_for_load_state
                  page.wait_for_selector('table', timeout: 12_000)
                else
                  puts "ℹ️ No more pages."
                  break
                end
              rescue => pag_err
                puts "⚠️ Pagination ended or failed: #{pag_err.message}"
                break
              end
            end # loop

            browser.close
          end # Playwright.create 
        end
      end
      results
    end
    def self.scrape_sedgemoor(authority, params)
      puts "🪣 Scraping Sedgemoor with Playwright"

      results = []
      from = params[:validated_from] || params[:received_from] || (Date.today - DAYS)
      to   = params[:validated_to]   || params[:received_to]   || Date.today

      from_str = from.strftime('%d/%m/%Y')
      to_str   = to.strftime('%d/%m/%Y')
      begin
        Timeout.timeout(3000) do 
          Playwright.create(playwright_cli_executable_path: 'npx playwright') do |playwright|
            browser = playwright.chromium.launch(headless: false)
            page    = browser.new_page

            begin
              from = Date.parse(from_str) rescue nil
              to   = Date.parse(to_str)   rescue nil

              page.goto(authority.url)
              page.wait_for_load_state
              sleep 1
              if page.locator('select[name="dateType"]').count > 0
                page.select_option('select[name="dateType"]', value: 'RegDate') rescue nil
              end
              page.fill('input[name="dateFrom"]', from.strftime('%d/%m/%Y')) rescue nil if from
              page.fill('input[name="dateTo"]',   to.strftime('%d/%m/%Y')) rescue nil if to

              puts "📅 Setting decision date range: #{from&.strftime('%d/%m/%Y')} → #{to&.strftime('%d/%m/%Y')}"

              if page.locator('input#Submit').count > 0
                page.click('input#Submit')
              elsif page.locator('input[name="Submit"]').count > 0
                page.click('input[name="Submit"]')
              else
                page.click('input[type="submit"][value="Submit"]') rescue nil
              end

              page.wait_for_selector('#paging-table tbody tr', timeout: 30_000)

              # --- NEW pagination logic: collect total pages first ---
              total_pages = page.locator('div.dataTables_paginate span a.paginate_button').count rescue 1
              total_pages = 1 if total_pages < 1
              puts "📑 Detected #{total_pages} pages of results"

              (1..total_pages).each do |page_num|
                # if not on first page, click the page number
                if page_num > 1
                  puts "➡️ Navigating to page #{page_num}"
                  page.click("div.dataTables_paginate span a.paginate_button:has-text('#{page_num}')")
                  page.wait_for_selector('#paging-table tbody tr', timeout: 15_000)
                  page.wait_for_timeout(500)
                end

                rows = page.locator('#paging-table tbody tr')
                row_count = rows.count
                puts "📋 Found #{row_count} applications on page #{page_num}"

                (0...row_count).each do |i|
                  begin
                    row = rows.nth(i)
                    ref_text = row.locator('label#caseRef').first.text_content&.strip rescue nil
                    reg_txt  = row.locator('div.two__col__list__item__row:has(.two__col__list__search__header:has-text("Registered Date")) .two__col__list__data').first&.text_content&.strip rescue nil
                    type_txt = row.locator('div.two__col__list__item__row:has(.two__col__list__search__header:has-text("Type")) .two__col__list__data').first&.text_content&.strip rescue nil
                    location_txt  = row.locator('div.two__col__list__item__row:has(.two__col__list__search__header:has-text("Location")) .two__col__list__data').first&.text_content&.strip rescue nil
                    proposal_txt  = row.locator('div.two__col__list__item__Row:has(.two__col__list__search__header:has-text("Proposal")), div.two__col__list__item__row:has(.two__col__list__search__header:has-text("Proposal")) .two__col__list__data').first&.text_content&.strip rescue nil

                    view_btn = row.locator('input[value="View Details"]').first rescue nil
                    detail_url = nil
                    if view_btn && view_btn.count > 0
                      onclick = view_btn.get_attribute('onclick') rescue nil
                      if onclick && onclick =~ /location\.href\s*=\s*['"]([^'"]+)['"]/
                        href = Regexp.last_match(1)
                        detail_url = URI.join(authority.url, href).to_s rescue nil
                      end
                    else
                      anchor = row.locator('a').first rescue nil
                      if anchor && anchor.count > 0
                        href = anchor.get_attribute('href') rescue nil
                        detail_url = href && !href.start_with?('http') ? URI.join(authority.url, href).to_s : href
                      end
                    end

                    puts "➡️ Opening application #{ref_text || '(no ref)'}"

                    if view_btn && view_btn.count > 0
                      view_btn.click
                      page.wait_for_selector('#Details, .tab__content', timeout: 15_000)
                    elsif detail_url
                      page.goto(detail_url)
                      page.wait_for_selector('#Details, .tab__content', timeout: 15_000)
                    else
                      puts "⚠️ Can't open detail for row #{i+1}, skipping"
                      next
                    end

                    get_detail = lambda do |label|
                      begin
                        sel = %Q{#Details .two__col__list__item__row:has(.two__col__list__search__header:has-text("#{label}")) .two__col__list__data}
                        val = page.locator(sel).first.text_content&.strip
                        val && !val.empty? ? val : nil
                      rescue
                        nil
                      end
                    end

                    application_number = get_detail.call('Application Number:') || ref_text || get_detail.call('Application Number')
                    registered_date_txt = get_detail.call('Registered Date:') || reg_txt
                    registered_date = Date.parse(registered_date_txt) rescue nil
                    location = get_detail.call('Location:') || location_txt
                    proposal = get_detail.call('Proposal:') || proposal_txt
                    app_type    = get_detail.call('Type:') || type_txt

                    docs_count = 0
                    docs_url   = page.url
                    if page.locator('button.tablinks:has-text("Planning Documents")').count > 0
                      page.click('button.tablinks:has-text("Planning Documents")') rescue nil
                      page.wait_for_timeout(300)
                    end
                    if page.locator('div.document__section__header:has-text("View Planning Application")').count > 0
                      page.locator('div.document__section__header:has-text("View Planning Application")').first.click rescue nil
                      page.wait_for_timeout(300)
                    end
                    docs_count += page.locator('table#PlanningApplication tbody tr').count rescue 0
                    if page.locator('div.document__section__header:has-text("View Plans")').count > 0
                      page.locator('div.document__section__header:has-text("View Plans")').first.click rescue nil
                      page.wait_for_timeout(300)
                    end
                    docs_count += page.locator('table#Plans tbody tr').count rescue 0
                    if docs_count == 0
                      docs_count = page.locator('table.dataTable tbody tr').count rescue 0
                    end

                    # --- BUILD APPLICATION OBJECT ---
                    app = Application.new
                    app.authority_name    = authority.name
                    app.council_reference = application_number
                    app.date_received     = registered_date
                    app.info_url          = page.url
                    app.address           = location
                    app.description       = proposal
                    app.documents_count   = docs_count
                    app.documents_url     = docs_url

                    if app.valid?
                      puts "------------------------------------------------------------"
                      puts "  Ref:        #{app.council_reference}"
                      puts "  Address:    #{app.address}"
                      puts "  Description:#{app.description}"
                      puts "  Date:       #{app.date_received}"
                      puts "  Docs:       #{app.documents_count}"
                      puts "  Link:       #{app.info_url}"
                      puts "------------------------------------------------------------"                         
                      results << app
                      puts "  → Added application #{app.council_reference}"
                    else
                      puts "  ⚠️ Skipped invalid application (#{application_number})"
                    end

                    # go back to results page
                    page.go_back
                    page.wait_for_selector('#paging-table tbody tr', timeout: 10_000)
                    page.wait_for_timeout(250)

                    # IMPORTANT: restore to the current listing page (page_num)
                    if page_num > 1
                      (page_num - 1).times do |k|
                        next_btn = page.locator('div.dataTables_paginate a.paginate_button.next').first rescue nil
                        if next_btn && next_btn.count > 0 && !next_btn.get_attribute('class').to_s.include?('disabled')
                          next_btn.click
                          page.wait_for_selector('#paging-table tbody tr', timeout: 10_000)
                          page.wait_for_timeout(250)
                        else
                          page.click("div.dataTables_paginate span a.paginate_button:has-text('#{page_num}')") rescue nil
                          page.wait_for_selector('#paging-table tbody tr', timeout: 10_000) rescue nil
                          page.wait_for_timeout(250)
                          break
                        end
                      end
                      puts "🔁 Restored to page #{page_num} after returning from detail"
                    end

                  rescue => row_err
                    puts "❌ Error processing Sedgemoor row #{i + 1}: #{row_err.class} - #{row_err.message}"
                    puts row_err.backtrace.first
                    begin
                      page.go_back
                      page.wait_for_selector('#paging-table tbody tr', timeout: 8_000)
                    rescue
                    end
                    next
                  end
                end
              end

              puts "✅ Finished all pages for Sedgemoor."

            rescue => e
              puts "❌ Error scraping Sedgemoor: #{e.class} - #{e.message}"
              puts e.backtrace.first
            ensure
              browser.close rescue nil
            end
          end
        end
      end
      results
    end
    def self.scrape_somerset_west_and_taunton(authority, params)
      puts "🌳 Scraping Somerset with Playwright"

      results = []
      from = params[:validated_from] || params[:received_from] || (Date.today - DAYS)
      to   = params[:validated_to]   || params[:received_to]   || Date.today

      from_str = from.strftime('%d/%m/%Y')
      to_str   = to.strftime('%d/%m/%Y')
      begin
        Timeout.timeout(900) do 
          Playwright.create(playwright_cli_executable_path: 'npx playwright') do |playwright|
            browser = playwright.chromium.launch(headless: false)
            page    = browser.new_page

            begin
              from = Date.parse(from_str) rescue nil
              to   = Date.parse(to_str)   rescue nil

              # Go to search page
              page.goto(authority.url)
              page.wait_for_load_state

              # Fill date fields (same keys as Mechanize version)
              page.fill('input[name="regdate1"]', from.strftime('%d/%m/%Y')) rescue nil if from
              page.fill('input[name="regdate2"]', to.strftime('%d/%m/%Y')) rescue nil if to

              puts "📅 Setting registration date range: #{from&.strftime('%d/%m/%Y')} → #{to&.strftime('%d/%m/%Y')}"

              # Submit the search form (try a few fallbacks)
              if page.locator('input[name="submit"]').count > 0
                page.click('input[name="submit"]')
              elsif page.locator('input[type="submit"][value]').count > 0
                page.locator('input[type="submit"][value]').first.click
              else
                page.evaluate(%q{
                  () => {
                    const f = document.querySelector('form');
                    if (f) { f.submit(); return true; }
                    return false;
                  }
                })
              end

              # Wait for results area
              page.wait_for_selector('#primary', timeout: 30_000)

              # Click "View full list" if present (helps avoid pagination)
              if page.locator('input.SWTbutton').count > 0
                clicked_full = false
                page.locator('input.SWTbutton').count.times do |bi|
                  btn = page.locator('input.SWTbutton').nth(bi)
                  val = (btn.get_attribute('value') || '').to_s
                  if val.downcase.include?('full') || val.downcase.include?('full document') || val.downcase.include?('full list')
                    btn.click rescue nil
                    page.wait_for_selector('#primary table.tablewid100.table-bordered.table-striped', timeout: 10_000) rescue nil
                    clicked_full = true
                    break
                  end
                end
                puts "ℹ️ Clicked 'View full list' (if present): #{clicked_full}"
              end

              # Ensure there are result item tables
              page.wait_for_selector('#primary table.tablewid100.table-bordered.table-striped', timeout: 15_000)

              # Collect all result tables
              tables_locator = page.locator('#primary table.tablewid100.table-bordered.table-striped')
              table_count = tables_locator.count
              puts "📋 Found #{table_count} application tables on this page"

              (0...table_count).each do |idx|
                begin
                  table = page.locator('#primary table.tablewid100.table-bordered.table-striped').nth(idx)

                  ref_anchor = table.locator('tr.zsubheader td a').first rescue nil
                  ref_text   = ref_anchor&.text_content&.strip
                  reg_td     = table.locator('tr.zsubheader td.zAlignRight').first
                  reg_text   = reg_td&.text_content&.strip

                  puts "➡️ Opening application #{ref_text || "(row #{idx + 1})"}"

                  # Click "View details" or fallback to anchor
                  if table.locator('input.SWTbutton[value="View details"]').count > 0
                    table.locator('input.SWTbutton[value="View details"]').first.click
                  else
                    if ref_anchor && (href = ref_anchor.get_attribute('href'))
                      page.goto(URI.join(page.url, href).to_s)
                    else
                      puts "⚠️ No details button or link found for table #{idx + 1}, skipping"
                      next
                    end
                  end

                  page.wait_for_selector('table.tablewid100.table-bordered.table-striped caption', timeout: 15_000)

                  details_table = page.locator('table.tablewid100.table-bordered.table-striped:has(caption:has-text("Planning application"))').first rescue nil

                  details = {}
                  if details_table && details_table.count > 0
                    rows = details_table.locator('tbody tr')
                    rows.count.times do |r|
                      th = rows.nth(r).locator('th').first rescue nil
                      td = rows.nth(r).locator('td').first rescue nil
                      next unless th && td
                      key = th.text_content.to_s.gsub(/\u00A0/, ' ').strip
                      val = td.text_content.to_s.strip
                      key_norm = key.gsub(/\s+/, ' ').strip
                      details[key_norm] = val
                    end
                  else
                    page.locator('table.tablewid100.table-bordered.table-striped tbody tr').each do |r|
                      k = r.locator('th').first&.text_content&.strip rescue nil
                      v = r.locator('td').first&.text_content&.strip rescue nil
                      next unless k
                      details[k.gsub(/\s+/, ' ').strip] = v
                    end
                  end

                  docs_count = 0
                  docs_url   = nil
                  docs_table = page.locator('table.tablewid100.table-bordered.table-striped:has(th:has-text("Date received"))').first rescue nil
                  if docs_table && docs_table.count > 0
                    docs_rows = docs_table.locator('tbody tr')
                    docs_count = docs_rows.count
                    if docs_count > 0
                      first_link = docs_table.locator('tbody tr td a.SWTButton').first rescue nil
                      href = first_link&.get_attribute('href') rescue nil
                      docs_url = href && !href.start_with?('http') ? URI.join(page.url, href).to_s : href
                    end
                  else
                    all_doc_links = page.locator('a.SWTButton, a:has-text("View image")')
                    docs_count = all_doc_links.count
                    docs_url = (all_doc_links.first.get_attribute('href') rescue nil) if docs_count > 0
                    docs_url = docs_url && !docs_url.start_with?('http') ? URI.join(page.url, docs_url).to_s : docs_url
                  end

                  council_reference = details['Application number'] || details['Application number '] || details['Application number :'] || ref_text
                  date_received     = (Date.parse(details['Received']) rescue nil)
                  date_registered   = (Date.parse(details['Registered']) rescue nil)
                  status_text       = details['Status']
                  proposal_text     = details['Proposal']
                  address_block     = details['Correspondent address'] || details['Correspondent'] || details['Applicant'] || ''

                  # --- Build app (Amber Valley style) ---
                  app = Application.new
                  app.authority_name    = authority.name
                  app.council_reference = council_reference
                  app.date_received     = date_received
                  app.date_validated    = date_registered
                  app.status            = status_text
                  app.info_url          = page.url
                  app.address           = address_block
                  app.description       = proposal_text
                  app.documents_count   = docs_count
                  app.documents_url     = docs_url || page.url

                  if app.valid?
                    puts "------------------------------------------------------------"
                    puts "  Ref:        #{app.council_reference}"
                    puts "  Address:    #{app.address}"
                    puts "  Description:#{app.description}"
                    puts "  Date:       #{app.date_received}"
                    puts "  Docs:       #{app.documents_count}"
                    puts "  Link:       #{app.info_url}"
                    puts "------------------------------------------------------------"                       
                    results << app.to_hash
                    puts "  → Added application #{app.council_reference}"
                  else
                    puts "  ⚠️ Skipped invalid record (#{council_reference})"
                  end

                  # Return to results list
                  page.go_back
                  page.wait_for_selector('#primary table.tablewid100.table-bordered.table-striped', timeout: 12_000)
                  page.wait_for_timeout(250)

                rescue => row_e
                  puts "❌ Error processing Somerset row #{idx + 1}: #{row_e.class} - #{row_e.message}"
                  puts row_e.backtrace.first
                  begin
                    page.go_back
                    page.wait_for_selector('#primary table.tablewid100.table-bordered.table-striped', timeout: 8_000)
                  rescue
                  end
                  next
                end
              end

            rescue => e
              puts "❌ Error scraping Somerset West and Taunton: #{e.class} - #{e.message}"
              puts e.backtrace.first
            ensure
              browser.close rescue nil
            end
          end
        end
      end
      results
    end





    # ---------------------------------------------------
    # SMALL HELPERS
    # ---------------------------------------------------
    def self.safe_text(page, selector)
      page.locator(selector)&.text_content&.strip
    rescue
      nil
    end

    def self.parse_date(str)
      return nil unless str
      Date.parse(str) rescue nil
    end

  end
end
