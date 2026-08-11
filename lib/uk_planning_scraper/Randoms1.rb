# frozen_string_literal: true
require 'addressable/uri'
require 'mechanize'
require 'date'
require_relative 'playwright_compat'
require_relative 'utils'
require_relative 'application'

DAYS = 7 unless defined?(DAYS)

module UKPlanningScraper
  class Randoms1Scraper

    # ============================================================
    #  ENTRY POINT — Called by Authority#scrape_randoms1
    # ============================================================
    def self.scrape(authority, params = {}, options = {})
      puts "🛠 Running Randoms1Scraper for #{authority.name} (#{authority.url})"

      case authority.name.strip
      when /Amber Valley/i
        scrape_amber_valley(authority, params)
      when /Ashfield/i
        scrape_ashfield(authority, params)
      when /Barnsley/i
        scrape_barnsley(authority, params)
      when /Bath And North East Somerset/i
        scrape_bath_and_north_east_somerset(authority, params)
      when /Boston/i
        scrape_boston(authority, params)        
      when /Bridgend/i
        scrape_bridgend(authority, params)        
      when /Camden/i
        scrape_camden(authority, params)        
      when /Carmarthenshire/i
        scrape_carmarthenshire(authority, params)     
      when /Central Bedfordshire/i
        scrape_central_bedfordshire(authority, params)  
      when /Colchester/i
        scrape_colchester(authority, params)  
      when /Copeland/i
        scrape_copeland(authority, params)  
      when /Crawley/i
        scrape_crawley(authority, params)  
      when /Dorset/i
        scrape_dorset(authority, params)  
      when /East Staffordshire/i
        scrape_eastleigh(authority, params)  
      when /Eastleigh/i
        scrape_eastleigh(authority, params)  
      when /Elmbridge/i
        scrape_elmbridge(authority, params)  
      when /Erewash/i
        scrape_erewash(authority, params)  
      when /Fareham/i
        scrape_fareham(authority, params)  
      when /Herefordshire/i
        scrape_herefordshire(authority, params)  

      # Add more Randoms1 cases here:
      #
      # when /Ashford/i
      #   scrape_ashford(authority, params)
      #
      # when /Fareham/i
      #   scrape_fareham(authority, params)

      else
        puts "⚠️ No Randoms1 scraper implementation for #{authority.name}"
        []
      end

    rescue => e
      puts "❌ Randoms1Scraper error for #{authority.name}: #{e.class} - #{e.message}"
      puts e.backtrace.first
      []
    end



    # ===================================================================
    # AMBER VALLEY — FULLY WORKING VERSION
    # ===================================================================
    def self.scrape_amber_valley(authority, params)
      results = []

      # Use validated_from/to if present, else received_from (we only need "from" for the cutoff)
      from = params[:validated_from] || params[:received_from] || (Date.today - DAYS)
      to   = params[:validated_to]   || params[:received_to]   || Date.today

      begin
        Timeout.timeout(900) do 
          Playwright.create(playwright_cli_executable_path: Playwright::CLI_EXECUTABLE_PATH) do |playwright|
            browser = playwright.chromium.launch(headless: false)
            page = browser.new_page

            begin
              page.goto(authority.url)
              page.wait_for_load_state

              # Accept cookies
              allow_btn = page.locator('#CybotCookiebotDialogBodyLevelButtonLevelOptinAllowAll')
              begin
                allow_btn.click if allow_btn.count > 0
              rescue; end

              # Open the section (you already changed this to collapse4)
              begin
                page.click('a[href="#collapse4"]')
              rescue; end

              # NO date fields to fill any more

              # Click the correct search button for this section
              begin
                page.click('#btnLookupNonDetermined')
              rescue; end

              page.wait_for_selector('#listOfPlanApps tbody tr', timeout: 15000)

              # Filter to show 100 applications per page (DataTables)
              begin
                page.locator('select[name="listOfPlanApps_length"]').select_option(value: '100')
                page.wait_for_timeout(2000) # give DataTables time to reload the table
              rescue => e
                puts "⚠️ Failed to set 100 entries: #{e.message}"
              end

              # Now scrape from the top (newest) downwards until we hit the "from" cutoff date
              scraping_complete = false

              loop do
                rows = page.locator('#listOfPlanApps tbody tr')
                count = rows.count
                break if count == 0

                count.times do |i|
                  row = rows.nth(i)
                  ref_link = row.locator('td a.refValButton')
                  next unless ref_link.count > 0

                  # === CUTOFF CHECK: use the "Date valid" column from the table ===
                  # The hidden <span> contains a reliable ISO date (e.g. 2026-03-09T00:00:00.000Z)
                  date_iso = ''
                  begin
                    date_iso = row.locator('td:nth-child(2) span').inner_text
                  rescue; end

                  table_date = nil
                  if date_iso.match?(/^\d{4}-\d{2}-\d{2}/)
                    begin
                      table_date = Date.parse(date_iso.split('T').first)
                    rescue; end
                  end

                  if table_date && table_date < from
                    puts "  → Reached cutoff date #{table_date} (from: #{from}), stopping scrape"
                    scraping_complete = true
                    break
                  end

                  # === Proceed with the original modal scraping logic ===
                  ref_link.first.click
                  page.wait_for_selector('#appDetailsSubContainer', timeout: 10000)

                  # Extract details (exactly as before)
                  ref_text      = safe_text(page, '#appRefVal')
                  address_text  = safe_text(page, '#applicationAddress')
                  desc_text     = safe_text(page, '#proposal')
                  status_text   = safe_text(page, '#status')
                  decision_text = safe_text(page, '#decType')
                  date_reg_text = safe_text(page, '#dateRegistered')

                  date_received = parse_date(date_reg_text)

                  docs_count = page.locator('#listOfPlanAppDocuments tbody tr').count rescue 0

                  app = Application.new
                  app.authority_name    = authority.name
                  app.council_reference = ref_text
                  app.address           = address_text
                  app.description       = desc_text
                  app.date_received     = date_received
                  app.status            = status_text
                  app.decision          = decision_text
                  app.documents_count   = docs_count
                  app.info_url          = authority.url
                  app.documents_url     = authority.url

                  if app.valid?
                    results << app
                    puts "  → Added #{app.council_reference}"
                  else
                    puts "  ⚠️ Invalid record skipped"
                  end

                  # Close modal
                  begin
                    page.click('#infoPop button.close[data-dismiss="modal"]')
                  rescue; end

                  page.wait_for_timeout(200)
                end

                break if scraping_complete

                # Pagination (adapted for 100-per-page)
                break if count < 100

                next_btn = page.locator('a[aria-controls="listOfPlanApps"][data-dt-idx]:has-text("Next")')
                break unless next_btn.count > 0
                break if next_btn.get_attribute('class').to_s =~ /disabled/

                next_btn.click
                page.wait_for_selector('#listOfPlanApps tbody tr')
              end

            rescue => e
              puts "⚠️ Amber Valley scraping error: #{e.class} - #{e.message}"
            ensure
              browser.close rescue nil
            end
          end
        end
      end
      results
    end

    def self.scrape_ashfield(authority, params)
      puts "🔍 Scraping Ashfield (randoms1)"
      results = []
      begin
        Timeout.timeout(900) do 
          Playwright.create(playwright_cli_executable_path: Playwright::CLI_EXECUTABLE_PATH) do |playwright|
            browser = playwright.chromium.launch(headless: false)
            page = browser.new_page

            # Go to base URL
            page.goto(authority.url)
            page.wait_for_load_state

            # Fill date range (dynamic IDs → match by placeholder)
            from = params[:validated_from] || params[:received_from] || (Date.today - DAYS)
            to   = params[:validated_to]   || params[:received_to]   || Date.today

            from_str = from.strftime('%d/%m/%Y')
            to_str   = to.strftime('%d/%m/%Y')
            date_inputs = page.locator('input[placeholder="DD/MM/YYYY"]')
            date_inputs.nth(0).fill(from_str)
            date_inputs.nth(1).fill(to_str)

            # Submit search
            page.click('.advancedsearchbutton')

            # Wait for initial results
            page.wait_for_selector('li.civica-keyobjectlistitem', timeout: 20_000)

            last_first_ref = nil

            loop do
              # === SCRAPE RESULTS ON CURRENT PAGE ===
              items = page.locator('li.civica-keyobjectlistitem')
              count = items.count
              puts "📋 Found #{count} applications on this page"

              items.count.times do |i|
                item = items.nth(i)

                ref_link = item.locator('a.civica-gfplanning-internetdesc')
                next unless ref_link.count > 0

                ref_text     = ref_link.text_content&.strip
                address_text = item.locator('.civica-gfplanning-applicationaddress')&.text_content&.strip
                desc_text    = item.locator('.civica-gfplanning-proposal')&.text_content&.strip

                # Open detail page
                ref_link.click
                accordion_header = page.locator('.civicaaccordionheader:has-text("Details")')
                accordion_header.click
                page.wait_for_selector('.civica-keyobject-fulldetails', state: 'visible', timeout: 15_000)

                # Scrape all detail blocks
                details = {}
                page.locator('.civica-keyobject-fulldetails .civicadetail').all.each do |d|
                  label = d.locator('.civicasubheader').text_content.strip rescue nil
                  value = d.locator('.civicadetailtext').text_content.strip rescue nil
                  details[label] = value
                end

                date_valid    = Date.parse(details['Date Valid']) rescue nil
                date_decision = Date.parse(details['Decision Date']) rescue nil
                decision_text = details['Decision']

                docs_count = page.locator('li.civica-doclistitem').count rescue 0

                # --- Build Application object ---
                app = Application.new
                app.authority_name    = authority.name
                app.council_reference = ref_text
                app.date_received     = date_valid
                app.status            = nil
                app.decision          = decision_text
                app.date_decision     = date_decision
                app.info_url          = authority.url
                app.address           = address_text
                app.description       = desc_text
                app.documents_count   = docs_count
                app.documents_url     = authority.url

                if app.valid?
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
                  results << app
                  puts "  → Added application #{app.council_reference}"
                else
                  puts "  ⚠️ Skipped invalid application (#{ref_text})"
                end

                # Back to results
                page.go_back
                page.wait_for_selector('li.civica-keyobjectlistitem', timeout: 10_000)
              end

              # === PAGINATION HANDLING (Ashfield Civica) ===
              begin
                # initialize tracking containers (persist between iterations)
                seen_first_refs ||= []
                page_index ||= 0
                max_pages = 100 # safety cap — adjust if you expect >100 pages

                # Grab current page first-ref and row count (for checks)
                first_ref_elem = page.locator('li.civica-keyobjectlistitem a.civica-gfplanning-internetdesc').first
                current_first_ref = first_ref_elem&.text_content&.strip rescue nil

                row_count = page.locator('li.civica-keyobjectlistitem').count rescue 0
                puts "ℹ️ Current page index #{page_index + 1}, rows: #{row_count}, first_ref: #{current_first_ref.inspect}"

                # Stop if we've seen this first ref already (loop detection)
                if current_first_ref && seen_first_refs.include?(current_first_ref)
                  puts "ℹ️ Detected repeated first application reference (#{current_first_ref}) — stopping pagination."
                  break
                end

                # Record the current first ref for future loop detection
                seen_first_refs << current_first_ref if current_first_ref

                # Defensive — fewer than expected results → likely last page
                if row_count > 0 && row_count < 10
                  puts "ℹ️ Found fewer than 10 results (#{row_count}) — likely last page, stopping pagination."
                  break
                end

                # ── FIXED: Use correct camelCase keyword for playwright-ruby-client ──
                next_btn_locator = page.locator('div.btn.secondary-btn').filter(hasText: 'Next')

                if next_btn_locator.count == 0
                  puts "ℹ️ No 'Next' button found — pagination finished."
                  break
                end

                next_btn = next_btn_locator.first

                # Optional: debug what we actually found
                # puts "Next button text: #{next_btn.inner_text.strip rescue 'N/A'}"

                # Check if disabled
                disabled = next_btn.get_attribute('class')&.include?('disabled-btn') rescue false
                visible  = next_btn.evaluate('el => !!(el && (el.offsetParent !== null))') rescue true

                if disabled || !visible
                  puts "ℹ️ Next button disabled or hidden — reached last page."
                  break
                end

                # Safety cap
                if page_index >= max_pages
                  puts "⚠️ Reached safety pagination cap (#{max_pages}) — stopping."
                  break
                end

                # Click Next and wait for page change
                puts "➡️ Clicking Next page..."
                old_first = current_first_ref

                next_btn.scroll_into_view_if_needed
                page.wait_for_timeout(300)
                next_btn.click(force: true)

                # Wait for content to change (first ref or no rows)
                begin
                  page.wait_for_function(
                    "oldText => {
                      const firstRow = document.querySelector('li.civica-keyobjectlistitem a.civica-gfplanning-internetdesc');
                      if (!firstRow) return true;
                      return firstRow.textContent.trim() !== (oldText || '').trim();
                    }",
                    arg: old_first,
                    timeout: 15_000
                  )
                rescue StandardError
                  # fallback — ignore exact text match failure
                end

                # Make sure results reloaded
                page.wait_for_selector('li.civica-keyobjectlistitem', timeout: 15_000, state: 'visible') rescue nil
                page.wait_for_timeout(600)

                page_index += 1
                puts "✅ Moved to next page (index now #{page_index})."
              rescue => pag_e
                puts "⚠️ Pagination error: #{pag_e.class} - #{pag_e.message}"
                break
              end
              # === END PAGINATION HANDLING ===


            end

            browser.close
          end
        end
      end
      results
    end

    def self.scrape_barnsley(authority, params)
      puts "🔍 Scraping Barnsley (randoms1)"
      results = []
      begin
        Timeout.timeout(900) do 
          agent = Mechanize.new
          page = agent.get(authority.url)
          form = page.forms.first
          raise '❌ Could not find form on Barnsley page' unless form

          # Fill in dates
          from = params[:validated_from] || params[:received_from] || (Date.today - DAYS)
          to   = params[:validated_to]   || params[:received_to]   || Date.today

          from_str = from.strftime('%d/%m/%Y')
          to_str   = to.strftime('%d/%m/%Y')
          form['dateDecisionFrom'] = from_str
          form['dateDecisionTo']   = to_str

          # Submit
          page = form.submit(form.button_with(name: 'submit'))
          base_url = authority.url[/^(https?:\/\/[^\/]+)/, 1]

          loop do
            rows = page.search('#table1 tbody tr')
            puts "Found #{rows.size} apps on this page."

            rows.each do |row|
              ref_link = row.at('td a.bottom')
              next unless ref_link

              council_ref = ref_link.text.strip
              info_url    = URI.join(base_url, ref_link['href']).to_s

              description = row.xpath('./td[2]')&.text&.strip
              address     = row.xpath('./td[3]')&.text&.strip
              received    = row.xpath('./td[4]')&.text&.strip
              date_valid  = (Date.parse(received) rescue nil)
              decision    = row.xpath('./td[5]')&.text&.strip
              status      = row.xpath('./td[6]')&.text&.strip

              # --- Build Application object ---
              app = Application.new
              app.authority_name    = authority.name
              app.council_reference = council_ref
              app.date_received     = date_valid
              app.status            = status
              app.decision          = decision
              app.info_url          = info_url
              app.address           = address
              app.description       = description
              app.documents_count   = 0
              app.documents_url     = nil

              if app.valid?
                results << app
              else
                puts "  ⚠️ Skipped invalid application (#{council_ref})"
              end
            end

            # Pagination
            next_link = page.link_with(text: /Next/i)
            break unless next_link
            page = next_link.click
          end

          # Enrich detail pages
          results.each_with_index do |app, idx|
            begin
              puts "#{idx + 1} of #{results.size}: #{app.info_url}"
              res = agent.get(app.info_url)
              next unless res&.code == '200'

              # Summary table
              res.search('#summaryDetails table tr').each do |tr|
                key   = tr.at('td.col-xs-3')&.text&.strip
                value = tr.at('td.col-xs-9')&.text&.strip
                next unless key && value

                case key
                when /Application Reference Number/i then app.council_reference = value
                when /Description/i                  then app.description       = value
                when /Site Address/i                 then app.address           = value
                when /Decision/i                     then app.decision          = value
                when /Status/i                       then app.status            = value
                end
              end

              # Dates
              res.search('table.table-bordered.table-responsive tr').each do |tr|
                key   = tr.at('td.col-xs-3')&.text&.strip
                value = tr.at('td.col-xs-9')&.text&.strip
                next unless key && value

                case key
                when /Received Date/i  then app.date_received  = (Date.parse(value) rescue nil)
                end
              end

              # Documents
              docs = res.search('#collapseTwo a.right').map { |a| URI.join(base_url, a['href']).to_s }
              if docs.any?
                app.documents_count = docs.size
                app.documents_url   = docs.join(' | ')
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
            rescue => e
              warn "⚠️ Error scraping Barnsley app #{app.info_url}: #{e.class} – #{e.message}"
              next
            end
          end
        end
      end
      results
    end




    def self.scrape_bath_and_north_east_somerset(authority, params)
      puts "🔍 Scraping Bath and North East Somerset (randoms2)"
      results = []
      begin
        Timeout.timeout(4000) do 
          Playwright.create(playwright_cli_executable_path: Playwright::CLI_EXECUTABLE_PATH) do |playwright|
            browser = playwright.chromium.launch(headless: false)
            page = browser.new_page

            # Go to base URL
            page.goto(authority.url)
            page.wait_for_load_state

            # Open advanced search accordion
            page.click('button#accordion-advancedSearch-heading-9')
            page.wait_for_selector('#accordion-DtValidated-From', timeout: 15_000)

            # Fill date range
            from = params[:validated_from] || params[:received_from] || (Date.today - DAYS)
            to   = params[:validated_to]   || params[:received_to]   || Date.today

            page.fill('#accordion-DtValidated-From', from.strftime('%Y-%m-%d'))
            page.fill('#accordion-DtValidated-To', to.strftime('%Y-%m-%d'))

            # Submit
            page.click('#advancedSearchBtn')
            page.wait_for_selector('#results-table tr.govuk-table__row', timeout: 20_000)

            base_url = authority.url[/^(https?:\/\/[^\/]+)/, 1]

            loop do
              rows = page.locator('#results-table tr.govuk-table__row')
              puts "Found #{rows.count} apps on this page."

              rows.all.each do |row|  # .all gives array of locators
                cell = row.locator('td.govuk-table__cell')  # there's only one <td> per <tr>

                # Get the full raw text of the cell (easiest way)
                full_text = cell.inner_text.strip rescue ''

                # Split by lines (each label:value pair is on its own line thanks to <br>)
                lines = full_text.lines.map(&:strip).reject(&:empty?)

                # Parse into a hash for easier access
                data = {}
                lines.each do |line|
                  if line =~ /^(.+?):\s*(.+)$/
                    label = $1.strip
                    value = $2.strip
                    data[label] = value
                  end
                end

                ref_text     = data["Application Reference"]
                address      = data["Application Address"]
                description  = data["Proposal"]
                received_str = data["Application Received"]
                status       = data["Application Status"]

                next unless ref_text&.match?(%r{^\d{2}/\d{5}/[A-Z]+})  # basic ref validation

                # Build info_url from ref (your current way is fine, but cleaner)
                ref_clean = ref_text.gsub('/', '%2F')  # already URL-encoded in href usually
                raw_href = "./details.html?refval=#{ref_clean}"
                info_url = "#{base_url}/webforms/planning#{raw_href.sub('./', '/')}"

                date_received = begin
                  Date.parse(received_str) if received_str
                rescue
                  nil
                end

                app = Application.new
                app.authority_name    = authority.name
                app.council_reference = ref_text
                app.date_received     = date_received
                app.info_url          = info_url
                app.address           = address
                app.description       = description
                if app.valid?
                  results << app
                  puts "  → Added application #{app.council_reference}"
                else
                  puts "  ⚠️ Skipped invalid application (#{ref_text || 'no ref'})"
                  puts "     Fields: addr=#{address&.inspect}, desc=#{description&.inspect}, date=#{date_received}"
                end
              end

              # Pagination
              if page.locator('a:has-text("Next")').count > 0
                page.click('a:has-text("Next")')
                page.wait_for_selector('#results-table tr.govuk-table__row', timeout: 20_000)
              else
                break
              end
            end

            # === Enrich detail pages ===
            results.each_with_index do |app, idx|
              begin
                puts "#{idx + 1} of #{results.size}: #{app.info_url}"
                detail_page = browser.new_page
                detail_page.goto(app.info_url)
                detail_page.wait_for_load_state

                # Details tab (default)
                details = detail_page.locator('#details')
                if details.count > 0
                  # Use exact header match to avoid confusion with "Address of Proposal"
                  app.address     = details.locator('p:has-text("Address of Proposal") + p').nth(0).text_content.strip rescue app.address
                  app.description = details.locator('p:has-text("Proposal"):not(:has-text("Address")) + p').nth(0).text_content.strip rescue app.description
                  puts "   ✔ Details scraped"
                else
                  puts "   ⚠️ No details found"
                end

                # Important Dates tab
                if detail_page.locator('a[href="#importantDates_Section"]').count > 0
                  detail_page.click('a[href="#importantDates_Section"]')
                  detail_page.wait_for_selector('#importantDates_Section', timeout: 10_000)

                  dates = detail_page.locator('#importantDates_Section')
                  app.date_received  = (Date.parse(dates.locator('p:below(:text("Application Received"))').nth(0).text_content.strip) rescue nil)
                  puts "   ✔ Dates scraped"
                else
                  puts "   ⚠️ Important Dates tab not found"
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
                detail_page.close
              rescue => e
                warn "⚠️ Error scraping Bath detail #{app.info_url}: #{e.class} – #{e.message}"
                next
              end
            end


            browser.close
          end
        end
      end
      results
    end


    def self.scrape_boston(authority, params)
      puts "🔍 Scraping Boston (randoms1)"
      results = []
      from = params[:validated_from] || params[:received_from] || (Date.today - DAYS)
      to   = params[:validated_to]   || params[:received_to]   || Date.today
      puts Playwright.methods.sort
      begin
        Timeout.timeout(900) do 
          Playwright.create(playwright_cli_executable_path: Playwright::CLI_EXECUTABLE_PATH) do |playwright|
            browser = playwright.chromium.launch(headless: false)
            page = browser.new_page

            # Go to base search URL
            page.goto(authority.url)
            page.wait_for_load_state

            # Optional: sometimes need to press Search/Next to show results
            begin
              if page.locator('#PLANNINGAPPLICATIONSEARCHV3_SEARCH_SEARCHBUTTON_NEXT').count > 0
                page.click('#PLANNINGAPPLICATIONSEARCHV3_SEARCH_SEARCHBUTTON_NEXT', timeout: 5_000)
              end
            rescue => _
              # Ignore — some pages show results immediately
            end

            # Wait for results table
            page.wait_for_selector('table.icmformdata__table tbody tr', timeout: 15_000)

            rows = page.locator('table.icmformdata__table tbody tr')
            rows.count.times do |i|
              row = rows.nth(i)

              # Skip headers (contain th)
              next if row.locator('th').count > 0

              cells = row.locator('td')
              next unless cells.count >= 6

              received_text = cells.nth(5).text_content&.strip
              received_date = begin
                Date.strptime(received_text, '%d/%m/%Y') rescue Date.parse(received_text) rescue nil
              end

              # Stop if we've reached older applications
              if received_date && received_date < from
                puts "  → Reached older apps (#{received_date}) — stopping."
                break
              end

              ref_text     = cells.nth(0).text_content&.strip
              desc_text    = cells.nth(1).text_content&.strip
              address_text = cells.nth(2).text_content&.strip

              # Try to find the details button
              details_button = cells.nth(6).locator('button, input[type="submit"], a')
              if details_button.count == 0
                details_button = row.locator('button, input[type="submit"], a')
              end

              begin
                details_button.first.click
              rescue => e
                warn "  ⚠️ Could not click details button for #{ref_text}: #{e.class} – #{e.message}"
                next
              end

              # Wait for details area
              begin
                page.wait_for_selector('#PLANNINGAPPLICATIONSEARCHV3_DETAILS_DETAILSDISPLAY, #PLANNINGAPPLICATIONSEARCHV3_DETAILS_DOCUMENTSDISPLAY', timeout: 10_000)
              rescue
                page.wait_for_timeout(500)
              end

              # Scrape details
              details_hash = {}
              if page.locator('#PLANNINGAPPLICATIONSEARCHV3_DETAILS_DETAILSDISPLAY').count > 0
                det_rows = page.locator('#PLANNINGAPPLICATIONSEARCHV3_DETAILS_DETAILSDISPLAY table[summary="Application Details"] tr')
                det_rows.count.times do |j|
                  th = det_rows.nth(j).locator('th').text_content&.strip rescue nil
                  td = det_rows.nth(j).locator('td').text_content&.strip rescue nil
                  details_hash[th] = td if th
                end
              end

              # Count documents
              docs_count = 0
              if page.locator('#PLANNINGAPPLICATIONSEARCHV3_DETAILS_DOCUMENTSDISPLAY').count > 0
                trows = page.locator('#PLANNINGAPPLICATIONSEARCHV3_DETAILS_DOCUMENTSDISPLAY table[summary="Application Documents"] tbody tr')
                if trows.count > 0 && trows.nth(0).locator('th').count > 0
                  docs_count = trows.count - 1
                else
                  docs_count = trows.count
                end
              end

              # Normalise fields
              council_reference = details_hash['Reference'] || ref_text
              received_from_details = details_hash['Received'] || details_hash['Application Received'] || received_text
              date_received_parsed = begin
                Date.strptime(received_from_details, '%d/%m/%Y') rescue Date.parse(received_from_details) rescue nil
              end

              status_text   = details_hash['Decision'] || details_hash['Status'] || nil
              decision_text = details_hash['Decision'] || nil

              # --- Build Application object ---
              app = UKPlanningScraper::Application.new
              app.authority_name    = authority.name
              app.council_reference = council_reference
              app.date_received     = date_received_parsed
              app.status            = status_text
              app.decision          = decision_text
              app.info_url          = authority.url
              app.address           = address_text
              app.description       = desc_text
              app.documents_count   = docs_count
              app.documents_url     = authority.url

              # --- Validate & store ---
              if app.valid?
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
                results << app
                puts "  → Added application #{app.council_reference}"
              else
                puts "  ⚠️ Skipped invalid application (#{app.council_reference || ref_text})"
              end

              # Return to results
              begin
                page.click('#PLANNINGAPPLICATIONSEARCHV3_DETAILS_APPLICATIONBACK_BACK')
                page.wait_for_selector('table.icmformdata__table tbody tr', timeout: 15_000)
              rescue => e
                warn "  ⚠️ Could not click back link: #{e.class} – #{e.message}, reloading"
                page.goto(authority.url)
                page.wait_for_selector('table.icmformdata__table tbody tr', timeout: 15_000)
              end
            end

            browser.close
          end
        end
      end
      results
    end
    def self.scrape_bridgend(authority, params)
      puts "🔍 Scraping Bridgend (randoms1)"

      results = []
      begin
        Timeout.timeout(900) do 
          Playwright.create(playwright_cli_executable_path: Playwright::CLI_EXECUTABLE_PATH) do |playwright|
            browser = playwright.chromium.launch(headless: false)
            page = browser.new_page

            # Go to base URL
            page.goto(authority.url)
            page.wait_for_load_state

            # ✅ Handle disclaimer if present
            if page.locator('input[value="Agree"]').count > 0
              page.click('input[value="Agree"]')
              page.wait_for_load_state
            end

            # Format dates as dd/mm/yyyy
            from = params[:validated_from] || params[:received_from] || (Date.today - DAYS)
            to   = params[:validated_to]   || params[:received_to]   || Date.today

            from_str = from.strftime('%d/%m/%Y')
            to_str   = to.strftime('%d/%m/%Y')

            # ✅ Fill in date fields by name (more stable than ASP.NET IDs)
            page.fill('input[name="DateIssuedFrom"]', from_str) if page.locator('input[name="DateIssuedFrom"]').count > 0
            page.fill('input[name="DateIssuedTo"]',   to_str)   if page.locator('input[name="DateIssuedTo"]').count > 0

            # Click search
            page.click('input#searchButton')
            page.wait_for_selector('table tbody tr', timeout: 15_000)

            # tiny helper that returns text or nil safely
            get_text = ->(selector) do
              loc = page.locator(selector)
              loc.count > 0 ? loc.nth(0).text_content&.strip : nil
            end

            # Iterate rows
            rows = page.locator('table tbody tr')
            rows.count.times do |i|
              row = rows.nth(i)

              ref_link = row.locator('a.hyperlink')
              next unless ref_link.count > 0

              # Click ref to open detail page
              ref_text = ref_link.text_content&.strip
              ref_link.click
              page.wait_for_load_state

              # Extract details
              address_text   = get_text.call('dt:has-text("Application Location") + dd')
              desc_text      = get_text.call('dt:has-text("Proposal") + dd')
              status_text    = get_text.call('dt:has-text("Status") + dd')
              decision_text  = get_text.call('dt:has-text("Decision") + dd')

              # Dates
              received_date  = UKPlanningScraper::Utils.parse_date(get_text.call('dt:has-text("Received") + dd'))

              # Documents
              docs_count = 0
              if page.locator('#documents table.document-list tr.row_link').count > 0
                docs_count = page.locator('#documents table.document-list tr.row_link').count
              end

              # --- Build Application object ---
              app = Application.new
              app.authority_name    = authority.name
              app.council_reference = ref_text
              app.date_received     = received_date
              app.status            = status_text
              app.decision          = decision_text
              app.info_url          = authority.url
              app.address           = address_text
              app.description       = desc_text
              app.documents_count   = docs_count
              app.documents_url     = authority.url

              # --- Validate and store ---
              if app.valid?
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
                results << app
                puts "  → Added application #{app.council_reference}"
              else
                puts "  ⚠️ Skipped invalid application (#{app.council_reference || ref_text})"
              end

              # ✅ Go back to results page
              if page.locator('a#PLANNINGAPPLICATIONSEARCHV3_DETAILS_APPLICATIONBACK_BACK').count > 0
                page.click('a#PLANNINGAPPLICATIONSEARCHV3_DETAILS_APPLICATIONBACK_BACK')
                page.wait_for_selector('table tbody tr', timeout: 15_000)
              else
                # fallback: browser back
                page.go_back
                page.wait_for_selector('table tbody tr', timeout: 15_000)
              end

              page.wait_for_timeout(250)
            end

            browser.close
          end
        end
      end
      results
    end

    def self.scrape_camden(authority, params)
      puts "🔍 Scraping Camden (randoms1)"
      results = []

      base_url = authority.url[/^(https?:\/\/[^\/]+)/, 1]
      begin
        Timeout.timeout(900) do 
          Playwright.create(playwright_cli_executable_path: Playwright::CLI_EXECUTABLE_PATH) do |playwright|
            browser = playwright.chromium.launch(headless: false)
            context = browser.new_context
            page = context.new_page

            begin
              # Load search page
              page.goto(authority.url)
              page.wait_for_load_state
              from = params[:validated_from] || params[:received_from] || (Date.today - DAYS)
              to   = params[:validated_to]   || params[:received_to]   || Date.today

              # Fill date fields
              begin
                page.fill('#dateStart', from_str)
                page.evaluate("document.querySelector('#dateStart')?.dispatchEvent(new Event('change', {bubbles:true}))")
              rescue
                page.evaluate("document.querySelector('#dateStart').value = #{from_str.inspect}; document.querySelector('#dateStart').dispatchEvent(new Event('change', {bubbles:true}))")
              end

              begin
                page.fill('#dateEnd', to_str)
                page.evaluate("document.querySelector('#dateEnd')?.dispatchEvent(new Event('change', {bubbles:true}))")
              rescue
                page.evaluate("document.querySelector('#dateEnd').value = #{to_str.inspect}; document.querySelector('#dateEnd').dispatchEvent(new Event('change', {bubbles:true}))")
              end

              # Submit search
              page.click('#csbtnSearch')
              begin
                page.wait_for_selector('table.display_table tbody tr', timeout: 15_000)
              rescue
              end

              # Helper to parse <ul class="list"> style blocks into a hash
              parse_ul_list = lambda do |p, selector|
                map = {}
                begin
                  items = p.locator("#{selector} li")
                  (0...items.count).each do |ii|
                    li = items.nth(ii)
                    label = (li.locator('span').first.text_content rescue nil)
                    full  = (li.locator('div').first.text_content rescue nil) || (li.text_content rescue nil)
                    next if label.nil? || full.nil?
                    value = full.sub(label, '').gsub("\u00A0", ' ').strip
                    map[label.strip] = value
                  end
                rescue
                end
                map
              end

              loop do
                page.wait_for_selector('table.display_table tbody tr', timeout: 8_000) rescue nil
                rows = page.locator('table.display_table tbody tr')
                total_rows = rows.count
                puts "Found #{total_rows} table rows (including header)."

                (0...total_rows).each do |ri|
                  begin
                    row = rows.nth(ri)
                    next if row.locator('th').count > 0

                    link_loc = row.locator('td a.data_text').first
                    next unless link_loc && link_loc.count > 0

                    href = link_loc.evaluate('el => el.href') rescue nil
                    ref_text = (link_loc.text_content || '').strip
                    puts "  → Opening #{ref_text} (#{href})"

                    detail_page = context.new_page
                    begin
                      detail_page.goto(href)
                      detail_page.wait_for_load_state
                    rescue => e
                      warn "    ⚠️ Failed to load detail page for #{ref_text}: #{e.message}"
                      detail_page.close rescue nil
                      next
                    end

                    summary = parse_ul_list.call(detail_page, 'ul.list')

                    app = Application.new
                    app.authority_name    = authority.name
                    app.info_url          = href
                    app.council_reference = summary['Application Number'] || ref_text
                    app.address           = summary['Site Address'] unless summary['Site Address'].to_s.empty?
                    app.description       = summary['Proposal'] || summary['Development Description']
                    app.status            = summary['Current Status'] || summary['Status'] || row.locator('td:nth-child(4)').text_content&.strip
                    app.decision          = summary['Decision']
                    app.date_received     = nil
                    app.documents_count   = 0
                    app.documents_url     = nil

                    # Decision block
                    begin
                      decision_div = detail_page.locator('xpath=//div[span[normalize-space(text())="Decision"]]')
                      if decision_div.count > 0
                        dtxt = decision_div.first.text_content.gsub(/^\s*Decision\s*/i, '').gsub("\u00A0", ' ').strip rescue nil
                        app.decision = dtxt unless dtxt.nil? || dtxt.empty?
                      end
                    rescue
                    end

                    # Dates page
                    begin
                      dates_link = detail_page.locator('a:has-text("Application Dates")')
                      if dates_link.count > 0
                        dates_href = dates_link.first.evaluate('el => el.href') rescue nil
                        if dates_href
                          dates_page = context.new_page
                          begin
                            dates_page.goto(dates_href)
                            dates_page.wait_for_load_state
                            dates_map = parse_ul_list.call(dates_page, 'ul.list')
                            app.date_received  ||= (Date.parse(dates_map['Received']) rescue nil)
                          rescue => e
                            warn "    ⚠️ Dates page parse failed for #{ref_text}: #{e.class} - #{e.message}"
                          ensure
                            dates_page.close rescue nil
                          end
                        end
                      end
                    rescue
                    end

                    # --- Documents page ---
                    begin
                      docs_anchor = detail_page.locator('a:has-text("View Related Documents"), a:has-text("View drawings")')
                      if docs_anchor.count > 0
                        docs_href = docs_anchor.first.evaluate('el => el.href') rescue nil
                        if docs_href && !docs_href.empty?
                          docs_page = context.new_page
                          begin
                            docs_page.goto(docs_href)
                            docs_page.wait_for_load_state

                            # Wait for document rows
                            begin
                              docs_page.wait_for_selector('table#recordtable tbody tr', timeout: 10_000)
                            rescue
                            end

                            doc_rows = docs_page.locator('table#recordtable tbody tr')
                            doc_count = doc_rows.count

                            if doc_count > 0
                              app.documents_count = doc_count
                              app.documents_url   = docs_href
                              puts "    ✔ Found #{doc_count} documents."
                            else
                              puts "    ⚠️ No documents found."
                            end
                          rescue => e
                            warn "    ⚠️ Documents page load failed for #{ref_text}: #{e.message}"
                          ensure
                            docs_page.close rescue nil
                          end
                        end
                      end
                    rescue => e
                      warn "    ⚠️ Document scraping error for #{ref_text}: #{e.message}"
                    end

                    # === Validate and store ===
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

                    detail_page.close rescue nil
                  rescue => app_e
                    warn "⚠️ Error scraping Camden row ##{ri + 1}: #{app_e.class} - #{app_e.message}"
                    next
                  end
                end

                # Pagination
                begin
                  next_btn = page.locator('a.noborder:has(img[alt="Go to next page"]), a.noborder:has(img[title="Go to next page"])').first
                  if next_btn && next_btn.count > 0
                    next_href = next_btn.evaluate('el => el.href') rescue nil
                    if next_href && !next_href.empty?
                      puts "➡️ Navigating to next results page: #{next_href}"
                      page.goto(next_href)
                      page.wait_for_load_state
                      page.wait_for_selector('table.display_table tbody tr', timeout: 8_000) rescue nil
                      next
                    end
                  end
                rescue
                end

                break
              end

            rescue => e
              warn "❌ Error scraping Camden: #{e.class} - #{e.message}"
            ensure
              browser.close rescue nil
            end
          end
        end
      end
      results
    end
    def self.scrape_carmarthenshire(authority, params)
      puts "🔍 Scraping Carmarthenshire"

      results = []
      begin
        Timeout.timeout(900) do 
          Playwright.create(playwright_cli_executable_path: Playwright::CLI_EXECUTABLE_PATH) do |playwright|
            browser = playwright.chromium.launch(headless: false)
            page = browser.new_page

            page.goto(authority.url)
            page.wait_for_load_state
            sleep 2
            from = params[:validated_from] || params[:received_from] || (Date.today - DAYS)
            to   = params[:validated_to]   || params[:received_to]   || Date.today

            from_str = from.strftime('%d/%m/%Y')
            to_str   = to.strftime('%d/%m/%Y')

            # --- Minimal fill: Registration Date From (4th .slds-input.input) ---
            begin
              from_str = from.strftime('%d/%m/%Y')
              puts "   ℹ️ Filling Registration Date From with #{from_str}"

              # Locate the 4th .slds-input.input field (index 3)
              from_input = page.locator('input.slds-input.input').nth(3)
              raise "Registration Date From input not found" if from_input.nil?

              # Click and type the date
              from_input.click
              from_input.fill('')
              from_input.type(from_str)
              page.wait_for_timeout(150)

              # Commit the value via JS and blur event
              from_input.evaluate(<<~JS, from_str)
                (el, v) => {
                  const desc = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value');
                  if (desc && desc.set) desc.set.call(el, v); else el.value = v;
                  el.dispatchEvent(new Event('input', { bubbles: true }));
                  el.dispatchEvent(new Event('change', { bubbles: true }));
                  el.blur();
                }
              JS

              # Optional: click calendar button to ensure commit (if present)
              cal_btn = from_input.locator('xpath=following::button[1]').first rescue nil
              cal_btn.click rescue nil if cal_btn && cal_btn.count > 0

              puts "   ✔ Filled Registration Date From: #{from_str}"
            rescue => e
              puts "   ⚠️ Could not fill Registration Date From: #{e.class} - #{e.message}"
            end

            # --- Click Search ---
            begin
              page.get_by_role('button', name: /Search/i).click
            rescue
              page.locator('button.slds-button_brand', has_text: /Search/i).click(force: true)
            end

            # --- Wait for results ---
            begin
              page.wait_for_selector('#PApplication .slds-tile.cPR_Article', timeout: 20_000)
            rescue => e
              puts "   ⚠️ Results did not appear or took too long: #{e.message}"
              # return early with whatever we have
              browser.close rescue nil
              return results
            end

            rows = page.locator('#PApplication .slds-tile.cPR_Article h4 a.uiOutputURL')

            rows.count.times do |i|
              row = rows.nth(i)
              ref_text = row.text_content&.strip
              next if ref_text.nil? || ref_text.empty?

              row.click
              page.wait_for_load_state
              page.wait_for_timeout(500)

              begin
                # Extract fields robustly from Arcus detail page
                ref_val = page.locator('div[data-target-selection-name*="Planning_Application__c.Name"] lightning-formatted-text').first&.text_content&.strip rescue nil

                address_text = page.locator('div[data-target-selection-name*="Site_Address__c"] lightning-formatted-text').first&.text_content&.strip rescue nil
                desc_text    = page.locator('div[data-target-selection-name*="Proposal__c"] lightning-formatted-text').first&.text_content&.strip rescue nil
                date_text    = page.locator('div[data-target-selection-name*="Received_Date__c"] lightning-formatted-text').first&.text_content&.strip rescue nil

                date_received = Date.strptime(date_text, '%d/%m/%Y') rescue nil


                app = Application.new
                app.authority_name    = authority.name
                app.council_reference = ref_val
                app.date_received     = date_received
                app.decision          = nil
                app.info_url          = page.url
                app.address           = address_text
                app.description       = desc_text

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
                  puts "   → Added application #{app.council_reference}"
                else
                  puts "   ⚠️ Skipped invalid record (#{ref_text})"
                end
              rescue => e
                puts "   ⚠️ Error scraping detail: #{e.message}"
              ensure
                page.go_back
                page.wait_for_selector('#PApplication .slds-tile.cPR_Article', timeout: 10_000)
                page.wait_for_timeout(250)
              end
            end

            browser.close
          end
        end
      end
      results
    end

    def self.scrape_central_bedfordshire(authority, params)
      puts "🔍 Scraping Central Bedfordshire"
      results = []

      require 'uri'
      require 'cgi'
      begin
        Timeout.timeout(2000) do 
          Playwright.create(playwright_cli_executable_path: Playwright::CLI_EXECUTABLE_PATH) do |playwright|
            browser = playwright.chromium.launch(headless: false)
            page = browser.new_page

            # Go to base URL
            page.goto(authority.url)
            page.wait_for_load_state

            # Accept cookies if button exists
            if page.locator('#CybotCookiebotDialogBodyLevelButtonLevelOptinAllowAll').count > 0
              page.click('#CybotCookiebotDialogBodyLevelButtonLevelOptinAllowAll')
            end

            # Fill in date range
            from = params[:validated_from] || params[:received_from] || (Date.today - DAYS)
            to   = params[:validated_to]   || params[:received_to]   || Date.today

            from_str = from.strftime('%d/%m/%Y')
            to_str   = to.strftime('%d/%m/%Y')
            page.fill('input[name="regdate1"]', from_str)
            page.fill('input[name="regdate2"]', to_str)

            # Submit form
            page.click('input[type="submit"][value="Search"]')
            page.wait_for_selector('table.results-table tbody tr')

            loop do
              rows = page.locator('table.results-table tbody tr')
              row_count = rows.count

              (0...row_count).each do |i|
                begin
                  row = rows.nth(i)
                  ref_link = row.locator('td.casenumber a')
                  next unless ref_link.count > 0

                  # Build absolute detail URL
                  href_raw = ref_link.get_attribute('href')
                  href = URI.join(authority.url, href_raw).to_s

                  # Navigate into detail page in same tab
                  page.goto(href)
                  page.wait_for_selector('table#details-table')

                  details_table = page.locator('table#details-table')

                  # === Helpers ===
                  clean_text = lambda do |label|
                    begin
                      locator = details_table.locator(%Q[xpath=.//tr[normalize-space(th)='#{label}']/td])
                      raw = locator.text_content
                      return nil if raw.nil?
                      s = raw.gsub("\u00A0", ' ').gsub(/\s+/, ' ').strip
                      s.empty? ? nil : s
                    rescue
                      nil
                    end
                  end

                  extract_date = lambda do |label|
                    raw = clean_text.call(label)
                    return nil if raw.nil?
                    m = raw.match(/(\d{1,2})\D+(\d{1,2})\D+(\d{2,4})/)
                    if m
                      day = m[1].rjust(2, '0')
                      mon = m[2].rjust(2, '0')
                      year = m[3]
                      UKPlanningScraper::Utils.parse_date("#{day}/#{mon}/#{year}")
                    else
                      UKPlanningScraper::Utils.parse_date(raw) rescue nil
                    end
                  end

                  # Get a stable reference
                  ref_labels = [
                    'Application Reference:',
                    'Reference:',
                    'Case Number:',
                    'Application No:',
                    'Application Ref:',
                    'Application Number:'
                  ]
                  council_ref = nil
                  ref_labels.each do |lbl|
                    council_ref = clean_text.call(lbl)
                    break if council_ref
                  end
                  if council_ref.nil?
                    q = URI.parse(href).query.to_s
                    params = CGI.parse(q)
                    council_ref = params['TheSystemkey']&.first
                  end
                  council_ref ||= href

                  # === Build Application ===
                  app = Application.new
                  app.authority_name    = authority.name
                  app.council_reference = council_ref
                  app.date_received     = extract_date.call('Date Received:')
                  app.status            = (clean_text.call('Status:') rescue nil)
                  app.decision          = (clean_text.call('Decision:') rescue nil)
                  app.info_url          = href
                  app.address           = (clean_text.call('Location:') rescue nil)
                  app.description       = (clean_text.call('Description:') rescue nil)
                  app.documents_count   = ((details_table.locator(%Q[xpath=.//tr[normalize-space(th)='Conditions or Reasons:']/td//a]).count > 0 ? 1 : 0) rescue 0)
                  app.documents_url     = (details_table.locator(%Q[xpath=.//tr[normalize-space(th)='Conditions or Reasons:']/td//a]).get_attribute('href') rescue nil)

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
                    puts "  ⚠️ Skipped invalid record (#{app.council_reference})"
                  end

                  # Back to search results
                  page.go_back
                  page.wait_for_selector('table.results-table tbody tr')

                rescue => e
                  puts "❌ Error scraping Central Bedfordshire row: #{e.class} - #{e.message}"
                  # Try to return to results page if stuck
                  begin
                    page.go_back
                    page.wait_for_selector('table.results-table tbody tr')
                  rescue
                  end
                end
              end


              # Next page (no has_text:, use XPath instead)
              next_btn = page.locator("//a[normalize-space(text())='Next']")
              break unless next_btn.count > 0 && !next_btn.get_attribute('class').to_s.include?('disabled')
              next_btn.click
              page.wait_for_selector('table.results-table tbody tr')
            end

            browser.close
          end
        end
      end
      results
    end

    def self.scrape_colchester(authority, params)
      puts "🔍 Scraping Colchester"
      results = []
      begin
        Timeout.timeout(900) do 
          Playwright.create(playwright_cli_executable_path: Playwright::CLI_EXECUTABLE_PATH) do |playwright|
            browser = playwright.chromium.launch(headless: false)
            page = browser.new_page

            # ensure we have a 'from' date to compare against
            from = params[:validated_from] || params[:received_from] || (Date.today - DAYS)
            to   = params[:validated_to]   || params[:received_to]   || Date.today

            from_str = from.strftime('%d/%m/%Y')
            to_str   = to.strftime('%d/%m/%Y')

            # Go straight to Colchester base URL (already lists applications)
            page.goto(authority.url)
            page.wait_for_selector('tbody tr')
            page.wait_for_load_state
            stop_pagination = false

            loop do
              rows = page.locator('tbody tr')
              break if rows.count == 0

              rows.count.times do |i|
                row = rows.nth(i)

                # --- READ registered date from the results row (do NOT open detail if out of range) ---
                # Try to read a <time datetime="YYYY-MM-DD"> or fallback to the cell's aria-label/text
                reg_date = nil
                begin
                  time_el = row.locator('td[data-attribute="new_registration_date"] time').first rescue nil
                  if time_el && time_el.count > 0
                    dt = (time_el.get_attribute('datetime') rescue nil)
                    reg_date = Date.parse(dt) rescue nil if dt && !dt.to_s.empty?
                  end
                rescue
                  reg_date = nil
                end

                # fallback: aria-label on the td e.g. aria-label="17/10/2025"
                if reg_date.nil?
                  begin
                    aria = row.locator('td[data-attribute="new_registration_date"]').first.get_attribute('aria-label') rescue nil
                    if aria && aria.match(/\d{2}\/\d{2}\/\d{4}/)
                      reg_date = Date.strptime(aria, '%d/%m/%Y') rescue nil
                    else
                      # maybe inner text contains a date
                      txt = row.locator('td[data-attribute="new_registration_date"]').first.text_content rescue nil
                      reg_date = Date.parse(txt) rescue nil if txt && txt.match(/\d{4}/)
                    end
                  rescue
                    reg_date = nil
                  end
                end

                # If we have a registration date and it is before the requested `from`, stop everything immediately
                if reg_date && reg_date < from
                  puts "ℹ️ Encountered record with registration date #{reg_date} which is earlier than from=#{from} — stopping scrape."
                  stop_pagination = true
                  break
                end

                # --- proceed only if still in-range ---
                ref_link = row.locator('td[data-attribute="new_name"] a')
                next unless ref_link.count > 0

                href = ref_link.get_attribute('href')
                href = URI.join(authority.url, href).to_s

                # Open detail page
                detail_page = browser.new_page
                detail_page.goto(href)
                detail_page.wait_for_selector('form')

                # === Extract fields from detail page ===
                date_received = parse_date(
                  (detail_page.locator('#new_date_received_datepicker_description').get_attribute('value') rescue nil) ||
                  (detail_page.locator('#new_date_received_datepicker_description').text_content rescue nil)
                )

                # === Build Application ===
                app = Application.new
                app.authority_name    = authority.name
                app.council_reference = (ref_link.text_content.strip rescue nil)
                app.date_received     = date_received
                app.status            = (row.locator('td[data-attribute="new_application_status"]').text_content.strip rescue nil)
                app.decision          = nil
                app.info_url          = href
                app.address           = (row.locator('td[data-attribute="new_concatenatedaddress"]').text_content.strip rescue nil)
                app.description       = (row.locator('td[data-attribute="new_development_desc"]').text_content.strip rescue nil)
                app.documents_count   = 0
                app.documents_url     = nil


                # === Scrape documents ===
                if detail_page.locator('#wam-doc').count > 0
                  docs_link = detail_page.locator('#wam-doc').get_attribute('href') rescue nil
                  if docs_link
                    docs_url = URI.join(authority.url, docs_link).to_s

                    docs_page = browser.new_page
                    docs_page.goto(docs_url)
                    begin
                      docs_page.wait_for_selector('select[name="documents_length"], table#documents tbody tr', timeout: 5_000)
                    rescue
                    end

                    # Select 50 per page if available
                    begin
                      if docs_page.locator('select[name="documents_length"]').count > 0
                        docs_page.select_option('select[name="documents_length"]', value: '50')
                        docs_page.wait_for_timeout(800)
                      end
                    rescue
                    end

                    # Count docs robustly
                    begin
                      if docs_page.locator('table#documents tbody tr').count > 0
                        app.documents_count = docs_page.locator('table#documents tbody tr').count
                      else
                        app.documents_count = docs_page.locator('a').count
                      end
                    rescue
                    end

                    app.documents_url = docs_url
                    docs_page.close
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
                  puts "  ⚠️ Skipped invalid record (#{app.council_reference})"
                end

                detail_page.close
              end

              # If we hit an out-of-range date inside the rows loop, stop everything immediately
              break if stop_pagination

              # --- PAGINATION ---
              begin
                # --- Accept cookies if present ---
                begin
                  if page.locator('#ccc-notify-accept').count > 0
                    puts "🍪 Accepting cookies..."
                    page.click('#ccc-notify-accept')
                    page.wait_for_timeout(500)
                    puts "✅ Cookies accepted."
                  else
                    puts "🍪 No cookie banner present."
                  end
                rescue => cookie_err
                  puts "⚠️ Cookie acceptance failed: #{cookie_err.class} - #{cookie_err.message}"
                end

                pagination = page.locator('ul.pagination')
                break if pagination.count == 0

                active_anchor = nil
                if pagination.locator('li.active a[data-page]').count > 0
                  active_anchor = pagination.locator('li.active a[data-page]').first
                elsif pagination.locator('a[aria-current="page"]').count > 0
                  active_anchor = pagination.locator('a[aria-current="page"]').first
                else
                  active_anchor = pagination.locator('li.active a').first rescue nil
                end

                current_page = (active_anchor && active_anchor.get_attribute('data-page') ? active_anchor.get_attribute('data-page').to_i : 1) rescue 1
                next_page_num = current_page + 1

                next_anchor = pagination.locator("a[data-page='#{next_page_num}']").first
                if next_anchor.count == 0
                  next_anchor = pagination.locator('a.entity-pager-next-link, a[aria-label="Next page"], a[aria-label*="Next"]').first
                end
                break if next_anchor.count == 0

                disabled_attr = (next_anchor.get_attribute('aria-disabled') rescue nil)
                disabled_class = (next_anchor.get_attribute('class') rescue nil)
                if (disabled_attr && ['true', 'disabled'].include?(disabled_attr.to_s.downcase)) ||
                  (disabled_class && disabled_class.to_s.downcase.include?('disabled'))
                  puts "ℹ️ Reached last page — pagination ended."
                  break
                end

                first_selector = 'tbody tr td[data-attribute="new_name"] a'
                first_selector_alt = 'table.display_table tbody tr td a.data_text'
                prev_first_href = nil
                if page.locator(first_selector).count > 0
                  prev_first_href = page.locator(first_selector).first.get_attribute('href') rescue nil
                elsif page.locator(first_selector_alt).count > 0
                  prev_first_href = page.locator(first_selector_alt).first.get_attribute('href') rescue nil
                end
                prev_count = page.locator('tbody tr').count

                puts "➡️ Clicking Next (page #{next_page_num})..."
                begin
                  next_anchor.click
                rescue
                  page.evaluate(%Q{
                    () => {
                      const el = document.querySelector("ul.pagination a[data-page='#{next_page_num}']");
                      if (el) { el.click(); return true }
                      const el2 = document.querySelector('ul.pagination a.entity-pager-next-link');
                      if (el2) { el2.click(); return true }
                      return false
                    }
                  }) rescue nil
                end

                begin
                  if prev_first_href
                    page.wait_for_function(%Q{
                      () => {
                        const sel = document.querySelector("#{first_selector}");
                        if (!sel) return true;
                        return sel.href !== #{prev_first_href.inspect};
                      }
                    }, timeout: 10_000)
                  else
                    page.wait_for_function("() => document.querySelectorAll('tbody tr').length !== #{prev_count}", timeout: 10_000)
                  end
                rescue
                  page.wait_for_timeout(1200)
                end

                begin
                  page.wait_for_selector('tbody tr', timeout: 8_000)
                rescue
                end
              rescue => pag_e
                warn "⚠️ Pagination step failed: #{pag_e.class} - #{pag_e.message}; stopping pagination."
                break
              end

            end

            browser.close
          end
        end
      end
      results
    end
    def self.scrape_copeland(authority, params)
      puts "🔍 Scraping Copeland (randoms1)"
      results = []

      # --- Normalize dates ---
      today = Date.today
      from_date = if params[:received_from]
                    Date.parse(params[:received_from])
                  else
                    today - DAYS
                  end
      to_date   = if params[:received_to]
                    Date.parse(params[:received_to])
                  else
                    today
                  end
      begin
        Timeout.timeout(900) do 
          Playwright.create(playwright_cli_executable_path: Playwright::CLI_EXECUTABLE_PATH) do |playwright|
            browser = playwright.chromium.launch(headless: false) # headful for debugging
            page = browser.new_page

            # Go to base URL
            page.goto(authority.url)
            page.wait_for_load_state

            # Accept cookies if present
            if page.locator('button#ccc-recommended-settings').count > 0
              page.click('button#ccc-recommended-settings')
              page.wait_for_timeout(500)
            end

            loop do
              # Wait for table rows
              page.wait_for_selector("table.views-table tbody tr", timeout: 10_000)

              rows = page.locator("table.views-table tbody tr")
              row_count = rows.count
              puts "  → Found #{row_count} rows"

              row_count.times do |i|
                row = rows.nth(i)

                ref_link = row.locator("td.views-field-title a")
                next unless ref_link.count > 0

                valid_date_str = row.locator("td.views-field-field-plan-app-date-received span")&.text_content&.strip
                valid_date     = UKPlanningScraper::Utils.parse_date(valid_date_str)

                # stop scraping once outside date range
                if valid_date && valid_date < from_date
                  puts "  ⏹ Reached out-of-range date (#{valid_date}), stopping."
                  browser.close
                  return results
                end

                href = ref_link.get_attribute("href")
                # Fix relative URL → absolute
                if href && href.start_with?('/')
                  href = URI.join(authority.url, href).to_s
                end

                # Open detail page in a new tab
                detail_page = browser.new_page
                detail_page.goto(href)
                detail_page.wait_for_load_state
                if detail_page.locator('button#ccc-recommended-settings').count > 0
                  detail_page.click('button#ccc-recommended-settings')
                  detail_page.wait_for_timeout(500)
                end

                # --- Build Application object ---
                app = Application.new
                app.authority_name    = authority.name
                app.council_reference = ref_link.text_content&.strip
                app.description       = detail_page.locator(".field-name-body .field-item")&.text_content&.strip
                app.address           = detail_page.locator(".field-name-field-plan-app-site .field-item")&.text_content&.strip
                app.date_received     = Date.parse(
                                          detail_page.locator(".field-name-field-plan-app-date-received .date-display-single")&.text_content&.strip
                                        )
                app.info_url          = href

                # collect documents
                docs = detail_page.locator(".field-name-field-plan-app-plans-documents a")
                if docs.count > 0
                  app.documents_count = docs.count
                  app.documents_url   = docs.first.get_attribute("href")
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
                  puts "  ⚠️ Skipped invalid application (#{app.council_reference || 'unknown ref'})"
                end

                detail_page.close
                page.wait_for_timeout(250)
              end

              # --- New robust pagination for Copeland ---
              next_link = page.locator('a[title="Go to next page"]').first
              if next_link && next_link.count > 0
                next_href = next_link.get_attribute('href') rescue nil
                if next_href && !next_href.empty?
                  next_url = URI.join(authority.url, next_href).to_s
                  puts "➡️ Navigating to next page: #{next_url}"
                  page.goto(next_url)
                  page.wait_for_load_state
                  page.wait_for_timeout(500)
                else
                  puts "ℹ️ Next link found but no valid href — stopping."
                  break
                end
              else
                puts "ℹ️ No 'Next' link found — pagination finished."
                break
              end
            end

            browser.close
          end
        end
      end
      results
    end
    def self.scrape_crawley(authority, params)
      puts "🔍 Scraping Crawley (randoms1)"

      results = []
      begin
        Timeout.timeout(900) do 
          Playwright.create(playwright_cli_executable_path: Playwright::CLI_EXECUTABLE_PATH) do |playwright|
            browser = playwright.chromium.launch(headless: false)
            page = browser.new_page

            # Go to base URL
            page.goto(authority.url)
            page.wait_for_load_state

            # --- Close cookies if banner exists ---
            begin
              if page.locator('#cookie-alert button:has-text("Close")').count > 0
                page.click('#cookie-alert button:has-text("Close")')
                page.wait_for_load_state
                puts "✅ Closed cookie banner"
              end
            rescue => e
              puts "⚠️ Could not close cookie banner: #{e.message}"
            end

            # Try to accept disclaimer if present
            begin
              if page.locator('#agreeToDisclaimer').count > 0
                page.click('#agreeToDisclaimer')
                page.wait_for_load_state
              elsif page.locator('input[value="Agree"]').count > 0
                page.click('input[value="Agree"]')
                page.wait_for_load_state
              end
            rescue => _e
              # non-fatal
            end

            # ✅ FIXED: Click Advanced Search tab
            begin
              if page.locator('#AdvancedSearchTab').count > 0
                page.click('#AdvancedSearchTab')
                page.wait_for_selector('#advanced', timeout: 5000) # wait for advanced tab content
                puts "✅ Opened Advanced Search tab"
              else
                puts "⚠️ Advanced Search tab not found"
              end
            rescue => e
              puts "⚠️ Could not open Advanced Search tab: #{e.message}"
            end

            # Format dates
            from = params[:validated_from] || params[:received_from] || (Date.today - DAYS)
            to   = params[:validated_to]   || params[:received_to]   || Date.today

            from_str = from.strftime('%d/%m/%Y')
            to_str   = to.strftime('%d/%m/%Y')

            # Fill date inputs
            if page.locator('input[name="DateIssuedFrom"]').count > 0
              page.fill('input[name="DateIssuedFrom"]', from_str)
            elsif page.locator('input#DateIssuedFrom').count > 0
              page.fill('input#DateIssuedFrom', from_str)
            end

            if page.locator('input[name="DateIssuedTo"]').count > 0
              page.fill('input[name="DateIssuedTo"]', to_str)
            elsif page.locator('input#DateIssuedTo').count > 0
              page.fill('input#DateIssuedTo', to_str)
            end

            # Click search button
            begin
              if page.locator('#SearchRegisterButton').count > 0
                page.click('#SearchRegisterButton')
              elsif page.locator('button:has-text("Search")').count > 0
                page.click('button:has-text("Search")')
              end
            rescue => e
              warn "  ⚠️ Clicking search failed: #{e.class} - #{e.message}"
            end

            # Wait for results list
            begin
              page.wait_for_selector('div.results__item, div.row.results__item', timeout: 15_000)
            rescue
              browser.close
              return results
            end

            # tiny helper to safely fetch text from a selector
            get_text = ->(selector) do
              loc = page.locator(selector)
              loc.count > 0 ? loc.nth(0).text_content&.strip : nil
            end

            loop do
              # --- Process all results on current page ---
              rows = page.locator('div.results__item, div.row.results__item')
              row_count = rows.count
              puts "📄 Found #{row_count} results on this page."

              row_count.times do |i|
                row = rows.nth(i)

                ref_link = row.locator('a[href*="/Planning/Display"], a[href*="/Planning/Display/"], a')
                next unless ref_link.count > 0

                ref_text = ref_link.nth(0).text_content&.strip
                begin
                  ref_link.nth(0).click
                rescue => e
                  warn "  ⚠️ Could not click reference link #{ref_text}: #{e.class} - #{e.message}"
                  next
                end

                begin
                  page.wait_for_selector('div.tab-content.application, label:has-text("Application Number")', timeout: 10_000)
                rescue
                  page.wait_for_timeout(500)
                end

                council_ref    = get_text.call('label:has-text("Application Number") + div.form-control span') || ref_text
                address_text   = get_text.call('label:has-text("Location") + div.form-control span') ||
                                get_text.call('label:has-text("Location:") + div.form-control span') ||
                                get_text.call('label:has-text("Location") + div.form-control.readOnlyDetails span')
                desc_text      = get_text.call('label:has-text("Proposal") + div.form-control span') ||
                                get_text.call('label:has-text("Proposal:") + div.form-control span') ||
                                get_text.call('label:has-text("Proposal") + div.form-control.readOnlyDetails span')
                status_text    = get_text.call('label:has-text("Status") + div.form-control span')
                decision_text  = get_text.call('label:has-text("Decision") + div.form-control span')
                received_text = get_text.call('label:has-text("Registered Date") + div.form-control span') ||
                                get_text.call('label:has-text("Registered Date") + div.form-control.readOnlyDetails span') ||
                                get_text.call('label:has-text("Date Registered") + div.form-control span') ||
                                get_text.call('label:has-text("Date Registered") + div.form-control.readOnlyDetails span')

                # Safely parse the date
                begin
                  if received_text && received_text.strip.match?(/\d{1,2}\/\d{1,2}\/\d{4}/)
                    date_received = Date.strptime(received_text.strip, '%d/%m/%Y') rescue Date.parse(received_text)
                  else
                    date_received = nil
                  end
                rescue => e
                  puts "⚠️ Could not parse received date '#{received_text}': #{e.class} - #{e.message}"
                  date_received = nil
                end

                docs_count = 0
                if page.locator('div#documents table.table tbody tr').count > 0
                  docs_count = page.locator('div#documents table.table tbody tr').count
                elsif page.locator('div.tab-pane#documents table.table tbody tr').count > 0
                  docs_count = page.locator('div.tab-pane#documents table.table tbody tr').count
                end

                app = Application.new
                app.authority_name    = authority.name
                app.council_reference = council_ref
                app.date_received     = date_received
                app.status            = status_text
                app.decision          = decision_text
                app.info_url          = page.url
                app.address           = address_text
                app.description       = desc_text
                app.documents_count   = docs_count
                app.documents_url     = page.url

                if app.valid?
                  results << app
                  puts "------------------------------------------------------------"
                  puts "  Ref:        #{app.council_reference}"
                  puts "  Address:    #{app.address}"
                  puts "  Description:#{app.description}"
                  puts "  Date:       #{app.date_received}"
                  puts "  Docs:       #{app.documents_count}"
                  puts "  Link:       #{app.info_url}"
                  puts "------------------------------------------------------------"
                  puts "  → Added application #{app.council_reference}"
                else
                  puts "  ⚠️ Skipped invalid application (#{council_ref})"
                end

                # --- Return to results list ---
                begin
                  if page.locator('a.btn-results, a.btn-results.btn-labeled, a:has-text("Return to search results")').count > 0
                    page.click('a.btn-results, a:has-text("Return to search results")')
                    page.wait_for_selector('div.results__item, div.row.results__item', timeout: 10_000)
                  else
                    page.go_back
                    page.wait_for_selector('div.results__item, div.row.results__item', timeout: 10_000)
                  end
                rescue => e
                  warn "  ⚠️ Could not return to results cleanly: #{e.class} - #{e.message}"
                end

                page.wait_for_timeout(200)
              end

              # --- PAGINATION ---
              begin
                next_link = page.locator('li a[aria-label="Next Page."]')

                if next_link.count == 0
                  puts "ℹ️ No pagination link found — finished."
                  break
                end

                next_href = next_link.first.get_attribute('href') rescue nil
                if next_href.nil? || next_href.strip.empty?
                  puts "ℹ️ No further pages — pagination complete."
                  break
                end

                prev_count = page.locator('div.results__item, div.row.results__item').count
                puts "➡️ Navigating to next page: #{next_href}"

                # Build the correct absolute URL relative to the current /Search/Results page
                current_url = page.url.sub(/\/\d+$/, '') # remove /2, /3 etc. if already paged
                base_results_url = "https://planningregister.crawley.gov.uk"
                next_page_url = "#{base_results_url}#{next_href}"

                page.goto(next_page_url)
                page.wait_for_load_state
                begin
                  page.wait_for_function(%Q{
                    () => document.querySelectorAll('div.results__item, div.row.results__item').length !== #{prev_count}
                  }, timeout: 10_000)
                rescue
                  page.wait_for_timeout(1200)
                end

                page.wait_for_selector('div.results__item, div.row.results__item', timeout: 8_000)
              rescue => pag_e
                warn "⚠️ Pagination failed: #{pag_e.class} - #{pag_e.message}; stopping pagination."
                break
              end

            end # loop

            browser.close
          end
        end
      end
      results
    end
    def self.scrape_dorset(authority, params)
      puts "🔍 Scraping Dorset (randoms1)"
      results = []
      seen_references = Set.new

      today = Date.today
      from_date = params[:received_from] ? Date.parse(params[:received_from]) : today - DAYS
      to_date   = params[:received_to]   ? Date.parse(params[:received_to])   : today
      begin
        Timeout.timeout(1500) do 
          Playwright.create(playwright_cli_executable_path: Playwright::CLI_EXECUTABLE_PATH) do |playwright|
            browser = playwright.chromium.launch(headless: false) # visible browser for debugging
            page = browser.new_page

            # Go to base URL
            page.goto("https://planning.dorsetcouncil.gov.uk/advsearch.aspx")
            page.wait_for_load_state

            # Accept T&Cs if present
            if page.locator('input[name="ctl00$ContentPlaceHolder1$btnAccept"]').count > 0
              page.click('input[name="ctl00$ContentPlaceHolder1$btnAccept"]')
              page.wait_for_load_state
            end

            # Click Advanced Search link
            if page.locator('a:has-text("Advanced Search")').count > 0
              page.click('a:has-text("Advanced Search")')
              page.wait_for_load_state
            end

            # Fill in from/to date fields
            page.fill('input[name="ctl00$ContentPlaceHolder1$txtDateReceivedFrom$dateInput"]', from_date.strftime("%d/%m/%Y"))
            page.fill('input[name="ctl00$ContentPlaceHolder1$txtDateReceivedTo$dateInput"]',   to_date.strftime("%d/%m/%Y"))

            # Click search
            page.click('input[name="ctl00$ContentPlaceHolder1$btnSearch3"]')
            page.wait_for_load_state

            loop do
              # Wait for result rows
              page.wait_for_selector('#news_results_list .emphasise-area', timeout: 10_000)
              rows = page.locator('#news_results_list .emphasise-area')
              row_count = rows.count
              puts "  → Found #{row_count} rows"

              new_apps = 0

              row_count.times do |i|
                row = rows.nth(i)

                ref_link = row.locator('h2 a')
                next unless ref_link.count > 0

                app_ref = ref_link.text_content&.strip
                next if seen_references.include?(app_ref)

                href    = ref_link.get_attribute("href")
                app_url = URI.join("https://planning.dorsetcouncil.gov.uk/advsearch.aspx", href).to_s

                # === Go into details page (scrape everything from here) ===
                detail_page = browser.new_page
                detail_page.goto(app_url)
                detail_page.wait_for_load_state

                # Accept disclaimer on detail page if shown
                if detail_page.locator('input[name="ctl00$ContentPlaceHolder1$btnAccept"]').count > 0
                  detail_page.click('input[name="ctl00$ContentPlaceHolder1$btnAccept"]')
                  detail_page.wait_for_load_state
                end

                details = {}
                details['reference']    = detail_page.locator('span.applabel:has-text("Application No") + p').text_content rescue nil
                details['status']       = detail_page.locator('span.applabel:has-text("Status") + p').text_content rescue nil
                details['type']         = detail_page.locator('span.applabel:has-text("Type") + p').text_content rescue nil
                details['valid_date']   = detail_page.locator('span.applabel:has-text("Valid Date") + p').text_content rescue nil
                details['decision']     = detail_page.locator('span.applabel:has-text("Decision") + p').text_content rescue nil
                details['proposal']     = detail_page.locator('#proposal p.appdata').text_content rescue nil

                # Go to the Location tab first (if not already there)
                if detail_page.locator('a.rtsLink:has-text("Location")').count > 0
                  detail_page.click('a.rtsLink:has-text("Location")')
                  detail_page.wait_for_selector('#ctl00_ContentPlaceHolder1_pvLocation', timeout: 10_000) rescue nil
                end

                # Find the "Address" label and grab the *next sibling* <p.appdata>
                begin
                  address_el = detail_page.locator('div#ctl00_ContentPlaceHolder1_pvLocation span.applabel')
                  if address_el.count > 0
                    address_node = address_el.first.evaluate_handle('el => el.nextElementSibling')
                    address_text = address_node&.evaluate('el => el.textContent')&.strip
                    address = address_text&.strip&.gsub(/\s+/, ' ')
                  else
                    # fallback: take the first p.appdata under leftcol
                    address_text = detail_page.locator('div#ctl00_ContentPlaceHolder1_pvLocation .leftcol p.appdata').first.text_content rescue nil
                    address = address_text&.strip&.gsub(/\s+/, ' ')
                  end
                rescue => e
                  puts "⚠️ Failed to extract Dorset address: #{e.message}"
                  address = nil
                end

                # --- Build Application object ---
                app = Application.new
                app.authority_name    = authority.name
                app.council_reference = app_ref
                app.address           = address
                app.description       = details['proposal']
                app.status            = details['status']
                app.decision          = details['type']
                app.date_received     = Date.parse(details['valid_date'])
                app.info_url          = app_url

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
                  seen_references.add(app_ref)
                  new_apps += 1
                  puts "  → Added application #{app.council_reference}"
                else
                  puts "  ⚠️ Skipped invalid application (#{app_ref})"
                end

                detail_page.close
              end

              if new_apps == 0
                puts "ℹ️ No new applications on this page — stopping pagination."
                break
              end

              # --- Pagination Fix for Dorset ---
              begin
                page_info = page.locator('#ctl00_ContentPlaceHolder1_lvResults_RadDataPager1 .rdpWrap').last.text_content.strip rescue nil

                if page_info
                  match = page_info.match(/Page (\d+) of (\d+)/)
                  if match
                    current_page = match[1].to_i
                    total_pages = match[2].to_i

                    if current_page >= total_pages
                      puts "ℹ️ Reached last page (#{current_page}/#{total_pages}) — stopping."
                      break
                    end
                  end
                end

                next_btn = page.locator('#ctl00_ContentPlaceHolder1_lvResults_RadDataPager1_ctl02_NextButton')

                if next_btn.count > 0
                  puts "➡️ Moving to next page..."
                  next_btn.click
                  page.wait_for_load_state

                  # Wait for the results to refresh
                  page.wait_for_selector('#news_results_list .emphasise-area', timeout: 15_000)
                  page.wait_for_timeout(750)
                else
                  puts "ℹ️ No Next button found — pagination complete."
                  break
                end
              rescue StandardError => pag_e
                puts "⚠️ Pagination error: #{pag_e.class} - #{pag_e.message}"
                break
              end
              # --- END PAGINATION FIX ---
            end

            browser.close
          end
        end
      end
      results
    end
    def self.scrape_east_staffordshire(authority, params)
      puts "🌿 Launching headful browser for East Staffordshire..."

      results = []
      from = params[:validated_from] || params[:received_from] || (Date.today - DAYS)
      to   = params[:validated_to]   || params[:received_to]   || Date.today

      from_str = from.strftime('%d/%m/%Y')
      to_str   = to.strftime('%d/%m/%Y')
      begin
        Timeout.timeout(900) do 
          Playwright.create(playwright_cli_executable_path: Playwright::CLI_EXECUTABLE_PATH) do |playwright|
            browser = playwright.chromium.launch(headless: false)
            context = browser.new_context
            page = context.new_page
            puts "yo wahatshksglkjsghd"
            begin
              page.goto(authority.url)
              page.wait_for_load_state

              # --- Accept cookies ---
              if page.locator('button:has-text("Accept additional cookies")').count > 0
                page.click('button:has-text("Accept additional cookies")') rescue nil
                puts "🍪 Accepted cookies"
                page.wait_for_timeout(500)
              else
                puts "accept button not found"
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
                puts "🔍 Clicked second Search button (East Staffordshire)"
              else
                search_buttons.first.click rescue nil
                puts "⚠️ Only one Search button found; clicked first one"
              end
              sleep 2
              page.wait_for_selector('div[data-id][role="row"] a.entityTable__linkCell', timeout: 30_000)
              puts "✅ Results loaded for East Staffordshire"

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
                    puts "❌ Error processing East Staffordshire row #{i + 1}: #{row_err.class} - #{row_err.message}"
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
              puts "❌ Error scraping East Staffordshire: #{e.class} - #{e.message}"
              puts e.backtrace.first
            ensure
              browser.close rescue nil
            end
          end
        end
      end
      results
    end
    def self.scrape_eastleigh(authority, params)
      results = []
      begin
        Timeout.timeout(900) do 
          Playwright.create(playwright_cli_executable_path: Playwright::CLI_EXECUTABLE_PATH) do |playwright|
            puts "➡️ Launching Playwright for Eastleigh"
            browser = playwright.chromium.launch(headless: false)
            page = browser.new_page
            page.goto(authority.url)
            puts "🌐 Navigated to #{authority.url}"

            # Handle cookie confirmation
            begin
              cookie_button = page.locator('#ccc-dismiss-button')
              if cookie_button.visible?
                cookie_button.click(timeout: 5_000)
                page.wait_for_timeout(1_000)
                puts "✅ Clicked cookie confirm"
              end
            rescue => e
              puts "⚠️ Cookie banner handling failed: #{e.message}"
            end

            # Go to Advanced Search tab
            begin
              page.click('a[data-label="Advanced Search"]', timeout: 10_000)
              puts "✅ Clicked Advanced Search tab"
              page.wait_for_timeout(2_000)
            rescue => e
              puts "❌ Failed to click Advanced Search tab: #{e.message}"
              browser.close
              return []
            end
            from = params[:validated_from] || params[:received_from] || (Date.today - DAYS)
            to   = params[:validated_to]   || params[:received_to]   || Date.today

            # Fill in from / to dates (Salesforce Lightning inputs)
            begin
              date_inputs = page.locator('input.input')
              if date_inputs.count >= 2
                date_inputs.nth(1).fill(from)
                date_inputs.nth(0).fill(to)
                puts "📝 Filled in date range #{from} - #{to}"
              else
                puts "⚠️ Did not find expected date input controls; continuing anyway."
              end
            rescue => e
              puts "⚠️ Failed to fill date fields: #{e.message}"
            end

            # Robustly click the Search button — allow fallback and then "click off" and force the real submit
            begin
              clicked = false

    #################################################################################################
              # 1) Try any visible button[name="submit"]
              submit_buttons = page.locator('button[name="submit"]')
              if submit_buttons.count > 0
                (0...submit_buttons.count).each do |bi|
                  btn = submit_buttons.nth(bi)
                  begin
                    if btn.visible?
                      btn.click(timeout: 10_000)
                      clicked = true
                      #puts "✅ Clicked button[name='submit'] (index #{bi})"
                      break
                    end
                  rescue => click_err
                    #puts "⚠️ button[name='submit'] click failed (index #{bi}): #{click_err.message}"
                    next
                  end
                end
              end

              # 2) Fallback: find any visible button with text "Search" but skip the top-bar search-button by class
              if !clicked
                search_buttons = page.locator('button:has-text("Search")')
                if search_buttons.count > 0
                  (0...search_buttons.count).each do |si|
                    btn = search_buttons.nth(si)
                    begin
                      next unless btn.visible?
                      cls = (btn.get_attribute('class') rescue '') || ''
                      if cls.to_s.include?('search-button')
                        #puts "ℹ️ Skipping top-bar search button (index #{si})"
                        next
                      end

                      btn.click(timeout: 10_000)
                      clicked = true
                      puts "✅ Clicked fallback visible Search button (index #{si})"
                      break
                    rescue => click_err
                      #puts "⚠️ Fallback Search button click failed (index #{si}): #{click_err.message}"
                      next
                    end
                  end
                end
              end
    ################################################################################################
              # 3) JS form-local fallback: click button[name='submit'] inside the form that contains the date inputs
              if !clicked
                begin
                  js_click_form_btn = <<~JS
                    (() => {
                      const inputs = document.querySelectorAll('input.input');
                      for (let i = 0; i < inputs.length; i++) {
                        const form = inputs[i].closest('form');
                        if (!form) continue;
                        const btn = form.querySelector('button[name="submit"]');
                        if (btn) { btn.click(); return true; }
                      }
                      const any = Array.from(document.querySelectorAll('button[name="submit"]')).find(b => b.offsetParent !== null);
                      if (any) { any.click(); return true; }
                      return false;
                    })();
                  JS
                  ok = page.evaluate(js_click_form_btn) rescue false
                  if ok
                    clicked = true
                    puts "✅ Clicked form-local button[name='submit'] via JS fallback"
                  else
                    puts "⚠️ JS form-local fallback did not find a button to click"
                  end
                rescue => e
                  puts "⚠️ JS fallback failed: #{e.message}"
                end
              end

              unless clicked
                puts "❌ Could not find a suitable Search button to click. Exiting Eastleigh block."
                browser.close
                return []
              end

              page.evaluate("document.activeElement && document.activeElement.blur && document.activeElement.blur()") rescue nil
              page.click('body') rescue nil
              page.wait_for_timeout(700)

              begin
                post_submit_buttons = page.locator('button[name="submit"]')
                if post_submit_buttons.count > 0
                  (0...post_submit_buttons.count).each do |bi|
                    btn = post_submit_buttons.nth(bi)
                    begin
                      next unless btn.visible?
                      btn.click(timeout: 8_000)
                      puts "🔁 Clicked explicit post-blur button[name='submit'] (index #{bi})"
                      break
                    rescue
                      next
                    end
                  end
                end 
              rescue
              end

              page.wait_for_timeout(1500)
              puts "✅ Search submit attempted (with blur/click-off)"
            rescue => e
              puts "⚠️ Failed to locate/click Search button: #{e.message}"
            end

            # Expand results (View More loop)
            loop do
              begin
                view_more = page.locator('a:has-text("View More")')
                break unless view_more.visible?
                view_more.click
                page.wait_for_timeout(2_000)
                puts "📄 Loaded more results"
              rescue
                break
              end
            end

            # Scrape each result by clicking through
            records = page.locator('#arcusbuilt__PApplication__c .article')
            count = records.count
            puts "📊 Found #{count} applications"

            count.times do |i|
              begin
                record = records.nth(i)
                link = record.locator('h4 a')
                ref_text = link.inner_text rescue nil
                puts "➡️ Opening application #{ref_text}"

                # Open detail page
                link.click
                page.wait_for_timeout(2_000)

                # Extract all details
                council_reference = page.locator('label:has-text("Planning Application Number") + span.uiOutputText').inner_text rescue nil
                address_text      = page.locator('label:has-text("Site Address") + span.uiOutputText').inner_text rescue nil
                desc_text         = page.locator('label:has-text("Proposal") + span.uiOutputText').inner_text rescue nil
                status_text       = page.locator('label:has-text("Application Status") + span.uiOutputText').inner_text rescue nil
                app_type_text     = page.locator('label:has-text("Application Type") + span.uiOutputText').inner_text rescue nil
                begin
                  received_date = nil

                  # Find all candidate rows, then pick the one that contains the label text "Date Received"
                  rows = page.locator('div.slds-form-element__row')
                  rows_count = rows.count rescue 0

                  found_row = nil
                  (0...rows_count).each do |ri|
                    r = rows.nth(ri)
                    txt = (r.text_content || '').strip
                    if txt =~ /Date\s*Received/i
                      found_row = r
                      break
                    end
                  end

                  if found_row
                    # Try a few selectors that might contain the date in different Lightning markup variants
                    date_span = nil
                    date_span = found_row.locator('span.uiOutputDate').first if found_row.locator('span.uiOutputDate').count > 0 rescue nil
                    date_span ||= found_row.locator('div.slds-truncate span').first if found_row.locator('div.slds-truncate span').count > 0 rescue nil
                    date_span ||= found_row.locator('div.form__field span').first if found_row.locator('div.form__field span').count > 0 rescue nil

                    received_date_text = date_span ? (date_span.text_content || '').strip : nil

                    if received_date_text && received_date_text.match?(/\d{1,2}\/\d{1,2}\/\d{4}/)
                      # normalize to dd/mm/YYYY
                      begin
                        received_date = Date.strptime(received_date_text.strip, '%d/%m/%Y')
                      rescue ArgumentError
                        # try fallback parse
                        received_date = Date.parse(received_date_text) rescue nil
                      end
                    end
                  end
                rescue => e
                  puts "⚠️ Failed to parse received date: #{e.class} - #{e.message}"
                  received_date = nil
                end

                docs_count = 0
                begin
                  page.click('a.slds-tabs_default__link[data-label="Documents"]', timeout: 5_000)
                  page.wait_for_timeout(2_000)
                  docs_count = page.locator('.slds-table tbody tr').count rescue 0
                  puts "📑 Found #{docs_count} documents"
                rescue
                  puts "⚠️ No documents tab or failed to fetch docs"
                end
                # === Rewritten Application.new save block ===
                app = Application.new
                app.authority_name    = authority.name
                app.council_reference = council_reference
                app.date_received     = received_date
                app.status            = status_text
                app.info_url          = authority.url
                app.address           = address_text
                app.description       = desc_text
                app.documents_count   = docs_count
                app.documents_url     = authority.url

                if app.valid?
                  results << app
                  puts "✅ Valid app: #{app.to_hash}"
                else
                  puts "⛔ Skipping invalid app: #{app.council_reference.inspect}"
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
                # Return to results
                page.click('button[name="BackButton"]', timeout: 10_000)
                page.wait_for_timeout(2_000)
              rescue => e
                puts "⚠️ Error scraping application ##{i}: #{e.message}"
                next
              end
            end

            browser.close
          end
        end
      end
      results
    end
    def self.scrape_elmbridge(authority, params)
      results = []
      begin
        Timeout.timeout(900) do 
          Playwright.create(playwright_cli_executable_path: Playwright::CLI_EXECUTABLE_PATH) do |playwright|
            browser = playwright.chromium.launch(headless: false) # visible for debugging
            page = browser.new_page

            # Go to base URL
            page.goto(authority.url)
            page.wait_for_load_state
            puts "🌐 Loaded Elmbridge base page"

            # Click "Advanced Search" tab
            begin
              page.click('ul#navlist li.atNav a:has-text("Advanced Search")')
              page.wait_for_load_state
              puts "🟢 Opened Advanced Search tab"
            rescue => e
              puts "❌ Failed to open Advanced Search: #{e.message}"
            end
            from = params[:validated_from] || params[:received_from] || (Date.today - DAYS)
            to   = params[:validated_to]   || params[:received_to]   || Date.today

            # Fill in date fields
            begin

              page.fill('input[name="datedec_from:PARAM"]', from.strftime('%Y-%m-%d'))
              page.fill('input[name="datedec_to:PARAM"]',   to.strftime('%Y-%m-%d'))
              puts "📝 Filled date range #{from} → #{to}"
            rescue => e
              puts "⚠️ Failed to fill date fields: #{e.message}"
            end

            # Select 250 max records
            begin
              page.select_option('#maxrecords', value: '250')
              puts "📑 Selected 250 max records"
            rescue => e
              puts "⚠️ Failed to select 250 records: #{e.message}"
            end

            # Submit form
            begin
              page.click('input[type="submit"], button[type="submit"]', timeout: 5_000)
              page.wait_for_load_state
              puts "✅ Submitted search form"
            rescue => e
              puts "❌ Failed to submit form: #{e.message}"
            end

            # Process results table
            rows = page.locator('#atWeeklyListTable tr')
            row_count = rows.count
            puts "📊 Found #{row_count - 1} applications (excluding header)"

            (1...row_count).each do |i| # skip header row
              row = rows.nth(i)

              ref     = row.locator('td').nth(0).text_content&.strip rescue nil
              address = row.locator('td.address').text_content&.strip rescue nil
              desc    = row.locator('td.proposal').text_content&.strip rescue nil
              link    = row.locator('a.atLinkbutton')
              next unless ref && link.count > 0

              app_url = link.get_attribute("href")
              info_url = URI.join(page.url, app_url).to_s

              # --- Build Application object ---
              app = Application.new
              app.authority_name    = authority.name
              app.council_reference = ref
              app.address           = address
              app.description       = desc
              app.info_url          = info_url

              puts "➡️ Opening application #{ref}"

              # Open details page
              link.click
              page.wait_for_load_state

              # Scrape main details
              extra_details = {} # store non-model fields safely
              page.locator('dl dt').all.each do |dt|
                label = dt.text_content&.strip
                value = dt.locator('xpath=following-sibling::dd[1]').text_content&.strip rescue nil
                case label
                when 'Development address :'
                  app.address = value
                when 'Description :'
                  app.description = value
                when 'Decision :'
                  app.decision = value
                when 'Status:'
                  app.status = value
                when 'Application Type :'
                  extra_details[:application_type] = value
                end
              end

              # Key Dates tab
              if page.locator('a:has-text("Key Dates")').count > 0
                page.click('a:has-text("Key Dates")')
                page.wait_for_load_state

                page.locator('dl dt').all.each do |dt|
                  label = dt.text_content&.strip
                  value = dt.locator('xpath=following-sibling::dd[1]').text_content&.strip rescue nil
                  case label
                  when 'Received On :'
                    app.date_received = Date.parse(value)

                  end
                end
              end

              # Plans & Documents tab
              if page.locator('a:has-text("Plans & Documents")').count > 0
                page.click('a:has-text("Plans & Documents")')
                page.wait_for_load_state

                docs_rows = page.locator('#docs tr').all.select do |tr|
                  tr.locator('.document-description').count > 0
                end

                app.documents_count = docs_rows.size
                app.documents_url   = page.url
                puts "📑 Found #{docs_rows.size} documents"
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
                puts "  ⚠️ Skipped invalid application (#{ref})"
              end

              # Back three times → Key Dates → Details → Results
              3.times do
                page.go_back
                page.wait_for_load_state
              end
              puts "⬅️ Returned to results"
            end

            browser.close
          end
        end
      end
      results
    end
    def self.scrape_erewash(authority, params)
      puts "🔍 Scraping Erewash (randoms1)"

      results = []
      begin
        Timeout.timeout(900) do 
          Playwright.create(playwright_cli_executable_path: Playwright::CLI_EXECUTABLE_PATH) do |playwright|
            browser = playwright.chromium.launch(headless: false)
            page = browser.new_page

            # Go to base URL
            page.goto(authority.url)
            page.wait_for_load_state

            # Fill in date range
            from = params[:validated_from] || params[:received_from] || (Date.today - DAYS)
            to   = params[:validated_to]   || params[:received_to]   || Date.today

            from_str = from.strftime('%d/%m/%Y')
            to_str   = to.strftime('%d/%m/%Y')

            page.fill('#DateValidFrom', from_str)
            page.fill('#DateValidTo', to_str)

            # Click search
            page.click('button[name="ClickedSearchButtonId"][value="SearchAll"]')

            # Wait for results
            page.wait_for_selector('ul.results-list li')

            base_results_url = 'https://register.civicacx.co.uk/Erewash/Planning/Results/'

            loop do
              rows = page.locator('ul.results-list li')
              rows.count.times do |i|
                row = rows.nth(i)

                ref_text     = row.locator('h4 span:nth-of-type(2)')&.text_content&.strip
                desc_text    = row.locator('dt:has-text("Application Description") + dd span')&.text_content&.strip
                date_val_txt = row.locator('dt:has-text("Date Valid") + dd span')&.text_content&.strip
                decision_txt = row.locator('dt:has-text("Decision Type") + dd span')&.text_content&.strip
                address_txt  = row.locator('dt:has-text("Site Address") + dd')&.text_content&.strip

                date_validated = Date.parse(date_val_txt)


                details_link = row.locator('a:has-text("Details")').get_attribute('href') rescue nil
                docs_link    = row.locator('a:has-text("Documents")').get_attribute('href') rescue nil

                base_url    = "https://register.civicacx.co.uk"
                details_url = details_link ? URI.join(base_url, details_link).to_s : nil
                docs_url    = docs_link    ? URI.join(base_url, docs_link).to_s    : nil

                app = Application.new
                app.authority_name    = authority.name
                app.council_reference = ref_text
                app.description       = desc_text
                app.date_received    = date_validated
                app.decision          = decision_txt
                app.address           = address_txt
                app.info_url          = details_url || authority.url

                extra_details = {}

                # --- Scrape details page ---
                if details_url
                  page.goto(details_url)
                  page.wait_for_selector('.panel-body')

                  page.locator('.panel-body dl.form-group').all.each do |dl|
                    dt = dl.locator('dt').text_content.strip rescue nil
                    dd = dl.locator('dd span, dd div').text_content.strip rescue nil
                    next unless dt

                    case dt
                    when 'Application Type'       then extra_details[:application_type]  = dd
                    when 'Application Status'     then app.status = dd
                    end
                  end
                end

                # --- Scrape documents page ---
                if docs_url
                  page.goto(docs_url)
                  page.wait_for_selector('#bootstrap-table tbody tr', timeout: 5000) rescue nil

                  documents = []
                  page.locator('#bootstrap-table tbody tr').all.each do |tr|
                    title = tr.locator('td:nth-child(1) span').text_content.strip rescue nil
                    file  = tr.locator('td:nth-child(2) span').text_content.strip rescue nil
                    url   = tr.locator('td:nth-child(3) a').get_attribute('href') rescue nil
                    next unless title && url

                    full_url = URI.join(base_url, url).to_s
                    documents << { title: title, file: file, url: full_url }
                  end

                  app.documents_count = documents.size
                  app.documents_url   = docs_url
                  extra_details[:documents] = documents
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
                  puts "  ⚠️ Skipped invalid application (#{ref_text})"
                end

                # --- Go back to results properly ---
                begin
                  back_link = page.locator('a.btn.btn-default:has-text("Back to Results")')
                  if back_link.count > 0
                    back_href = back_link.first.get_attribute('href') rescue nil
                    if back_href && !back_href.strip.empty?
                      full_back_url = URI.join("https://register.civicacx.co.uk", back_href).to_s
                      page.goto(full_back_url)
                      page.wait_for_selector('ul.results-list li', timeout: 10_000)
                    else
                      puts "⚠️ Back to Results link found but href was empty — reloading search."
                      page.goto(authority.url)
                      page.wait_for_selector('#DateValidFrom')
                      page.fill('#DateValidFrom', from_str)
                      page.fill('#DateValidTo', to_str)
                      page.click('button[name="ClickedSearchButtonId"][value="SearchAll"]')
                      page.wait_for_selector('ul.results-list li')
                    end
                  else
                    puts "⚠️ No Back to Results link — re-running search."
                    page.goto(authority.url)
                    page.wait_for_selector('#DateValidFrom')
                    page.fill('#DateValidFrom', from_str)
                    page.fill('#DateValidTo', to_str)
                    page.click('button[name="ClickedSearchButtonId"][value="SearchAll"]')
                    page.wait_for_selector('ul.results-list li')
                  end
                rescue => e
                  warn "  ⚠️ Could not return to results cleanly: #{e.class} - #{e.message}"
                end

              end

              # --- PAGINATION ---
              begin
                next_link = page.locator('a.page-link[aria-label="Next"]')
                if next_link.count == 0
                  puts "ℹ️ No pagination link found — finished."
                  break
                end

                next_href = next_link.first.get_attribute('href') rescue nil
                if next_href.nil? || next_href.strip.empty?
                  puts "ℹ️ No further pages — pagination complete."
                  break
                end

                prev_count = page.locator('ul.results-list li').count
                next_page_url = URI.join(base_results_url, next_href).to_s
                puts "➡️ Navigating to next page: #{next_page_url}"

                page.goto(next_page_url)
                page.wait_for_load_state

                begin
                  page.wait_for_function(%Q{
                    () => document.querySelectorAll('ul.results-list li').length !== #{prev_count}
                  }, timeout: 10_000)
                rescue
                  page.wait_for_timeout(1200)
                end

                page.wait_for_selector('ul.results-list li', timeout: 8_000)
              rescue => pag_e
                warn "⚠️ Pagination failed: #{pag_e.class} - #{pag_e.message}; stopping pagination."
                break
              end
            end

            browser.close
          end
        end
      end
      results
    end
    def self.scrape_fareham(authority, params)
      puts "🔍 Scraping Fareham (randoms1)"
      results = []
      begin
        Timeout.timeout(900) do 
          Playwright.create(playwright_cli_executable_path: Playwright::CLI_EXECUTABLE_PATH) do |playwright|
            browser = playwright.chromium.launch(headless: false)
            page = browser.new_page

            # Go to base URL
            page.goto(authority.url)
            page.wait_for_load_state

            # Accept cookies if button is there
            if page.locator('a.cookieButton').count > 0
              page.click('a.cookieButton')
            end

            # Go to advanced search
            if page.locator('a#BodyPlaceHolder_uxLinkButtonShowAdvancedSearch').count > 0
              page.click('a#BodyPlaceHolder_uxLinkButtonShowAdvancedSearch')
              page.wait_for_selector('#uxStartDateReceivedTextBox')
            end

            # === FORM FILLING PART ===
            from = params[:validated_from] || params[:received_from] || (Date.today - DAYS)
            to   = params[:validated_to]   || params[:received_to]   || Date.today

            from_str = from.strftime('%d/%m/%Y')
            to_str   = to.strftime('%d/%m/%Y')

            start_box = page.locator('input[name="ctl00$BodyPlaceHolder$uxStartDateReceivedTextBox"]')
            stop_box  = page.locator('input[name="ctl00$BodyPlaceHolder$uxStopDateReceivedTextBox"]')

            [start_box, stop_box].each_with_index do |box, idx|
              box.click
              box.press('Control+A')
              box.press('Delete')
              box.fill(idx == 0 ? from_str : to_str)
            end

            # Submit search
            page.click('#BodyPlaceHolder_uxButtonSearch')
            page.wait_for_selector('div.searchResultsTable')

            # === RESULTS LOOP ===
            loop do
              tables = page.locator('div.searchResultsTable')
              break if tables.count == 0

              tables.count.times do |i|
                tbl = tables.nth(i)

                ref_el   = tbl.locator('div.searchResultsHeadRow a[href*="ApplicationDetails.aspx"]')
                ref      = ref_el.count > 0 ? ref_el.text_content.strip : nil
                info_url = ref_el.count > 0 ? URI.join(authority.url, ref_el.get_attribute('href')).to_s : authority.url

                address  = tbl.locator('div.searchResultsHeadRow div.searchResultsCell:nth-of-type(2)').text_content.strip rescue nil
                proposal = tbl.locator('div.searchResultsRow:has(.searchResultsCellField:has-text("Proposal:")) div.searchResultsCell').text_content.strip rescue nil
                decision_date = tbl.locator('div.searchResultsRow:has(.searchResultsCellField:has-text("Decision Date:")) div.searchResultsCell').text_content.strip rescue nil
                status        = tbl.locator('div.searchResultsRow:has(.searchResultsCellField:has-text("Status:")) div.searchResultsCell').text_content.strip rescue nil

                # --- Build Application object ---
                app = Application.new
                app.authority_name    = authority.name
                app.council_reference = ref
                app.address           = address
                app.description       = proposal
                app.status            = status
                app.info_url          = info_url

                extra_details = {}

                # --- Details page ---
                if info_url
                  page2 = browser.new_page
                  page2.goto(info_url)
                  page2.wait_for_selector('div.detailsGridTable')

                  # Accept cookies inside details page if present
                  if page2.locator('a.cookieButton').count > 0
                    page2.click('a.cookieButton')
                  end

                  page2.locator('div.detailsGridTable div.docGridRow').all.each do |row|
                    field = row.locator('div.detailsCells.detailsFieldNames').text_content.strip rescue nil
                    value = row.locator('div.detailsCells.detailsValues').text_content.strip rescue nil
                    next unless field && value

                    case field
                    when 'Received'        then app.date_received   = Date.parse(value)
                    when 'Status'          then app.status          = value
                    when 'Reference'       then app.council_reference = value
                    else
                      # Safely convert the field name to a symbol without using Rails' parameterize
                      safe_key = field.downcase.gsub(/[^a-z0-9]+/, '_').sub(/^_+/, '').sub(/_+$/, '').to_sym
                      extra_details[safe_key] = value
                    end
                  end

                  # --- Documents page ---
                  docs_remaining = 0
                  if page2.locator('input[name="ctl00$BodyPlaceHolder$uxChangeView_Documents"]').count > 0
                    page2.click('input[name="ctl00$BodyPlaceHolder$uxChangeView_Documents"]')
                    page2.wait_for_selector('div.docGridTable div.docGridRow', timeout: 5_000) rescue nil

                    docs_remaining = [page2.locator('div.docGridTable div.docGridRow').count - 1, 0].max
                    puts "📄 Found #{docs_remaining} documents for #{ref}"

                    documents = []

                    if docs_remaining > 0
                      while docs_remaining > 0
                        row = page2.locator('div.docGridTable div.docGridRow').nth(docs_remaining)
                        date_pub = row.locator('div.docGridCells.docGridCell_0').text_content.strip rescue nil
                        type     = row.locator('div.docGridCells.docGridCell_1').text_content.strip rescue nil
                        desc     = row.locator('div.docGridCells.docGridCell_2').text_content.strip rescue nil
                        link     = row.locator('div.docGridCells.docGridCell_3 a').get_attribute('href') rescue nil

                        if link
                          documents << {
                            date_published: Date.parse(date_pub),
                            type:           type,
                            description:    desc,
                            url:            URI.join(authority.url, link).to_s
                          }
                        end

                        docs_remaining -= 1
                      end

                      app.documents_count = documents.size
                      app.documents_url   = page2.url
                      extra_details[:documents] = documents
                    end
                  end

                  page2.close
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
                  puts "  ⚠️ Skipped invalid application (#{ref})"
                end
              end

              # --- Next page? ---
              if page.locator('a[href*="ApplicationSearch.aspx?search=true"][title*="Next"]').count > 0
                next_link = page.locator('a[href*="ApplicationSearch.aspx?search=true"][title*="Next"]').get_attribute('href')
                page.goto(URI.join(authority.url, next_link).to_s)
                page.wait_for_selector('div.searchResultsTable')
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
    def self.scrape_herefordshire(authority, params)
      puts "🔍 Scraping Herefordshire (randoms1)"

      results = []
      begin
        Timeout.timeout(900) do 
          Playwright.create(playwright_cli_executable_path: Playwright::CLI_EXECUTABLE_PATH) do |playwright|
            browser = playwright.chromium.launch(headless: false)
            page = browser.new_page

            # Go to base URL
            page.goto(authority.url)
            page.wait_for_load_state

            # Accept cookies if button exists
            if page.locator('button[name="cookies-notification-allowed"]').count > 0
              page.click('button[name="cookies-notification-allowed"]') rescue nil
              page.wait_for_timeout(500)
            end
            from = params[:validated_from] || params[:received_from] || (Date.today - DAYS)
            to   = params[:validated_to]   || params[:received_to]   || Date.today

            begin
              # Wait for the "Recent applications" tab to appear
              page.wait_for_selector('a[href="#tab2"]')

              # Click the tab to open that section
              page.click('a[href="#tab2"]')
              page.wait_for_load_state

              puts "🧭 Navigated to 'Recent applications' tab successfully"
            rescue => e
              puts "⚠️ Could not navigate to 'Recent applications' tab: #{e.class} - #{e.message}"
            end

            # Click "Registered in the last 7 days"
            page.click('#registered7days')
            page.wait_for_selector('#results-table tbody tr')

            # 🧩 Click "250 Results per page" to avoid pagination
            begin
              if page.locator('button[id="250resultsPerPage"]').count > 0
                puts "⚙️ Switching to 250 results per page..."
                page.click('button[id="250resultsPerPage"]')
                page.wait_for_load_state
                page.wait_for_selector('#results-table tbody tr', timeout: 10_000)
                page.wait_for_timeout(1000)
                puts "✅ Switched to 250 results per page."
              else
                puts "ℹ️ No '250 results per page' button found — continuing with default page size."
              end
            rescue => e
              puts "⚠️ Could not switch to 250 results per page: #{e.class} - #{e.message}"
            end

            sleep 2
            base_url = "https://www.herefordshire.gov.uk"

            rows = page.locator('#results-table tbody tr')
            row_count = rows.count
            puts "📋 Found #{row_count} rows on the page"

            row_count.times do |i|
              row = rows.nth(i)

              # The link is in the first column (<td><a href="...">REF</a></td>)
              ref_el = row.locator('td:first-child a')
              next unless ref_el.count > 0

              ref_text = ref_el.text_content&.strip
              next unless ref_text && !ref_text.empty?

              # The href is a full absolute URL on Herefordshire's site
              info_href = ref_el.get_attribute('href')
              next unless info_href

              # Normalise the URL in case it’s relative (rarely)
              info_url = URI.join(base_url, info_href).to_s

              puts "🔗 Found application #{ref_text} → #{info_url}"

              # --- Open each detail page in a new tab ---
              detail_page = browser.new_page
              detail_page.goto(info_url)
              detail_page.wait_for_load_state
              if detail_page.locator('button[name="cookies-notification-allowed"]').count > 0
                detail_page.click('button[name="cookies-notification-allowed"]') rescue nil
                detail_page.wait_for_timeout(500)
              end
              sleep 0.5
              # Default values
              status_text    = nil
              decision_text  = nil
              address_text   = nil
              desc_text      = nil
              type_text      = nil
              date_received  = nil
              date_decision  = nil
              docs_count     = 0

              # === General information table ===
              if detail_page.locator('table[summary="General information"] tbody tr').count > 0
                detail_page.locator('table[summary="General information"] tbody tr').count.times do |j|
                  tr = detail_page.locator('table[summary="General information"] tbody tr').nth(j)
                  field = tr.locator('th').text_content&.strip
                  value = tr.locator('td').text_content&.strip
                  next unless field

                  case field
                  when 'Current status' then status_text = value
                  when 'Decision'       then decision_text = value
                  when 'Type'           then type_text = value
                  when 'Location'       then address_text = value
                  when 'Proposal'       then desc_text = value
                  end
                end
              end

              # === Dates table ===
              if detail_page.locator('table[summary="Application dates"] tbody tr').count > 0
                detail_page.locator('table[summary="Application dates"] tbody tr').count.times do |j|
                  tr = detail_page.locator('table[summary="Application dates"] tbody tr').nth(j)
                  field = tr.locator('th').text_content&.strip
                  value = tr.locator('td').text_content&.strip
                  next unless field && value

                  clean_val = value.sub(/^\w+\s+/, '') # remove weekday

                  case field
                  when 'Date received' then date_received = Date.parse(clean_val) rescue nil
                  end
                end
              end

              # Skip if before our from date
              if date_received && date_received < from
                detail_page.close
                next
              end

              # Supporting Documents
              if detail_page.locator('button.hc-button--toggle:has-text("Supporting Documents")').count > 0
                detail_page.click('button.hc-button--toggle:has-text("Supporting Documents")') rescue nil
                detail_page.wait_for_timeout(300)
                docs_count += detail_page.locator('ul.related li a.hc-master-link').count
              end

              # Drawings
              if detail_page.locator('button.hc-button--toggle:has-text("Drawings")').count > 0
                detail_page.click('button.hc-button--toggle:has-text("Drawings")') rescue nil
                detail_page.wait_for_timeout(300)
                docs_count += detail_page.locator('ul.related li a.hc-master-link').count
              end

              # --- Build Application object ---
              app = Application.new
              app.authority_name    = authority.name
              app.council_reference = ref_text
              app.date_received     = date_received
              app.status            = status_text
              app.decision          = decision_text
              app.info_url          = info_url
              app.address           = address_text
              app.description       = desc_text
              app.documents_count   = docs_count
              app.documents_url     = info_url

              extra_details = { application_type: type_text }

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

              detail_page.close
              sleep 0.5
            end

            browser.close
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
