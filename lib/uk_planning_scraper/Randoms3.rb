# frozen_string_literal: true
require 'mechanize'
require 'date'
require_relative 'playwright_compat'
require_relative 'utils'
require_relative 'application'

DAYS = 7 unless defined?(DAYS)

module UKPlanningScraper
  class Randoms3Scraper

    # ============================================================
    #  ENTRY POINT — Called by Authority#scrape_randoms3
    # ============================================================
    def self.scrape(authority, params = {}, options = {})
      puts "🛠 Running Randoms3Scraper for #{authority.name} (#{authority.url})"

      case authority.name.strip
      when /South Derbyshire/i
        scrape_south_derbyshire(authority, params)
      when /South Oxfordshire/i
        scrape_south_oxfordshire(authority, params)
      when /St Albans/i
        scrape_st_albans(authority, params)
      when /Stratford on Avon/i
        scrape_stratford_on_avon(authority, params)
      when /Tandridge/i
        scrape_tandridge(authority, params)
      when /Telford and Wrekin/i
        scrape_telford_and_wrekin(authority, params)
      when /Tewkesbury/i
        scrape_tewkesbury(authority, params)
      when /Vale of White Horse/i
        scrape_vale_of_white_horse(authority, params)
      when /Walsall/i
        scrape_walsall(authority, params)
      when /Waverley/i
        scrape_waverley(authority, params)
      when /Wealden/i
        scrape_wealden(authority, params)
      when /West Dunbartonshire/i
        scrape_west_dunbartonshire(authority, params)
      when /West Lindsey/i
        scrape_west_lindsey(authority, params)
      when /Wiltshire/i
        scrape_wiltshire(authority, params)
      when /Wokingham/i
        scrape_wokingham(authority, params)

      else
        puts "⚠️ No Randoms3 scraper implementation for #{authority.name}"
        []
      end

    rescue => e
      puts "❌ Randoms3Scraper error for #{authority.name}: #{e.class} - #{e.message}"
      puts e.backtrace.first
      []
    end

    def self.scrape_south_derbyshire(authority, params)
      puts "🔍 Scraping South Derbyshire (randoms3)"

      results = []
      from = params[:validated_from] || params[:received_from] || (Date.today - DAYS)
      to   = params[:validated_to]   || params[:received_to]   || Date.today


      from_str = from.strftime('%d/%m/%Y')
      to_str   = to.strftime('%d/%m/%Y')
      begin
        Timeout.timeout(900) do 
          Playwright.create(playwright_cli_executable_path: Playwright::CLI_EXECUTABLE_PATH) do |playwright|
            browser = playwright.chromium.launch(headless: false)
            page = browser.new_page

            # Go to base URL
            page.goto(authority.url)
            page.wait_for_load_state

            # Accept cookies if present
            if page.locator('button.cookiesBtn__link:has-text("Accept all")').count > 0
              page.click('button.cookiesBtn__link:has-text("Accept all")')
            end

            # Select "Validation Date" for date type
            puts "📅 Selecting 'Validation Date'..."
            page.select_option("select[aria-label='Select a date type']", value: '1') rescue nil

            # Set "Applications Per Page" to 100
            puts "📄 Setting 'Applications Per Page' to 100..."
            page.select_option("select[aria-label='Applications Per Page']", value: '100') rescue nil

            # Convert dd/mm/yyyy from_str/to_str into ISO format for the disabled <input type="date">
            from_iso = Date.strptime(from_str, '%d/%m/%Y').strftime('%Y-%m-%d')
            to_iso   = Date.strptime(to_str, '%d/%m/%Y').strftime('%Y-%m-%d')

            # Fill in date range using JS since inputs are disabled
            page.evaluate("document.querySelector('input[aria-label=\"Enter after date\"]').removeAttribute('disabled')")
            page.evaluate("document.querySelector('input[aria-label=\"Enter after date\"]').value = '#{from_iso}'")

            page.evaluate("document.querySelector('input[aria-label=\"Enter before date\"]').removeAttribute('disabled')")
            page.evaluate("document.querySelector('input[aria-label=\"Enter before date\"]').value = '#{to_iso}'")

            # Wait for results to load
            page.wait_for_selector('div#list-view a.table-row')

            # Scrape all rows (no need for pagination because perPage = 100)
            rows = page.locator('div#list-view a.table-row')
            rows.count.times do |i|
              row = rows.nth(i)

              ref_text      = row.locator('div:nth-child(1)').text_content.strip
              desc_text     = row.locator('div:nth-child(3)').text_content.strip
              address_text  = row.locator('div:nth-child(4)').text_content.strip
              date_reg_text = row.locator('div:nth-child(5)').text_content.strip rescue nil
              status_text   = row.locator('div:nth-child(6)').text_content.strip rescue nil
              info_url      = row.get_attribute('href')

              date_received = Date.parse(date_reg_text) rescue nil

              # --- Build Application object ---
              app = Application.new
              app.authority_name    = authority.name
              app.council_reference = ref_text
              app.date_received     = date_received
              app.status            = status_text
              app.info_url          = info_url
              app.address           = address_text
              app.description       = desc_text
              app.documents_count   = 0
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
                puts "  ⚠️ Skipped invalid application (#{ref_text})"
              end
            end

            browser.close
          end
        end
      end
      results
    end

    def self.scrape_south_oxfordshire(authority, params)
      puts "🔍 Scraping South Oxfordshire"

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

            base_url = authority.url.split('?').first # e.g. "https://data.southoxon.gov.uk/ccm/support/Main.jsp"

            # Go to authority URL
            page.goto(authority.url)
            page.wait_for_load_state

            # --- Select FROM date ---
            begin
              page.select_option('#SDAY', value: from.day.to_s)   if page.locator('#SDAY').count > 0
              page.select_option('#SMONTH', value: from.month.to_s) if page.locator('#SMONTH').count > 0
              page.select_option('#SYEAR', value: from.year.to_s)  if page.locator('#SYEAR').count > 0

              # --- Select TO date ---
              to_date = Date.strptime(to_str, '%d/%m/%Y')
              page.select_option('#EDAY', value: to_date.day.to_s)   if page.locator('#EDAY').count > 0
              page.select_option('#EMONTH', value: to_date.month.to_s) if page.locator('#EMONTH').count > 0
              page.select_option('#EYEAR', value: to_date.year.to_s)  if page.locator('#EYEAR').count > 0
            rescue => e
              puts "⚠️ Selecting dropdown dates failed: #{e.message}"
            end

            puts "📅 Dates selected: #{from_str} → #{to_str}"

            # Submit search
            begin
              page.click('input[type="Submit"][value="Search"]')
              page.wait_for_selector('div.tablediv div.rowdiv', timeout: 30_000)
            rescue => e
              puts "⚠️ Submitting search failed: #{e.message}"
            end

            puts "✅ Search results loaded"

            # --- Scrape results ---
            rows = page.locator('div.tablediv > div.rowdiv').filter(has: page.locator('a'))
            rows.count.times do |i|
              row = rows.nth(i)
              link = row.locator('a')
              next unless link.count > 0

              ref_text = link.text_content.strip
              href = link.get_attribute('href')
              info_url = URI.join(base_url, href).to_s # convert relative URL to absolute

              desc_text    = row.locator('div:nth-child(2) > div:nth-child(2)').text_content.strip rescue nil
              address_text = row.locator('div:nth-child(2) > div:nth-child(1)').text_content.strip rescue nil
              date_reg_text = row.locator('div:nth-child(3) > div').text_content.strip rescue nil
              date_received = Date.parse(date_reg_text) rescue nil

              # Open application details
              page.goto(info_url)
              page.wait_for_selector('div.rowdiv')

              # Determine status from green highlight
              status_text = page.locator('div.rowdiv > div.rightcellcolourdiv[style*="background-color:#92D050"]').text_content.strip rescue nil

              # Scrape description & address from single app page
              desc_page = page.locator('div.rowdiv > div.leftcelldiv:text("Description") + div.rightcelldiv')
              desc_text = desc_page.text_content.strip rescue desc_text

              address_page = page.locator('div.rowdiv > div.leftcelldiv:text("Location") + div.rightcelldiv pre')
              address_text = address_page.text_content.strip rescue address_text

              # Scrape documents
              docs = page.locator('div.rowdiv > div.leftcelldiv:text("Downloads") + div.rightcelldiv ul.tree li a')
              docs_count = docs.count
              docs_urls  = docs.all.map { |d| d.get_attribute('href') }

              # Scrape additional dates
              dates_rows = page.locator('div.rowdiv > div.leftcelldiv:text("Application Progress") + div.rightcelltalldiv div.listrowdiv')
              date_validated = nil
              date_decision = nil

              dates_rows.count.times do |j|
                label = dates_rows.nth(j).locator('div.listcelldiv').first.text_content.strip rescue ''
                value = dates_rows.nth(j).locator('div.listcelldiv').nth(1).text_content.strip rescue nil
                case label
                when /Registration Date/i
                  date_validated = Date.parse(value) rescue nil
                when /Target Decision Date/i
                  date_decision = Date.parse(value) rescue nil
                end
              end

              # --- Build Application object ---
              app = Application.new
              app.authority_name    = authority.name
              app.council_reference = ref_text
              app.date_received     = date_received
              app.status            = status_text
              app.date_decision     = date_decision
              app.info_url          = info_url
              app.address           = address_text
              app.description       = desc_text
              app.documents_count   = docs_count
              app.documents_url     = docs_urls.join(', ')

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

              # Go back to results
              page.go_back
              page.wait_for_selector('div.tablediv div.rowdiv', timeout: 10_000)
            end

            browser.close
          end
        end
      end
      results
    end

    def self.scrape_st_albans(authority, params)
      puts "🔍 Launching headful browser for St Albans..."

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

            page.goto(authority.url)
            page.wait_for_load_state
            sleep 2

            # --- Fill in date range ---
            begin
              page.fill('#view352', from_str) if page.locator('#view352').count > 0
              page.fill('#view353', to_str)   if page.locator('#view353').count > 0
              puts "📅 Dates entered: #{from_str} → #{to_str}"
            rescue => e
              puts "⚠️ Filling St Albans date fields failed: #{e.message}"
            end

            # --- Click Search ---
            begin
              page.click('button.advancedsearchbutton')
              page.wait_for_selector('ul[data-bind*="foreach: KeyObjects"]', timeout: 30_000)
              puts "✅ Search submitted and results loaded for St Albans"
            rescue => e
              puts "⚠️ Clicking St Albans search failed: #{e.message}"
            end

            # --- Scraping with pagination ---
            scraped_total = 0
            total_count = nil

            # Extract total from "Showing 1–10 of 540 Items"
            count_text_el = page.locator('div.civicakeyobjectlistcount')
            if count_text_el.count > 0
              count_text = count_text_el.first.text_content.strip
              if count_text =~ /of\s+(\d+)\s+Items/i
                total_count = $1.to_i
                puts "📊 Total applications available: #{total_count}"
              else
                puts "⚠️ Could not parse total count text: '#{count_text}'"
              end
            else
              puts "⚠️ No total count element found."
            end

            loop do
              rows = page.locator('ul[data-bind*="foreach: KeyObjects"] > li.civica-keyobjectlistitem')
              row_count = rows.count
              puts "📑 Found #{row_count} application rows on this page"

              row_count.times do |i|
                row = rows.nth(i)
                sleep 1

                ref_link = row.locator('a.civica-pbdc-internetdesc')
                council_reference = nil
                info_url = nil
                date_received = nil

                if ref_link.count > 0
                  text = ref_link.first.text_content.strip

                  # Extract reference number
                  council_reference = text[/\b([A-Z]+\/?\d{4}\/?\d+|\bTP\/\d{4}\/\d+)\b/, 1] || text

                  # Extract "Valid From" date
                  if text =~ /Valid\s+From\s+(\d{1,2}\/\d{1,2}\/\d{4})/i
                    date_received = Date.strptime($1, '%d/%m/%Y') rescue nil
                  elsif text =~ /Valid\s+From\s+(\d{1,2}\s+\w+\s+\d{4})/i
                    date_received = Date.parse($1) rescue nil
                  end

                  href = ref_link.first.get_attribute('href')
                  if href && !href.empty?
                    base = authority.url.split('/planning/').first
                    info_url = URI.join(base, href).to_s rescue authority.url
                  else
                    info_url = authority.url
                  end
                end

                # --- Helper for fields ---
                get_field = ->(css_class) do
                  el = row.locator("div.civicadetailtext.#{css_class}")
                  el.count > 0 ? el.first.text_content.strip : nil
                end

                # --- Extract fields directly ---
                address     = get_field.call('civica-pbdc-uprndisplay')
                description = get_field.call('civica-pbdc-proposal')
                if description == '-'
                  description = nil
                end
                status      = get_field.call('civica-pbdc-app_status')
                decision    = get_field.call('civica-pbdc-decision_notice_type')

                # --- Build Application object ---
                app = Application.new
                app.authority_name    = authority.name
                app.council_reference = council_reference
                app.date_received     = date_received
                app.status            = status
                app.decision          = decision
                app.info_url          = info_url || authority.url
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
                  puts "  ⚠️ Skipped invalid application (#{council_reference.inspect})"
                end
              end

              scraped_total += row_count
              puts "📈 Scraped so far: #{scraped_total} / #{total_count || 'unknown'}"

              # --- Stop if we've reached total count ---
              if total_count && scraped_total >= total_count
                puts "✅ All #{scraped_total} applications scraped, stopping pagination."
                break
              end

              # --- Find and check the Next button ---
              next_btns = page.locator('div.btn.secondary-btn')
              next_btn = nil
              next_btns.count.times do |j|
                text = next_btns.nth(j).text_content.strip rescue ""
                if text.downcase.include?("next")
                  next_btn = next_btns.nth(j)
                  break
                end
              end

              if next_btn.nil?
                puts "⛔ No Next button found, stopping pagination."
                break
              end

              classes = next_btn.get_attribute('class').to_s
              if classes.include?('disabled-btn')
                puts "⛔ Next button disabled, no more pages."
                break
              end

              puts "➡️ Moving to next page..."
              first_row_text = rows.first.text_content.strip rescue ""
              next_btn.click
              page.wait_for_timeout(1000)
              page.wait_for_function(
                "(prev) => {
                  const rows = document.querySelectorAll('ul[data-bind*=\"foreach: KeyObjects\"] > li.civica-keyobjectlistitem');
                  if (rows.length === 0) return false;
                  return rows[0].innerText.trim() !== prev;
                }",
                arg: first_row_text
              )
            end


            browser.close
          end
        end
      end
      results
    end
    def self.scrape_stratford_on_avon(authority, params)
      puts "🔍 Launching headful browser for Stratford on Avon..."

      results = []
      from = params[:validated_from] || params[:received_from] || (Date.today - DAYS)
      to   = params[:validated_to]   || params[:received_to]   || Date.today

      from_str = from.strftime('%d/%m/%Y')
      to_str   = to.strftime('%d/%m/%Y')
      begin
        Timeout.timeout(3000) do 
          Playwright.create(playwright_cli_executable_path: Playwright::CLI_EXECUTABLE_PATH) do |playwright|
            browser = playwright.chromium.launch(headless: false)
            page = browser.new_page

            begin
              # Open authority page
              page.goto(authority.url)
              page.wait_for_load_state

              # Close cookie banner if present
              if page.locator('#cookieConsent').count > 0
                begin
                  page.locator('#cookieConsent').first.click if page.locator('#cookieConsent').first.visible?
                  puts "🍪 Cookie banner closed"
                rescue
                end
              end

              # Convert dd/mm/YYYY -> yyyy-mm-dd for <input type="date">
              from_iso = Date.strptime(from_str, '%d/%m/%Y').strftime('%Y-%m-%d') rescue nil
              to_iso   = Date.strptime(to_str,   '%d/%m/%Y').strftime('%Y-%m-%d') rescue nil

              if from_iso
                page.eval_on_selector('#dateApprecFrom',
                  "el => { el.value = '#{from_iso}'; el.dispatchEvent(new Event('input', { bubbles: true })); el.dispatchEvent(new Event('change', { bubbles: true })); }") rescue nil
              end

              if to_iso
                page.eval_on_selector('#dateApprecTo',
                  "el => { el.value = '#{to_iso}'; el.dispatchEvent(new Event('input', { bubbles: true })); el.dispatchEvent(new Event('change', { bubbles: true })); }") rescue nil
              end

              puts "📅 Dates entered (UI shows dd/mm/yyyy): #{from_str} → #{to_str}"

              # Click Search
              begin
                if page.locator('button.btn.btn-lg.btn-primary:has-text("Search")').count > 0
                  page.locator('button.btn.btn-lg.btn-primary:has-text("Search")').first.click
                end
              rescue => e
                puts "⚠️ Clicking Search failed: #{e.message}"
              end

              page.wait_for_load_state

              begin
                page.wait_for_selector('#searchResults .card.SearchResult', timeout: 30_000)
                puts "✅ Search submitted and results loaded for Stratford on Avon"

                loop do
                  rows = page.locator('#searchResults .card.SearchResult')

                  rows.count.times do |i|
                    row = rows.nth(i)

                    council_ref = row.locator('h5.headerStyle').first.text_content.strip rescue nil
                    address     = row.locator('> .card-body > p.card-text').nth(0).text_content.strip rescue nil
                    date_valid_text = row.locator('.col-xs-3.col-md-3 p.card-text').last.text_content.strip rescue nil
                    status_text     = row.locator('.col-xs-4.col-md-3 p.card-text').first.text_content.strip rescue nil
                    proposal_text   = row.locator('.col-xs-5.col-md-6 p.card-text').first.text_content.strip rescue nil

                    # Click into detail
                    begin
                      row.locator('h5.headerStyle').first.click
                    rescue => e
                      puts "⚠️ Failed to click result #{council_ref || "(#{i})"}: #{e.message}"
                      next
                    end

                    # --- Select correct details tab ---
                    details_panel = nil
                    begin
                      if page.locator('button#nav-home-tab').count > 0
                        page.click('button#nav-home-tab')
                        page.wait_for_selector('#nav-home', state: 'visible', timeout: 10_000)
                        details_panel = page.locator('#nav-home')
                      elsif page.locator('button#nav-homem-tab').count > 0
                        page.click('button#nav-homem-tab')
                        page.wait_for_selector('#nav-homem', state: 'visible', timeout: 10_000)
                        details_panel = page.locator('#nav-homem')
                      else
                        raise "No details tab found"
                      end
                    rescue => e
                      puts "⚠️ Details panel not visible for #{council_ref}: #{e.message}"
                      page.go_back rescue nil
                      page.wait_for_selector('#searchResults .card.SearchResult', timeout: 10_000) rescue nil
                      next
                    end

                    # Helper to extract label → p value
                    get_field = ->(label) {
                      begin
                        details_panel.locator("label:has-text('#{label}') + p").first.text_content.strip rescue nil
                      rescue
                        nil
                      end
                    }

                    detail_address  = details_panel.locator('#FormMobAddress').first.text_content.strip rescue nil
                    description     = get_field.call('Proposal') || proposal_text
                    status          = get_field.call('Status') || status_text
                    decision        = get_field.call('Decision')
                  
                    # --- Build Application object (NO DOCUMENTS) ---
                    app = Application.new
                    app.authority_name    = authority.name
                    app.council_reference = council_ref
                    app.date_received     = nil
                    app.status            = status
                    app.decision          = decision
                    app.info_url          = page.url
                    app.address           = detail_address || address
                    app.description       = description || proposal_text
                    app.documents_count   = nil
                    app.documents_url     = nil

                    # Extract date_received from Dates tab
                    begin
                      if page.locator('#nav-dates-tab').count > 0
                        page.click('#nav-dates-tab') rescue nil
                        page.wait_for_timeout(300)
                        rec_txt = page.locator('#nav-dates .civicadetailtext.civica-pbdc-received_date').first.text_content rescue nil
                        app.date_received = Date.strptime(rec_txt, '%d/%m/%Y') rescue nil
                      end
                    rescue
                    end

                    if app.valid?
                      puts "------------------------------------------------------------"
                      puts "  Ref:        #{app.council_reference}"
                      puts "  Address:    #{app.address}"
                      puts "  Description:#{app.description}"
                      puts "  Date:       #{app.date_received}"
                      puts "  Status:     #{app.status}"
                      puts "  Link:       #{app.info_url}"
                      puts "------------------------------------------------------------"
                      results << app
                      puts "  → Added application #{app.council_reference}"
                    else
                      puts "  ⚠️ Skipped invalid application (#{council_ref})"
                    end

                    # Navigate back to results
                    begin
                      page.go_back
                      page.wait_for_selector('#searchResults .card.SearchResult', timeout: 10_000)
                    rescue
                      page.wait_for_selector('#searchResults .card.SearchResult', timeout: 10_000) rescue nil
                    end
                    page.wait_for_timeout(300)
                  end

                  # --- Pagination ---
                  begin
                    next_btns = page.locator('a.page-link')
                    chosen_next = nil

                    (0...next_btns.count).each do |ni|
                      t = next_btns.nth(ni).text_content.to_s.strip.downcase rescue ''
                      if t.include?('next')
                        parent_classes = next_btns.nth(ni).locator('..').get_attribute('class').to_s rescue ''
                        if parent_classes.include?('disabled')
                          puts "⛔ Next button disabled, reached last page."
                          chosen_next = nil
                        else
                          chosen_next = next_btns.nth(ni)
                        end
                        break
                      end
                    end

                    if chosen_next
                      puts "➡️ Moving to next page..."
                      chosen_next.click
                      page.wait_for_selector('#searchResults .card.SearchResult', timeout: 15_000)
                      page.wait_for_timeout(500)
                      next
                    else
                      puts "✅ All applications scraped, no more pages."
                      break
                    end
                  rescue => e
                    puts "⚠️ Pagination error: #{e.class} - #{e.message}; stopping pagination gracefully."
                    break
                  end
                end

              rescue StandardError
                puts "⌛ Timeout waiting for results list - checking if on detail page for single result..."
                if page.locator('button#nav-home-tab').count > 0 || page.locator('button#nav-homem-tab').count > 0
                  puts "✅ Single result detected, scraping detail page directly."
                  # Extract council_ref
                  council_ref = page.locator('h2.headerStyle').text_content.strip rescue nil
                  council_ref ||= get_field.call('Application Reference') rescue nil
                  council_ref ||= get_field.call('Reference') rescue nil

                  if council_ref.nil?
                    puts "⚠️ Could not find council reference on detail page."
                  else
                    # --- Select correct details tab ---
                    details_panel = nil
                    begin
                      if page.locator('button#nav-home-tab').count > 0
                        page.click('button#nav-home-tab')
                        page.wait_for_selector('#nav-home', state: 'visible', timeout: 10_000)
                        details_panel = page.locator('#nav-home')
                      elsif page.locator('button#nav-homem-tab').count > 0
                        page.click('button#nav-homem-tab')
                        page.wait_for_selector('#nav-homem', state: 'visible', timeout: 10_000)
                        details_panel = page.locator('#nav-homem')
                      else
                        raise "No details tab found"
                      end
                    rescue => e
                      puts "⚠️ Details panel not visible for single result: #{e.message}"
                    end

                    if details_panel
                      # Helper to extract label → p value
                      get_field = ->(label) {
                        begin
                          details_panel.locator("label:has-text('#{label}') + p").first.text_content.strip rescue nil
                        rescue
                          nil
                        end
                      }
                      def title_case_address(s)
                        return '' if s.nil? || s.strip.empty?
                        s = s.downcase.strip
                        # Title case after prefixes
                        s = s.gsub(/(^|[\s\-\/\(\)\,\.])([a-z0-9])/i) { |m| $1 + $2.upcase }
                        # Fully uppercase the postcode at the end if it matches UK format
                        s.gsub(/\b([a-z]{1,2}[0-9][a-z0-9]?)\s*([0-9][a-z]{2})\b\z/i) { $1.upcase + ' ' + $2.upcase }
                      end
                      detail_address = get_field.call('Address')
                      description     = get_field.call('Proposal')
                      application_type = get_field.call('Application Type')
                      case_officer    = get_field.call('Case Officer')
                      parish          = get_field.call('Parish')
                      ward            = get_field.call('Ward')
                      status          = get_field.call('Status')
                      decision        = get_field.call('Decision')

                      # Extract date_received from Dates tab
                      date_received = nil
                      begin
                        if page.locator('#nav-dates-tab').count > 0
                          page.click('#nav-dates-tab') rescue nil
                          page.wait_for_timeout(300)
                          rec_txt = page.locator('#nav-dates .civicadetailtext.civica-pbdc-received_date').first.text_content rescue nil
                          date_received = Date.strptime(rec_txt, '%d/%m/%Y') rescue nil
                        end
                      rescue
                      end

                      # --- Build Application object (NO DOCUMENTS) ---
                      app = Application.new
                      app.authority_name    = authority.name
                      app.council_reference = council_ref
                      app.date_received     = date_received
                      app.status            = status
                      app.decision          = decision
                      app.info_url          = page.url
                      app.address           = detail_address
                      app.description       = description
                      app.documents_count   = nil
                      app.documents_url     = nil

                      if app.valid?
                        puts "------------------------------------------------------------"
                        puts "  Ref:        #{app.council_reference}"
                        puts "  Address:    #{app.address}"
                        puts "  Description:#{app.description}"
                        puts "  Date:       #{app.date_received}"
                        puts "  Status:     #{app.status}"
                        puts "  Link:       #{app.info_url}"
                        puts "------------------------------------------------------------"
                        results << app
                        puts "  → Added application #{app.council_reference}"
                      else
                        puts "  ⚠️ Skipped invalid application (#{council_ref})"
                      end
                    end
                  end
                else
                  puts "❌ No results found or unknown page state."
                end
              end

            rescue => e
              puts "❌ Error scraping Stratford on Avon: #{e.class} - #{e.message}"
            ensure
              browser.close rescue nil
            end
          end
        end
      end
      results
    end

    def self.scrape_tandridge(authority, params)
      puts "🔍 Launching headful browser for Tandridge..."

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

            begin
              # Go to authority URL
              page.goto(authority.url)
              page.wait_for_load_state

              # Select "Acknowledged date"
              page.select_option('#MainContent_ddlSearchCriteria', label: 'Acknowledged date')
              puts "✅ Search type set to 'Acknowledged date'"

              # Convert dd/mm/yyyy → yyyy-mm-dd
              from_date = Date.strptime(from_str, '%d/%m/%Y').strftime('%Y-%m-%d')
              to_date   = Date.strptime(to_str,   '%d/%m/%Y').strftime('%Y-%m-%d')

              # Fill date fields (native date inputs)
              page.fill('#MainContent_txtStartDate', from_date)
              page.fill('#MainContent_txtEndDate', to_date)
              puts "📅 Dates entered: #{from_str} → #{to_str} (converted to #{from_date} → #{to_date})"

              # Click search
              page.click('#MainContent_btnSearch')

              # Wait for results table body
              page.wait_for_selector('table#tblSearchResult tbody tr.DataRow', timeout: 30_000)
              puts "✅ Search submitted and results loaded for Tandridge"

              # If there's a length selector, prefer 100 results per page
              if page.locator('select[name="tblSearchResult_length"]').count > 0
                begin
                  page.locator('select[name="tblSearchResult_length"]').select_option(value: '100')
                  page.wait_for_timeout(500)
                rescue
                end
              end

              # --- PAGINATED RESULTS LOOP ---
              loop do
                rows = page.locator('table#tblSearchResult tbody tr.DataRow')
                row_count = rows.count
                puts "📋 Found #{row_count} applications on this page"

                rows.count.times do |i|
                  begin
                    row = rows.nth(i)

                    app_link = row.locator('td a').first
                    next unless app_link && app_link.count > 0

                    ref_text = app_link.text_content&.strip
                    puts "➡️ Opening application #{ref_text}"

                    # Click to open details
                    app_link.click
                    page.wait_for_selector('#MainContent_lblPlanningAppRefText, #MainContent_lblAddressTextValue', timeout: 15_000)

                    # === Scrape details ===
                    council_ref = page.locator('#MainContent_lblPlanningAppRefText').first&.text_content&.strip rescue nil
                    address     = page.locator('#MainContent_lblAddressTextValue').first&.text_content&.strip rescue nil
                    proposal    = page.locator('#MainContent_lblProposalTextValue').first&.text_content&.strip rescue nil

                    validated_txt   = page.locator('#MainContent_lblValidationDateTextValue').first&.text_content&.strip rescue nil
                    validated_date  = Date.parse(validated_txt) rescue nil
                    decision_txt    = page.locator('#MainContent_lblDecisionTextValue').first&.text_content&.strip rescue nil

                    # Documents
                    docs_count = 0
                    docs_url   = nil
                    if page.locator('a#MainContent_btnViewDocs').count > 0
                      docs_href = page.locator('a#MainContent_btnViewDocs').first.get_attribute('href') rescue nil
                      if docs_href
                        docs_page = browser.new_page
                        docs_page.goto(URI.join(page.url, docs_href).to_s)
                        docs_page.wait_for_selector('.civica-doclist, .civica-doclistitem', timeout: 10_000) rescue nil
                        docs_count = docs_page.locator('.civica-doclistitem').count rescue 0
                        docs_url = docs_page.url
                        docs_page.close
                      end
                    end

                    # --- Build Application object ---
                    app = Application.new
                    app.authority_name    = authority.name
                    app.council_reference = council_ref || ref_text
                    app.date_received     = validated_date
                    app.decision          = decision_txt
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
                      puts "  → Added application #{app.council_reference}"
                    else
                      puts "  ⚠️ Skipped invalid application (#{council_ref || ref_text})"
                    end

                    # Go back to results
                    page.go_back
                    page.go_back
                    page.wait_for_selector('table#tblSearchResult tbody tr.DataRow', timeout: 12_000)
                  rescue => row_err
                    puts "❌ Error processing Tandridge row #{i + 1}: #{row_err.class} - #{row_err.message}"
                    next
                  end
                end

                # --- Pagination: click Next if exists and is enabled, otherwise break ---
                begin
                  next_btn = page.locator('a.paginate_button.next').first
                  if next_btn && next_btn.count > 0
                    cls = next_btn.get_attribute('class') rescue ''
                    aria_disabled = next_btn.get_attribute('aria-disabled') rescue nil
                    is_disabled = (cls.to_s.include?('disabled') || aria_disabled == 'true')

                    if is_disabled
                      puts "ℹ️ Next button present but disabled — reached last page."
                      break
                    else
                      puts "➡️ Clicking Next page button..."
                      next_btn.click
                      page.wait_for_selector('table#tblSearchResult tbody tr.DataRow', timeout: 15_000)
                      page.wait_for_timeout(500)
                      next
                    end
                  else
                    puts "ℹ️ No next-page control found — finished pagination."
                    break
                  end
                rescue => pag_e
                  puts "⚠️ Pagination error: #{pag_e.class} - #{pag_e.message}"
                  break
                end
              end
              # --- END PAGINATED RESULTS LOOP ---

            rescue => e
              puts "❌ Error scraping Tandridge: #{e.class} - #{e.message}"
              puts e.backtrace.first
            ensure
              browser.close rescue nil
            end
          end
        end
      end
      results
    end
    def self.scrape_telford_and_wrekin(authority, params)
      puts "🔍 Scraping Telford and Wrekin (randoms3)"

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

            # Go to page
            page.goto(authority.url)
            page.wait_for_load_state

            # from_str and to_str expected in dd/MM/YYYY (as per your top-of-file logic)
            puts "📅 Entering dates: #{from_str} → #{to_str}"

            # helper lambda to pick a date using the jQuery UI datepicker, with a fallback
            pick_date = lambda do |input_selector, date_string|
              day_s, mon_s, year_s = date_string.split('/')
              day = day_s.to_i
              mon_index = mon_s.to_i - 1
              year = year_s.to_i

              begin
                # Click input to open the datepicker
                page.click(input_selector)
                page.wait_for_selector('#ui-datepicker-div', timeout: 5_000)

                # Try month/year selects if available
                begin
                  page.select_option('#ui-datepicker-div .ui-datepicker-month', value: mon_index.to_s)
                  page.select_option('#ui-datepicker-div .ui-datepicker-year', value: year.to_s)
                rescue => _e
                end

                # Click the day cell
                day_locator = page.locator("#ui-datepicker-div td a:has-text(\"#{day}\")")
                if day_locator.count > 0
                  day_locator.nth(0).click
                else
                  page.click("//div[@id='ui-datepicker-div']//a[text()='#{day}']", timeout: 2000) rescue nil
                end
                page.wait_for_timeout(250)
              rescue => e
                # fallback direct set
                safe_val = "%02d/%02d/%04d" % [day, mon_index + 1, year]
                js = <<~JS
                  (function(){
                    var el = document.querySelector("#{input_selector}");
                    if (!el) return false;
                    el.value = "#{safe_val}";
                    el.dispatchEvent(new Event('input', {bubbles: true}));
                    el.dispatchEvent(new Event('change', {bubbles: true}));
                    return true;
                  })();
                JS
                page.evaluate(js)
                page.wait_for_timeout(200)
              end
            end

            # Pick both dates
            pick_date.call('#ctl00_ContentPlaceHolder1_DCdatefrom', from_str)
            pick_date.call('#ctl00_ContentPlaceHolder1_DCdateto',   to_str)

            # Click search button
            page.click('#ctl00_ContentPlaceHolder1_btnSearchPlanningDetails')
            puts "🔎 Submitted search form"

            # Wait for results to load
            begin
              page.wait_for_selector('table#ctl00_ContentPlaceHolder1_gvResults, table.results, table', timeout: 30_000)
              puts "✅ Results appear to have loaded"
            rescue => e
              puts "⚠️ Waiting for results timed out: #{e.message}"
            end

            # ---------------- SCRAPING LOGIC STARTS ----------------
            begin
              # Try to set page size to 100 (if present)
              pg_select = 'select#ctl00_ContentPlaceHolder1_gvResults_ctl01_PageSizeDropDownTop'
              if page.locator(pg_select).count > 0
                page.select_option(pg_select, value: '100')
                page.click('#ctl00_ContentPlaceHolder1_gvResults_ctl01_SelectPageCountTop')
                page.wait_for_timeout(500)
              end
            rescue => e
              puts "⚠️ Could not change page size: #{e.message}"
            end

            total_to_scrape = nil
            processed_count = 0

            loop do
              # Wait for application links
              begin
                page.wait_for_selector('a[href*="pa-applicationsummary.aspx?applicationnumber="]', timeout: 15_000)
              rescue => _
              end

              links_locator = page.locator('a[href*="pa-applicationsummary.aspx?applicationnumber="]')
              link_count = links_locator.count
              puts "Found #{link_count} application links on results page."

              # Set total on first page
              total_to_scrape ||= link_count
              puts "📊 Total to scrape: #{total_to_scrape}, Processed so far: #{processed_count}"

              (0...link_count).each do |i|
                begin
                  link_loc = links_locator.nth(i)
                  href = link_loc.evaluate('el => el.href')
                  ref_text = link_loc.text_content&.strip

                  puts "➡️ Opening #{ref_text} (#{href})"
                  detail_page = context.new_page
                  detail_page.goto(href)
                  detail_page.wait_for_load_state

                  # Wait for the details table
                  begin
                    detail_page.wait_for_selector('tbody tr', timeout: 10_000)
                  rescue
                  end

                  # --- Build Application object ---
                  app = Application.new
                  app.authority_name    = authority.name
                  app.council_reference = nil
                  app.date_received     = nil
                  app.status            = nil
                  app.decision          = nil
                  app.info_url          = href
                  app.address           = nil
                  app.description       = nil
                  app.documents_count   = nil
                  app.documents_url     = nil

                  # Parse main table rows
                  rows = detail_page.locator('tbody tr')
                  rows_count = rows.count
                  (0...rows_count).each do |ridx|
                    row = rows.nth(ridx)
                    key = row.locator('th').all_text_contents&.first&.strip
                    value = row.locator('td').all_text_contents&.first&.strip
                    next if key.nil? || value.nil?

                    case key.downcase
                    when /application number/i
                      app.council_reference = value
                    when /site address/i, /location/i
                      app.address = value
                    when /description of proposal/i, /proposal/i, /^description$/i
                      app.description = value
                    when /^decision$/i
                      app.decision = value.empty? ? nil : value
                    when /current status/i, /^status$/i
                      app.status = value
                    when /application received/i
                      app.date_received = (Date.parse(value) rescue nil)
                    end
                  end

                  # Progress page
                  begin
                    prog_link = detail_page.locator('a[href*="pa-progresstracking-public.aspx"]').first
                    if prog_link && prog_link.count > 0
                      prog_href = prog_link.evaluate('el => el.href')
                      prog_page = context.new_page
                      prog_page.goto(prog_href)
                      prog_page.wait_for_load_state
                      begin
                        app.date_received  ||= (Date.parse(prog_page.locator('#celAppealReceived').text_content.strip) rescue nil)
                      rescue => _e
                      ensure
                        prog_page.close
                      end
                    end
                  rescue => _e
                  end

                  # Documents page
                  begin
                    docs_link = detail_page.locator('a[href*="pa-documents-public.aspx"], a[href*="pa-documents-plans-public.aspx"], a:has-text("Documents")').first
                    docs = []
                    if docs_link && docs_link.count > 0
                      docs_href = docs_link.evaluate('el => el.href')
                      docs_page = context.new_page
                      docs_page.goto(docs_href)
                      docs_page.wait_for_load_state

                      docs_page.locator('#tblPADocuments tbody tr td a').each do |a_loc|
                        begin
                          d_href = a_loc.evaluate('el => el.href')
                          docs << d_href if d_href && d_href.length > 0
                        rescue
                          next
                        end
                      end

                      if docs.empty?
                        docs_page.locator('table#tblPADocuments a').each do |a_loc|
                          begin
                            d_href = a_loc.evaluate('el => el.href')
                            docs << d_href if d_href && d_href.length > 0
                          rescue
                            next
                          end
                        end
                      end

                      app.documents_count = docs.size
                      app.documents_url   = docs.join(' | ') unless docs.empty?
                      docs_page.close
                    end
                  rescue => _e
                  end

                  app.info_url ||= href

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
                    processed_count += 1
                    puts "  → Added application #{app.council_reference} (#{processed_count}/#{total_to_scrape})"
                  else
                    puts "  ⚠️ Skipped invalid application for link #{href}"
                  end

                  detail_page.close
                rescue => e
                  warn "⚠️ Error scraping Telford app link ##{i + 1}: #{e.class} - #{e.message}"
                end
              end

              # --- Check if we've processed all expected apps ---
              if processed_count >= total_to_scrape
                puts "✅ Reached target count of #{total_to_scrape} applications. Stopping."
                break
              end

              # --- Pagination ---
              if link_count < 10
                puts "⛔ Less than 10 applications on this page (#{link_count}), assuming last page."
                break
              end

              next_link = page.locator('#ctl00_ContentPlaceHolder1_gvResults_ctl01_lbPagerTopNext')
              if next_link.count > 0
                begin
                  puts "➡️ Going to next page..."
                  next_link.click
                  page.wait_for_load_state
                  page.wait_for_selector('a[href*="pa-applicationsummary.aspx?applicationnumber="]', timeout: 15_000)
                  page.wait_for_timeout(500)
                rescue => e
                  puts "⚠️ Pagination error: #{e.class} - #{e.message}"
                  break
                end
              else
                puts "✅ No Next link, finished all pages."
                break
              end
            end

            browser.close
          end
        end
      end
      results
    end

    def self.scrape_vale_of_white_horse(authority, params)
      puts "🔍 Scraping Vale of White Horse (randoms3)"

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

            # Go to search page
            page.goto(authority.url)
            page.wait_for_load_state
            puts "✅ Search form loaded"

            # Parse dates
            from_time = (Date.parse(from_str) rescue from || Date.today)
            to_time   = (Date.parse(to_str)   rescue to   || Date.today)

            from_day, from_month, from_year = from_time.day.to_s, from_time.month.to_s, from_time.year.to_s
            to_day,   to_month,   to_year   = to_time.day.to_s,   to_time.month.to_s,   to_time.year.to_s

            puts "📅 Setting FROM date: #{from_day}-#{from_month}-#{from_year}"
            puts "📅 Setting TO   date: #{to_day}-#{to_month}-#{to_year}"

            # helper: try multiple selectors
            try_select = lambda do |selectors, value|
              selectors.each do |sel|
                begin
                  if page.locator(sel).count > 0
                    page.select_option(sel, value: value)
                    page.wait_for_timeout(150)
                    return true
                  end
                rescue
                  next
                end
              end
              false
            end

            # Fill in FROM
            try_select.call(['select[name="SDAY"]',   'select#SDAY',   'select[id="SDAY"]'],   from_day)   || puts("⚠️ Could not set FROM day")
            try_select.call(['select[name="SMONTH"]', 'select#SMONTH', 'select[id="SMONTH"]'], from_month) || puts("⚠️ Could not set FROM month")
            try_select.call(['select[name="SYEAR"]',  'select#SYEAR',  'select[id="SYEAR"]'],  from_year)  || puts("⚠️ Could not set FROM year")

            # Fill in TO
            try_select.call(['select[name="EDAY"]',   'select#EDAY',   'select[id="EDAY"]'],   to_day)   || puts("⚠️ Could not set TO day")
            try_select.call(['select[name="EMONTH"]', 'select#EMONTH', 'select[id="EMONTH"]'], to_month) || puts("⚠️ Could not set TO month")
            try_select.call(['select[name="EYEAR"]',  'select#EYEAR',  'select[id="EYEAR"]'],  to_year)  || puts("⚠️ Could not set TO year")

            # Submit the form
            if page.locator("input[name='Submit'][value*='Search']").count > 0
              puts "🔍 Submitting search via input[name='Submit']"
              page.click("input[name='Submit'][value*='Search']")
            elsif page.locator("button:has-text('Search')").count > 0
              puts "🔍 Submitting search via button:has-text('Search')"
              page.click("button:has-text('Search')")
            elsif page.locator("input[type='submit']").count > 0
              puts "🔍 Submitting search via first input[type='submit']"
              page.click("input[type='submit']")
            else
              raise "❌ Search button not found"
            end

            page.wait_for_load_state
            puts "✅ Results / search page loaded (attempting to scrape links)"

            # wait (for robustness) for at least one results link (but don't crash if none)
            begin
              page.wait_for_selector('div.rowdiv a[href*="MODULE=ApplicationDetails"]', timeout: 10_000)
            rescue
              # continue; we'll attempt to locate links anyway
            end

            links_locator = page.locator('div.rowdiv a[href*="MODULE=ApplicationDetails"]')
            link_count = links_locator.count
            puts "Found #{link_count} application links."

            (0...link_count).each do |i|
              begin
                link_loc = links_locator.nth(i)
                href = link_loc.evaluate('el => el.href') rescue nil
                ref_text = link_loc.text_content&.strip rescue nil
                ref_text ||= "(unknown ref)"

                puts "➡️ Opening #{ref_text} (#{href})"
                detail = context.new_page
                detail.goto(href)
                # wait briefly for detail container(s)
                begin
                  detail.wait_for_selector('div.tablediv, div.tableheader, div.rowdiv', timeout: 6_000)
                rescue
                  # not fatal — some pages take longer or have different structure
                end

                # --- Build Application object ---
                app = Application.new
                app.authority_name       = authority.name
                app.council_reference    = nil
                app.date_received        = nil
                app.status               = nil
                app.decision             = nil
                app.info_url             = href
                app.address              = nil
                app.description          = nil
                app.documents_count      = nil
                app.documents_url        = nil

                # Try header for reference
                if detail.locator('div.tableheader div').count > 0
                  header_text = detail.locator('div.tableheader div').nth(0).text_content(timeout: 500) rescue nil
                  app.council_reference = header_text&.split&.first if header_text && header_text.length > 0
                end
                app.council_reference ||= ref_text

                # --- Generic row parsing ---
                rows = detail.locator('div.rowdiv')
                rows_count = rows.count
                (0...rows_count).each do |ridx|
                  row = rows.nth(ridx)
                  child_count = row.locator('> div').count rescue 0
                  next if child_count < 2

                  key = row.locator('> div').nth(0).text_content(timeout: 300) rescue nil
                  value = row.locator('> div').nth(1).text_content(timeout: 300) rescue nil
                  next if key.nil? || value.nil?

                  key_s = key.gsub(/\s+/, ' ').strip.downcase
                  val_s = value.gsub(/\s+/, ' ').strip

                  case key_s
                  when /description/i
                    app.description ||= val_s
                  when /\blocation\b/i
                    app.address ||= val_s
                  when /^decision$/i
                    app.decision = val_s unless val_s.empty?
                  when /reference|application number/i
                    app.council_reference ||= val_s
                  end
                end

                # --- Application Progress table ---
                progress_rows = detail.locator('div.listrowdiv')
                (0...progress_rows.count).each do |pi|
                  pr = progress_rows.nth(pi)
                  label = pr.locator('div').nth(0).text_content(timeout: 200) rescue nil
                  val   = pr.locator('div').nth(1).text_content(timeout: 200) rescue nil
                  next if label.nil? || val.nil?
                  label_n = label.gsub(/\s+/, ' ').strip.downcase
                  val_n = val.gsub(/(st|nd|rd|th)/i, '').strip

                  case label_n
                  when /date received/i
                    app.date_received ||= (Date.parse(val_n) rescue nil)
                  end
                end

                # --- Documents ---
                docs = []
                docs_locator = detail.locator('a[href*="dynamic_serve.jsp"]')
                (0...docs_locator.count).each do |di|
                  begin
                    a_loc = docs_locator.nth(di)
                    d_href = a_loc.evaluate('el => el.href') rescue nil
                    docs << d_href if d_href && d_href.length > 0
                  rescue
                    next
                  end
                end

                if docs.empty?
                  tree_locator = detail.locator('ul.tree a')
                  (0...tree_locator.count).each do |ti|
                    begin
                      a_loc = tree_locator.nth(ti)
                      d_href = a_loc.evaluate('el => el.href') rescue nil
                      docs << d_href if d_href && d_href.include?('dynamic_serve.jsp')
                    rescue
                      next
                    end
                  end
                end

                app.documents_count = docs.size
                app.documents_url   = docs.join(' | ') unless docs.empty?
                app.info_url       ||= href

                # --- Validate and store ---
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
                  puts "  → Added #{app.council_reference}"
                else
                  puts "  ⚠️ Skipped incomplete application for #{href}"
                end

                detail.close
              rescue => e
                warn "⚠️ Error scraping app link ##{i + 1}: #{e.class} - #{e.message}"
                next
              end
            end

            browser.close
          end
        end
      end
      results
    end
    def self.scrape_walsall(authority, params)
      puts "🔍 Scraping Walsall (randoms3)"

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

            # Go to search page and wait
            page.goto(authority.url)
            page.wait_for_load_state
            puts "✅ Search form loaded"

            # Fill dates (from_str / to_str come from top-of-file logic)
            puts "📅 Entering dates: From #{from_str} → To #{to_str}"
            page.fill("input[name='REGFROMDATE.MAINBODY.WPACIS.1']", from_str) rescue nil
            page.fill("input[name='REGTODATE.MAINBODY.WPACIS.1']", to_str) rescue nil

            # Submit search
            if page.locator("input[name='SEARCHBUTTON.MAINBODY.WPACIS.1'][value*='Search']").count > 0
              puts "🔍 Submitting search form..."
              page.click("input[name='SEARCHBUTTON.MAINBODY.WPACIS.1'][value*='Search']")
              begin
                page.wait_for_selector('table.apas_tbl, table.apas_tbl tbody tr', timeout: 15_000)
              rescue
                # continue regardless
              end
              puts "✅ Search submitted (Walsall)"
            else
              raise "❌ Search button not found"
            end

            # --- PAGINATION LOOP ---
            base_domain = URI(authority.url).scheme + "://" + URI(authority.url).host
            current_page = 1

            loop do
              puts "📄 Scraping page #{current_page}..."

              # Collect all result links
              result_links = page.locator('table.apas_tbl a[href*="WPHAPPDETAIL.DisplayUrl"]')
              link_count = result_links.count
              puts "Found #{link_count} application links on page #{current_page}."

              (0...link_count).each do |idx|
                begin
                  link_loc = result_links.nth(idx)
                  href = link_loc.evaluate('el => el.href') rescue nil
                  ref_text = link_loc.text_content&.strip rescue nil
                  next unless href

                  puts "➡️ Opening #{ref_text} (#{href})"
                  detail = context.new_page
                  detail.goto(href)
                  begin
                    detail.wait_for_selector('fieldset.apas, span#PlanningApplicationReference, .fieldset_divdata', timeout: 10_000)
                  rescue
                    sleep 0.3
                  end

                  # --- Build Application object ---
                  app = Application.new
                  app.authority_name       = authority.name
                  app.council_reference    = nil
                  app.date_received        = nil
                  app.status               = nil
                  app.decision             = nil
                  app.info_url             = href
                  app.address              = nil
                  app.description          = nil
                  app.documents_count      = nil
                  app.documents_url        = nil


                  # helper to get the sibling <p> text after a <span id="...">
                  get_after_text = lambda do |selector|
                    begin
                      if detail.locator(selector).count > 0
                        detail.locator(selector).evaluate(<<~JS)
                          el => {
                            const n = el.nextElementSibling;
                            if (!n) return null;
                            return n.textContent.trim();
                          }
                        JS
                      else
                        nil
                      end
                    rescue
                      nil
                    end
                  end

                  # Extract fields
                  begin
                    cref = get_after_text.call('span#PlanningApplicationReference')
                    app.council_reference = (cref && !cref.empty?) ? cref : (ref_text || nil)

                    desc = get_after_text.call('span#FullDescription')
                    app.description = desc&.gsub(/\s+/, ' ')&.strip if desc

                    addr = get_after_text.call('span#MainLocation')
                    app.address = addr&.gsub(/\s+/, ' ')&.strip if addr

                    stage = get_after_text.call('span#Stage')
                    app.status = stage&.gsub(/\s+/, ' ')&.strip if stage

                    dec_text = get_after_text.call('span#Decision')
                    app.decision = dec_text&.strip unless dec_text.nil? || dec_text.strip.empty?

                    received_alt = get_after_text.call('span#DateReceived') || get_after_text.call('span#ApplicationReceived')
                    if received_alt && !received_alt.strip.empty?
                      r_clean = received_alt.gsub(/(st|nd|rd|th)/i, '')
                      app.date_received = (Date.parse(r_clean) rescue nil)
                    end
                  rescue => e
                    warn "  ⚠️ Partial parse error for #{href}: #{e.class} - #{e.message}"
                  end

                  # --- Documents ---
                  docs = []
                  begin
                    if detail.locator('select[name="tableMedia_length"]').count > 0
                      detail.select_option('select[name="tableMedia_length"]', value: '-1') rescue nil
                      begin
                        detail.wait_for_selector('tbody#tableMediaBody tr', timeout: 3_000)
                      rescue
                      end
                    end

                    if detail.locator('tbody#tableMediaBody a').count > 0
                      ml = detail.locator('tbody#tableMediaBody a')
                      (0...ml.count).each do |mi|
                        a = ml.nth(mi)
                        dh = a.evaluate('el => el.href') rescue nil
                        docs << dh if dh && !dh.to_s.empty?
                      end
                    else
                      candidates = detail.locator('a[href*="WCHDISPLAYMEDIA.showImage"], a[href*="dynamic_serve.jsp"], a[href*="WCHDISPLAYMEDIA"]')
                      (0...candidates.count).each do |ci|
                        a = candidates.nth(ci)
                        dh = a.evaluate('el => el.href') rescue nil
                        docs << dh if dh && !dh.to_s.empty?
                      end
                    end
                  rescue => e
                    warn "  ⚠️ Documents parse error for #{href}: #{e.class} - #{e.message}"
                  end

                  app.documents_count = docs.size
                  app.documents_url   = docs.join(' | ') unless docs.empty?
                  app.info_url       ||= href

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
                    puts "  → Added #{app.council_reference}"
                  else
                    puts "  ⚠️ Skipped incomplete application for #{href}"
                  end

                  detail.close
                rescue => e
                  warn "⚠️ Error scraping Walsall app link ##{idx + 1}: #{e.class} - #{e.message}"
                  next
                end
              end

              # --- PAGINATION HANDLING (Robust for Walsall) ---
              begin
                pagination_html = page.content
                doc = Nokogiri::HTML(pagination_html)

                # Find all pagination <a> links containing "WPHAPPSEARCHRES.displayResultsURL"
                pagelinks = doc.css('a[href*="WPHAPPSEARCHRES.displayResultsURL"]').map { |a| a['href'] }.compact.uniq

                if pagelinks.empty?
                  puts "✅ No pagination links found — finished after page #{current_page}."
                  break
                end

                # Extract the base part of the pagination URL from the first link (usually page 2)
                first_link = pagelinks.first
                base_part = first_link.split('StartIndex=').first
                result_id = base_part[/ResultID=\d+/]
                raise "⚠️ Could not extract ResultID for pagination." unless result_id

                # Get total pages by counting how many distinct StartIndex values exist
                start_indices = pagelinks.map { |h| h[/StartIndex=(\d+)/, 1].to_i }.sort
                if start_indices.empty?
                  puts "✅ Only one page of results."
                  break
                end

                # Start crawling next pages incrementally
                start_indices.each do |start_index|
                  next if start_index <= (current_page * 10) # skip already scraped pages

                  next_link = "#{base_domain}/swift/apas/run/#{base_part}StartIndex=#{start_index}&SortOrder=APNID&DispResultsAs=WPHAPPSEARCHRES"
                  puts "➡️ Navigating to next results page (StartIndex=#{start_index}): #{next_link}"

                  page.goto(next_link)
                  page.wait_for_load_state
                  begin
                    page.wait_for_selector('table.apas_tbl a[href*="WPHAPPDETAIL.DisplayUrl"]', timeout: 10_000)
                    current_page += 1
                    puts "✅ Loaded page #{current_page} successfully."
                  rescue
                    puts "⚠️ Could not confirm page #{current_page + 1} load — stopping pagination."
                    break
                  end

                  # Break out of the loop here and resume scraping the next page
                  break
                end
              rescue => e
                puts "⚠️ Pagination failed at page #{current_page}: #{e.class} - #{e.message}"
                break
              end

            end # end loop

            browser.close
          end
        end
      end
      results
    end
    def self.scrape_waverley(authority, params)
      puts "🔍 Scraping Waverley (randomsX)"

      results = []
      from = params[:validated_from] || params[:received_from] || (Date.today - DAYS)
      to   = params[:validated_to]   || params[:received_to]   || Date.today


      from_str = from.strftime('%d/%m/%Y')
      to_str   = to.strftime('%d/%m/%Y')
      begin
        Timeout.timeout(900) do 
          Playwright.create(playwright_cli_executable_path: Playwright::CLI_EXECUTABLE_PATH) do |playwright|
            browser = playwright.chromium.launch(headless: false)
            page = browser.new_page

            begin
              # Go to the search page
              page.goto(authority.url)
              page.wait_for_load_state

              puts "📅 Entering dates: From #{from_str} → To #{to_str}"
              page.fill('#view623', from_str)
              page.fill('#view624', to_str)

              # Click Search (fires JS)
              puts "🔍 Clicking search button..."
              if page.locator('button.advancedsearchbutton').count > 0
                page.click('button.advancedsearchbutton')
              else
                raise "Search button (button.advancedsearchbutton) not found"
              end

              # Wait for results list
              page.wait_for_selector('.civica-keyobjectlistitem, a.civica-gfplanning-internetdesc', timeout: 30_000)
              puts "✅ Results loaded for Waverley"

              # --- PAGINATED RESULTS LOOP ---
              loop do
                rows = page.locator('a.civica-gfplanning-internetdesc')
                row_count = rows.count
                puts "📑 Found #{row_count} applications on this page"

                (0...row_count).each do |i|
                  begin
                    link = page.locator('a.civica-gfplanning-internetdesc').nth(i)
                    next unless link && link.count > 0

                    ref_text = link.text_content&.strip rescue nil
                    puts "➡️ Opening application ##{i + 1}: #{ref_text || 'Unknown Ref'}"

                    link.click
                    page.wait_for_selector('.civicaaccordionheader, .civica-keyobject-fulldetails', timeout: 15_000)
                    page.wait_for_timeout(250)

                    details_html = page.content
                    doc = Nokogiri::HTML(details_html)

                    council_ref = doc.at_css('.civica-gfplanning-sdescription.civicadetailtext')&.text&.strip
                    address_nodes = doc.css(
                      '.civica-gfplanning-atext1.civicadetailtext',
                      '.civica-gfplanning-atext2.civicadetailtext',
                      '.civica-gfplanning-atext4.civicadetailtext',
                      '.civica-gfplanning-atext6.civicadetailtext'
                    )
                    address = address_nodes.map { |n| n.text.strip }.reject(&:empty?).join(', ')
                    description = doc.at_css('.civica-gfplanning-stext10.civicadetailtext')&.text&.strip
                    status_text = doc.at_css('.civica-gfplanning-spicklist2.civicadetailtext')&.text&.strip

                    # Documents section
                    docs_count = 0
                    docs_url = nil
                    docs_header = page.locator("div.civicaaccordionheader:has-text('Documents')")
                    if docs_header.count > 0
                      begin
                        docs_header.first.click
                        page.wait_for_selector('.civica-doclist, .civica-doclistitem', timeout: 10_000)
                        page.wait_for_timeout(200)
                        docs_html = page.content
                        docs_doc = Nokogiri::HTML(docs_html)
                        documents = docs_doc.css('.civica-doclistitem').map do |d|
                          {
                            title: d.at_css('.civica-doclisttitletext')&.text&.strip,
                            date: d.at_css('.civica-doclistdetailtext')&.text&.strip,
                            link: (d.at_css('a')&.[]('href') && URI.join(authority.url, d.at_css('a')&.[]('href')).to_s)
                          }
                        end
                        docs_count = documents.size
                        docs_url = page.url
                      rescue => doc_e
                        puts "⚠️ Failed to expand/parse documents: #{doc_e.class} - #{doc_e.message}"
                      end
                    else
                      docs_count = doc.css('.civica-doclistitem').size rescue 0
                      docs_url = page.url if docs_count > 0
                    end

                    app = UKPlanningScraper::Application.new
                    app.authority_name    = authority.name
                    app.council_reference = council_ref || ref_text
                    app.date_received     = nil
                    app.status            = status_text
                    app.decision          = nil
                    app.info_url          = page.url
                    app.address           = address
                    app.description       = description || applicant_name || agent_name
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
                      puts " → Added application #{app.council_reference}"
                      begin
                        result_store(authority, app.to_hash) if defined?(result_store)
                      rescue => rs_e
                        puts "⚠️ result_store failed: #{rs_e.class} - #{rs_e.message}"
                      end
                    else
                      puts " ⚠️ Skipped invalid record (#{council_ref || ref_text})"
                    end

                    # Return to results
                    begin
                      page.go_back
                      page.wait_for_selector('a.civica-gfplanning-internetdesc, .civica-keyobjectlistitem', timeout: 20_000)
                      page.wait_for_timeout(250)
                    rescue
                      puts "⚠️ Could not return to results for #{ref_text}"
                    end

                  rescue => app_err
                    puts "❌ Error scraping application ##{i + 1}: #{app_err.class} - #{app_err.message}"
                    puts app_err.backtrace.first
                    begin
                      page.go_back
                      page.wait_for_selector('a.civica-gfplanning-internetdesc, .civica-keyobjectlistitem', timeout: 8_000)
                    rescue
                    end
                    next
                  end
                end

                # --- PAGINATION HANDLER ---
                next_btn = page.locator('div.btn.secondary-btn[data-bind*="onForward"]')
                if next_btn.count > 0 && !next_btn.first.evaluate("el => el.classList.contains('disabled-btn')")
                  puts "➡️ Moving to next results page..."
                  next_btn.first.click
                  page.wait_for_selector('a.civica-gfplanning-internetdesc, .civica-keyobjectlistitem', timeout: 30_000)
                  page.wait_for_timeout(500)
                else
                  puts "✅ No more pages to scrape for Waverley."
                  break
                end
              end

            rescue => e
              puts "❌ Error scraping Waverley: #{e.class} - #{e.message}"
              puts e.backtrace.first
            ensure
              browser.close rescue nil
            end
          end
        end
      end
      results
    end
    def self.scrape_wealden(authority, params)
      puts "🏛️ Launching headful browser for Wealden District Council..."

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

            begin
              # Go to authority URL
              base_url = authority.url
              page.goto(base_url, timeout: 120_000)
              page.wait_for_load_state

              # --- Handle cookie banner ---
              if page.locator('button:has-text("Close")').count > 0
                begin
                  page.click('button:has-text("Close")', timeout: 5_000)
                  puts "🍪 Closed cookie banner"
                rescue
                end
              end

              # --- Accept disclaimer / terms ---
              if page.locator('button:has-text("Agree")').count > 0
                begin
                  page.click('button:has-text("Agree")', timeout: 5_000)
                  page.wait_for_load_state
                  puts "✅ Accepted terms and disclaimer"
                rescue
                end
              end

              # --- Go to Advanced Search tab ---
              if page.locator('a.tab-button:has-text("Advanced")').count > 0
                page.click('a.tab-button:has-text("Advanced")', timeout: 5_000)
                page.wait_for_load_state
                puts "🔍 Opened Advanced Search tab"
              else
                puts "⚠️ Could not locate Advanced Search tab; continuing anyway"
              end

              # --- Uncheck unnecessary boxes (Building Control / Enforcement / TPOs) ---
              begin
                boxes_to_uncheck = [
                  "Building Control",
                  "Enforcement",
                  "Tree Preservation Orders"
                ]

                boxes_to_uncheck.each do |label_text|
                  labels = page.query_selector_all("label.tickbox")
                  target_label = labels.find do |lbl|
                    (lbl.inner_text.strip rescue "").include?(label_text)
                  end

                  if target_label
                    puts "☑️ Attempting to uncheck #{label_text}..."
                    target_label.click rescue nil
                    page.wait_for_timeout(500) # give time for JS to react

                    checkbox = target_label.query_selector("input[type='checkbox']") rescue nil
                    checked = checkbox && page.evaluate("(el) => el.checked", checkbox) rescue false

                    if checked
                      puts "⚠️ #{label_text} still appears checked, retrying..."
                      target_label.click rescue nil
                      page.wait_for_timeout(500)
                      checked = checkbox && page.evaluate("(el) => el.checked", checkbox) rescue false
                      if !checked
                        puts "✅ Successfully unchecked #{label_text} (after retry)"
                      else
                        puts "❌ Failed to uncheck #{label_text}"
                      end
                    else
                      puts "✅ Successfully unchecked #{label_text}"
                    end
                  else
                    puts "⚠️ Could not find label for #{label_text}"
                  end
                end
              rescue => e
                puts "⚠️ Error while unchecking Wealden boxes: #{e.message}"
              end

              # --- Fill Received Date (From only) ---
              from_date_fmt = Date.strptime(from_str, '%d/%m/%Y').strftime('%d/%m/%Y')
              if page.locator('#DateReceivedFrom').count > 0
                input = page.locator('#DateReceivedFrom')
                input.click
                input.fill('')
                input.fill(from_date_fmt)
                puts "📅 Entered From Date: #{from_date_fmt}"
              else
                puts "⚠️ Could not find date input field"
              end
              sleep 1

              # --- Submit search (simulate pressing Enter after form completion) ---
              begin
                puts "⌨️ Preparing to submit form via Enter key..."

                input = page.locator('#DateReceivedFrom')
                input.click
                page.keyboard.press("Enter")
                puts "🔍 Pressed Enter to submit form"

                page.wait_for_load_state("load", timeout: 10_000)
                page.wait_for_selector("table, .results, #SearchResults, #dgSearchResults", timeout: 10_000)
                puts "✅ Search initiated successfully via Enter"
              rescue => e
                puts "❌ Error submitting search via Enter key: #{e.class} - #{e.message}"
              end

              # --- RESULTS + PAGINATION LOOP ---
              loop do
                begin
                  page.wait_for_selector('table.tblResults tbody tr', timeout: 20_000)
                rescue
                  puts "⚠️ No results found, ending scrape"
                  break
                end

                rows = page.locator('table.tblResults tbody tr')
                row_count = rows.count
                puts "📋 Found #{row_count} results on this page"

                rows.count.times do |i|
                  begin
                    row = rows.nth(i)
                    link_el = row.locator('td:nth-child(1) a')
                    next unless link_el && link_el.count > 0

                    app_ref = link_el.text_content.strip rescue nil
                    next if app_ref.nil? || app_ref.empty?
                    puts "➡️ Processing application #{app_ref}"

                    # Open detail page
                    detail_url = URI.join(base_url, link_el.get_attribute('href')).to_s
                    detail_page = context.new_page
                    detail_page.goto(detail_url, timeout: 90_000)
                    detail_page.wait_for_load_state

                    # --- Initialize Application ---
                    app = Application.new
                    app.authority_name    = authority.name
                    app.council_reference = app_ref
                    app.info_url          = detail_url

                    # --- Summary table extraction ---
                    if detail_page.locator('#summarytable').count > 0
                      detail_page.locator('#summarytable tbody tr').all.each do |tr|
                        header = tr.locator('td:nth-child(1)').text_content.strip rescue ''
                        value  = tr.locator('td:nth-child(2)').text_content.strip rescue ''
                        case header
                        when /Application Number/i
                          app.council_reference = value
                        when /Location Address/i
                          app.address = value
                        when /Proposal/i
                          app.description = value
                        when /^Status$/i
                          app.status = value
                        when /Application Type/i
                          # optional
                        when /Decision$/i
                          app.decision = value unless value == 'N/A'
                        end
                      end
                    end

                    # --- Dates table extraction ---
                    if detail_page.locator('#importantdate').count > 0
                      detail_page.locator('#importantdate tbody tr').all.each do |tr|
                        header = tr.locator('td:nth-child(1)').text_content.strip rescue ''
                        value  = tr.locator('td:nth-child(2)').text_content.strip rescue ''
                        case header
                        when /Application Received Date/i
                          app.date_received = Date.parse(value) rescue nil
                        end
                      end
                    end

                    # --- Documents tab ---
                    docs = []
                    if detail_page.locator('a.tab-button:has-text("Documents")').count > 0
                      begin
                        detail_page.click('a.tab-button:has-text("Documents")')
                        detail_page.wait_for_load_state
                        if detail_page.locator('table#documentsdata').count > 0
                          detail_page.locator('table#documentsdata tbody tr.datarow').all.each do |docrow|
                            doc_link = docrow.locator('a[href*="/Document/Download"]').first rescue nil
                            next unless doc_link && doc_link.count > 0
                            href = doc_link.get_attribute('href')
                            text = doc_link.text_content.strip rescue ''
                            docs << { name: text, url: URI.join(base_url, href).to_s } if href
                          end
                        end
                      rescue
                      end
                    end
                    app.documents_count = docs.count
                    app.documents_url   = detail_page.url unless docs.empty?

                    detail_page.close

                    # --- Validate and store ---
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
                      puts "  ⚠️ Skipped invalid application (#{app_ref})"
                    end

                  rescue => row_err
                    puts "❌ Error processing row #{i + 1}: #{row_err.class} - #{row_err.message}"
                    next
                  end
                end

                # --- Pagination ---
                if page.locator('a[aria-label="Next Page."]').count > 0
                  next_button = page.locator('a[aria-label="Next Page."]').first

                  if next_button && next_button.visible?
                    puts "➡️ Moving to next page via click..."
                    begin
                      next_button.click(timeout: 10_000)
                      puts "⏳ Waiting for next page to load..."
                      page.wait_for_load_state
                      page.wait_for_selector("#application_results_table, table.tblResults", timeout: 15_000)
                      page.wait_for_timeout(1000)
                      puts "✅ Next page loaded successfully"
                      next
                    rescue => e
                      puts "⚠️ Error clicking Next button: #{e.message}"
                      break
                    end
                  else
                    puts "⚠️ Next button not visible or missing."
                    break
                  end
                else
                  puts "✅ No more pages."
                  break
                end
              end

              puts "🏁 Completed Wealden scrape: #{results.count} applications total"

            rescue => e
              puts "❌ Error scraping Wealden: #{e.class} - #{e.message}"
              puts e.backtrace.first
            ensure
              browser.close rescue nil
            end
          end
        end
      end
      results
    end
    def self.scrape_west_dunbartonshire(authority, params)
      puts "🌊 Scraping West Dunbartonshire (randoms2)"

      results = []
      from = params[:validated_from] || params[:received_from] || (Date.today - DAYS)
      to   = params[:validated_to]   || params[:received_to]   || Date.today


      from_str = from.strftime('%d/%m/%Y')
      to_str   = to.strftime('%d/%m/%Y')
      begin
        Timeout.timeout(900) do 
          Playwright.create(playwright_cli_executable_path: Playwright::CLI_EXECUTABLE_PATH) do |playwright|
            browser = playwright.chromium.launch(headless: false)
            page = browser.new_page

            begin
              # Go to search page
              page.goto(authority.url)
              page.wait_for_load_state

              puts "📝 Setting decision/received date range: #{from_str} → #{to_str}"

              # === Fill date inputs (try multiple selectors) ===
              filled_from = false
              filled_to   = false

              begin
                if page.locator('input[name="vDateRcvFr"]').count > 0
                  page.fill('input[name="vDateRcvFr"]', from_str)
                  filled_from = true
                end
              rescue; end

              begin
                if page.locator('input[name="vDateRcvTo"]').count > 0
                  page.fill('input[name="vDateRcvTo"]', to_str)
                  filled_to = true
                end
              rescue; end

              # Fallback selectors
              begin
                page.locator('input[title*="DateRcvFr"]').first.fill(from_str) if !filled_from && page.locator('input[title*="DateRcvFr"]').count > 0
                filled_from = true if !filled_from && page.locator('input[title*="DateRcvFr"]').count > 0
              rescue; end
              begin
                page.locator('input[title*="DateRcvTo"]').first.fill(to_str) if !filled_to && page.locator('input[title*="DateRcvTo"]').count > 0
                filled_to = true if !filled_to && page.locator('input[title*="DateRcvTo"]').count > 0
              rescue; end

              # Last fallback: use visible text fields
              if !(filled_from && filled_to)
                text_inputs = page.locator('input[type="text"]:visible')
                if text_inputs.count >= 2
                  text_inputs.nth(0).fill(from_str) unless filled_from
                  text_inputs.nth(1).fill(to_str) unless filled_to
                  filled_from = filled_to = true
                end
              end

              puts "✔️ Date inputs filled (from=#{filled_from}, to=#{filled_to})"

              # === Submit search ===
              if page.locator('input#Submit2').count > 0
                page.click('input#Submit2')
              elsif page.locator('input[name="Submit2"]').count > 0
                page.click('input[name="Submit2"]')
              elsif page.locator('input[type="submit"][value="Search"]').count > 0
                page.click('input[type="submit"][value="Search"]')
              else
                page.locator('div.document input[type="submit"]:visible').first.click rescue (raise "❌ Could not find Search/Submit button on West Dunbartonshire page")
              end

              sleep 3
              page.wait_for_selector('div.document table', timeout: 20_000)
              page.wait_for_timeout(300)

              tables = page.locator('div.document table')
              table_count = tables.count
              puts "📋 Found #{table_count} result table(s)"

              (0...table_count).each do |ti|
                begin
                  table = page.locator('div.document table').nth(ti)
                  detail_url = nil

                  if table.locator('form').count > 0
                    form = table.locator('form').first
                    action = form.get_attribute('action') || ''
                    params = {}
                    hidden_inputs = form.locator('input[type="hidden"]')
                    hidden_inputs.count.times do |hi|
                      inp = hidden_inputs.nth(hi)
                      name = inp.get_attribute('name') rescue nil
                      val  = inp.get_attribute('value') rescue nil
                      params[name] = val if name
                    end
                    if params.empty? && form.locator('input[name="vUPRN"]').count > 0
                      params['vUPRN'] = form.locator('input[name="vUPRN"]').first.get_attribute('value') rescue nil
                    end
                    if action && !action.empty?
                      base = action.start_with?('http') ? action : URI.join(authority.url, action).to_s
                      query = params.empty? ? "" : URI.encode_www_form(params)
                      detail_url = base.include?('?') ? "#{base}&#{query}" : "#{base}?#{query}"
                    end
                  end

                  table_text = table.text_content&.strip
                  app_ref = table_text[/\b[A-Z]{1,3}\d{2}\/\d{1,4}(?:\/[A-Z0-9]+)?\b/] if table_text

                  puts "➡️ Processing result #{ti + 1}/#{table_count} #{app_ref || ''}"

                  # === Open detail page ===
                  detail_page = nil
                  if detail_url
                    detail_page = browser.new_page
                    detail_page.goto(detail_url)
                    detail_page.wait_for_selector('#Table4, table#Table4', timeout: 15_000)
                  else
                    if table.locator('input[type="submit"][value="View"]').count > 0
                      table.locator('input[type="submit"][value="View"]').first.click
                      page.wait_for_selector('#Table4, table#Table4', timeout: 15_000)
                      detail_page = page
                    else
                      puts "⚠️ No detail link/form found for this table, skipping"
                      next
                    end
                  end

                  # === Scrape details table ===
                  details = {}
                  tbl = detail_page.locator('table#Table4, #Table4')
                  tbl = detail_page.locator('table').first if tbl.count == 0
                  if tbl && tbl.count > 0
                    rows = tbl.locator('tr')
                    rows.count.times do |r|
                      label_el = rows.nth(r).locator('td').first
                      value_el = rows.nth(r).locator('td').nth(1)
                      next unless label_el
                      label = label_el.text_content&.strip&.gsub(/\s+/, ' ')
                      val   = value_el&.text_content&.strip&.gsub(/\u00A0/, ' ')
                      details[label] = val
                    end
                  end

                  find_value = lambda do |needle|
                    pair = details.find { |k, _| k.to_s.downcase.include?(needle.downcase) }
                    pair && pair.last && pair.last.strip.length > 0 ? pair.last.strip : nil
                  end

                  council_ref    = find_value.call('Reference Number') || app_ref
                  address_block = nil
                  proposal_text = nil
                  details.each do |label, value|
                    cleaned_label = label.downcase.strip

                    # Address block – ONLY match "address of proposal"
                    if cleaned_label == 'address of proposal:' || cleaned_label.include?('address of proposal')
                      address_block = value
                    end

                    # Proposal – ONLY match the field EXACTLY named "proposal"
                    # and NOT "address of proposal"
                    if cleaned_label == 'proposal:' || cleaned_label == 'proposal'
                      proposal_text = value
                    end
                  end
                  status_text    = find_value.call('Status')
                  decision_text  = find_value.call('Decision')
                  received_txt   = find_value.call('Date Received')
                  date_received  = Date.parse(received_txt) rescue nil

                  # === Documents ===
                  docs_count = 0
                  docs_url = nil
                  if detail_page.locator('a:has-text("View Associated Documents"), a[title*="Documents"]').count > 0
                    docs_href = detail_page.locator('a:has-text("View Associated Documents"), a[title*="Documents"]').first.get_attribute('href') rescue nil
                    if docs_href
                      docs_page = browser.new_page
                      docs_page.goto(URI.join(detail_page.url, docs_href).to_s)
                      begin
                        docs_page.wait_for_selector('.civica-doclist .civica-doclistitem, .civica-doclistitem', timeout: 8_000)
                      rescue; end
                      docs_count = docs_page.locator('.civica-doclist .civica-doclistitem').count rescue 0
                      docs_count = docs_page.locator('.civica-doclistitem').count if docs_count == 0 rescue docs_count
                      docs_url = docs_page.url
                      docs_page.close
                    end
                  end

                  # === Build Application ===
                  app = Application.new
                  app.authority_name    = authority.name
                  app.council_reference = council_ref
                  app.date_received     = date_received
                  app.status            = status_text
                  app.decision          = decision_text
                  app.info_url          = detail_page.url
                  app.address           = address_block
                  app.description       = proposal_text
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
                    puts "  ⚠️ Skipped invalid application (#{council_ref || app_ref})"
                  end

                  # Close detail page if new
                  if detail_page && detail_page != page
                    detail_page.close rescue nil
                  else
                    page.go_back rescue nil
                    page.wait_for_selector('div.document table', timeout: 10_000) rescue nil
                  end

                  page.wait_for_timeout(250)

                rescue => app_err
                  puts "❌ Error processing West Dunbartonshire result #{ti + 1}: #{app_err.class} - #{app_err.message}"
                  puts app_err.backtrace.first
                  begin
                    page.goto(authority.url)
                    page.wait_for_load_state
                    page.fill('input[name="vDateRcvFr"]', from_str) rescue nil
                    page.fill('input[name="vDateRcvTo"]', to_str) rescue nil
                    page.locator('input#Submit2').first.click rescue nil
                    page.wait_for_selector('div.document table', timeout: 10_000)
                  rescue; end
                  next
                end
              end

            rescue => e
              puts "❌ Error scraping West Dunbartonshire: #{e.class} - #{e.message}"
              puts e.backtrace.first
            ensure
              browser.close rescue nil
            end
          end
        end
      end
      results
    end
    def self.scrape_west_lindsey(authority, params)
      puts "🔍 Scraping West Lindsey"

      results = []

      from = params[:validated_from] || params[:received_from] || (Date.today - DAYS)
      to   = params[:validated_to]   || params[:received_to]   || Date.today


      from_str = from.strftime('%d/%m/%Y')
      to_str   = to.strftime('%d/%m/%Y')
      base_url = "https://westlindsey-publicportal.statmap.co.uk"
      begin
        Timeout.timeout(900) do 
          Playwright.create(playwright_cli_executable_path: Playwright::CLI_EXECUTABLE_PATH) do |playwright|
            browser = playwright.chromium.launch(headless: false)
            page = browser.new_page

            # Go to base URL
            page.goto(authority.url)
            page.wait_for_load_state

            # Accept cookies if button is there
            if page.locator('button:has-text("Accept additional cookies")').count > 0
              page.click('button:has-text("Accept additional cookies")')
            end

            # Open Planning Applications tab
            page.click('button:has-text("Planning Applications")')

            # Switch to Advanced tab
            page.click('button:has-text("Advanced")')

            # Enter FROM date
            page.click('#app-Received-Deadline-From')
            page.keyboard.press('Control+A')
            page.keyboard.press('Backspace')
            page.keyboard.type(from_str)

            # Enter TO date
            page.click('#app-Received-Deadline-To')
            page.keyboard.press('Control+A')
            page.keyboard.press('Backspace')
            page.keyboard.type(to_str)

            puts "📅 Dates entered: #{from_str} → #{to_str}"

            # Click the SECOND "Search" button
            search_buttons = page.locator('button:has-text("Search")')
            if search_buttons.count >= 2
              puts "🔍 Clicking the second Search button..."
              search_buttons.nth(1).click
            else
              raise "❌ Could not find the second Search button"
            end

            # Wait for results
            page.wait_for_selector('div.MuiDataGrid-row')

            page_index = 1
            loop do
              puts "📄 Scraping results page #{page_index}"

              rows = page.locator('div.MuiDataGrid-row')
              row_count = rows.count

              rows.count.times do |i|
                row = rows.nth(i)

                ref_link = row.locator('a.entityTable__linkCell')
                next unless ref_link.count > 0

                ref_text    = ref_link.text_content&.strip
                detail_url  = ref_link.get_attribute('href')
                addr_text   = row.locator('div[data-field="address"]')&.text_content&.strip
                desc_text   = row.locator('div[data-field="proposal"]')&.text_content&.strip
                rec_text    = row.locator('div[data-field="receivedDate"]')&.text_content&.strip
                status_text = row.locator('div[data-field="status"]')&.text_content&.strip
                dec_text    = row.locator('div[data-field="decision"]')&.text_content&.strip

                date_received = Date.parse(rec_text) rescue nil
                full_url = base_url + detail_url

                # Open details in a new page
                detail_page = browser.new_page
                detail_page.goto(full_url)
                detail_page.wait_for_load_state

                # Accept cookies again if present
                if detail_page.locator('button:has-text("Accept additional cookies")').count > 0
                  detail_page.click('button:has-text("Accept additional cookies")')
                end

                # Collect additional details
                details_map = {}
                detail_page.locator('.mirageFormControl__inputContainer').all.each do |field|
                  label = field.locator('label')&.text_content&.strip
                  value = field.locator('span')&.text_content&.strip
                  details_map[label] = value if label && value
                end

                # Documents
                docs_count = 0
                if detail_page.locator('button:has-text("Documents")').count > 0
                  detail_page.click('button:has-text("Documents")')
                  detail_page.wait_for_selector('div.MuiDataGrid-row', timeout: 5000) rescue nil
                  docs_count = detail_page.locator('div.MuiDataGrid-row').count rescue 0
                end

                # --- Build Application object ---
                app = Application.new
                app.authority_name    = authority.name
                app.council_reference = ref_text
                app.date_received     = date_received
                app.status            = status_text
                app.decision          = dec_text
                app.info_url          = full_url
                app.address           = addr_text
                app.description       = desc_text
                app.documents_count   = docs_count
                app.documents_url     = authority.url

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
              end

              # Pagination
              next_button = page.locator('button[aria-label="next"]')
              if next_button.count > 0 && next_button.get_attribute('disabled').nil?
                next_button.click
                page.wait_for_selector('div.MuiDataGrid-row')
                page.wait_for_timeout(500)
                page_index += 1
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
    def self.scrape_wiltshire(authority, params)
      puts "🌿 Launching headful browser for Wiltshire..."

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

            begin
              # Go to search page
              page.goto(authority.url)
              page.wait_for_load_state
              puts "✅ Loaded Wiltshire planning search page"

              # Enter date range
              page.fill('input[id="650:0"]', from_str)
              page.fill('input[id="666:0"]', to_str)
              puts "📅 Date entered: #{from_str} → #{to_str}"

              # Click "Search Details"
              begin
                btn = page.locator('button:has-text("Search Details")').first
                btn.click(timeout: 10_000)
                puts "🔍 Search submitted"
              rescue => e
                puts "❌ Cannot click Search button: #{e.message}"
              end

              # Results
              page.wait_for_selector('tbody tr.slds-hint-parent', timeout: 30_000)
              puts "✅ Results table loaded"

              # PAGINATION LOOP
              loop do
                rows = page.locator('tbody tr.slds-hint-parent')
                row_count = rows.count
                puts "📋 #{row_count} applications on this page"

                row_count.times do |i|
                  begin
                    row = rows.nth(i)
                    ref_link = row.locator('td a.slds-show.slds-truncate.uiOutputURL')
                    next unless ref_link && ref_link.count > 0

                    ref_text  = ref_link.text_content&.strip
                    desc      = row.locator('td:nth-child(3) span').text_content&.strip rescue nil
                    date_recv = row.locator('td:nth-child(4) span').text_content&.strip rescue nil
                    status    = row.locator('td:nth-child(7) span').text_content&.strip rescue nil

                    puts "➡️ Opening #{ref_text}"

                    href = ref_link.get_attribute('href')
                    next unless href
                    detail_url = URI.join(page.url, href).to_s

                    detail_page = browser.new_page
                    detail_page.goto(detail_url)
                    detail_page.wait_for_load_state

                    # ====== SCRAPE DETAILS FROM THE DETAIL PAGE ======

                    # Council Reference
                    council_ref = detail_page
                      .locator('span.test-id__field-value lightning-formatted-text')
                      .nth(0)
                      &.text_content&.strip rescue ref_text

                    # Valid Date
                    valid_date_txt = detail_page
                      .locator('records-record-layout-item[field-label="Valid Date"] lightning-formatted-text')
                      &.text_content&.strip rescue nil

                    valid_date = Date.strptime(valid_date_txt, '%d/%m/%Y') rescue nil

                    # ====== CORRECT SITE ADDRESS SCRAPING ======
                    site_address = nil

                    detail_rows = detail_page.locator('div.slds-form-element')
                    detail_rows.count.times do |ri|
                      label_text = detail_rows.nth(ri).locator('span.slds-form-element__label').text_content&.strip rescue nil
                      next unless label_text&.downcase == "site address"

                      site_address = detail_rows.nth(ri)
                                        .locator('span.slds-output.slds-form-element__static.uiOutputText')
                                        .text_content&.strip rescue nil
                      break
                    end
                    detail_rows = detail_page.locator('div.slds-form-element')
                    detail_rows.count.times do |ri|
                      label_text = detail_rows.nth(ri).locator('span.slds-form-element__label').text_content&.strip rescue nil
                      next unless label_text&.downcase == "proposal"

                      desc = detail_rows.nth(ri)
                                        .locator('span.slds-output.slds-form-element__static.uiOutputText')
                                        .text_content&.strip rescue nil
                      break
                    end

                    # ====== Build Application ======
                    app = Application.new
                    app.authority_name    = authority.name
                    app.council_reference = council_ref
                    app.date_received     = valid_date
                    app.status            = status
                    app.info_url          = detail_url
                    app.address           = site_address   # <–––––––– REAL ADDRESS HERE
                    app.description       = desc
                    app.documents_count   = nil
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
                    else
                      puts "⚠️ Skipped invalid application (#{council_ref || ref_text})"
                    end

                    detail_page.close

                  rescue => row_err
                    puts "❌ Wiltshire row error #{i+1}: #{row_err.class} - #{row_err.message}"
                    next
                  end
                end

                # PAGINATION
                begin
                  next_btn = page.locator('button.slds-button:has-text("Next")').first
                  if next_btn && next_btn.count > 0 &&
                    !next_btn.get_attribute('disabled') &&
                    next_btn.get_attribute('aria-disabled') != 'true'

                    puts "➡️ Next page…"
                    next_btn.click(timeout: 10_000)
                    page.wait_for_selector('tbody tr.slds-hint-parent', timeout: 20_000)
                    page.wait_for_timeout(1000)
                    next
                  else
                    puts "📘 Finished pagination"
                    break
                  end
                rescue
                  puts "⚠️ Pagination issue — stopping"
                  break
                end
              end

            rescue => e
              puts "❌ Wiltshire scrape error: #{e.class} - #{e.message}"
              puts e.backtrace.first
            ensure
              browser.close rescue nil
            end
          end
        end
      end
      results
    end

    def self.scrape_wokingham(authority, params)
      puts "🔍 Scraping Wokingham (FastWeb)"

      results = []

      from = params[:validated_from] || params[:received_from] || (Date.today - DAYS)
      to   = params[:validated_to]   || params[:received_to]   || Date.today


      from_str = from.strftime('%d/%m/%Y')
      to_str   = to.strftime('%d/%m/%Y')
      begin
        Timeout.timeout(900) do 
          Playwright.create(playwright_cli_executable_path: Playwright::CLI_EXECUTABLE_PATH) do |playwright|
            browser = playwright.chromium.launch(headless: false)
            page = browser.new_page

            # Go to base URL
            page.goto(authority.url)
            page.wait_for_load_state
            puts "✅ Loaded Wokingham FastWeb search page"

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

                  # Open details page
                  page.goto(app_url)
                  page.wait_for_load_state
                  page.wait_for_selector('table.details-table', timeout: 10_000)

                  # --- SCRAPE DETAILS ---
                  details = {}
                  Nokogiri::HTML(page.content).css('table.details-table tr').each do |tr|
                    th = tr.at_css('th.RecordTitle')&.text&.strip&.gsub(/\s+/, ' ')
                    td = tr.at_css('td.RecordDetail')&.text&.strip&.gsub(/\s+/, ' ')
                    next unless th && td && !th.empty?
                    details[th.downcase] = td
                  end

                  council_ref = details['planning application number:'] || details['planning application number'] || ref_text
                  address     = details['site address:'] || details['site address']
                  description = details['description:'] || details['description']
                  status      = details['application status:'] || details['application status']
                  date_recv   = (Date.parse(details['date received:'] || details['date received']) rescue nil)
                  decision    = details['decision type:'] || details['decision type']

                  # --- DOCUMENTS (FastWeb robust) ---
                  docs_count = 0
                  docs_url = nil
                  begin
                    doc_link_locator = page.locator('a:has-text("Documents"), a:has-text("Plans")')
                    if doc_link_locator.count == 0
                      puts "ℹ️ No documents/plans link found on detail page."
                    else
                      link = doc_link_locator.first
                      href = link.get_attribute('href')&.to_s&.strip

                      if href && href != '' && href != '#' && !href.start_with?('javascript:')
                        begin
                          docs_url = URI.join(page.url, href).to_s rescue href
                        rescue => uri_err
                          docs_url = href
                        end

                        puts "📎 Opening documents page: #{docs_url}"
                        docs_page = browser.new_page
                        begin
                          docs_page.goto(docs_url)
                          docs_page.wait_for_selector('#searchResult, #searchResult_info, #searchResult_wrapper', timeout: 10_000) rescue nil

                          info_text = (docs_page.locator('#searchResult_info').inner_text rescue '') || ''
                          if info_text =~ /of\s+(\d+)\s+entries/i
                            docs_count = $1.to_i
                            puts "ℹ️ Extracted docs count from info text: #{docs_count}"
                          else
                            row_count = docs_page.locator('#searchResult tbody tr').count rescue 0
                            docs_count = row_count if row_count > 0
                            puts "ℹ️ Counted docs rows: #{docs_count}" if docs_count > 0
                          end
                        ensure
                          docs_page.close rescue nil
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

                  # --- BUILD Application object ---
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

                  # Return to results
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