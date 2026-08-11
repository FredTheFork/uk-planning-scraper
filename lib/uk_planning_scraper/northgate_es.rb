# frozen_string_literal: true
require_relative 'playwright_compat'
require 'date'
require 'time'
require 'uri'
require 'set'
require 'timeout'                    # ← added for the 15-minute timeout

#ENV['PLAYWRIGHT_BROWSERS_PATH'] = File.expand_path('../playwright-browsers', __dir__)

module UKPlanningScraper
  class NorthgateESScraper
    def initialize(authority, params, options)
      @authority = authority
      @params = params
      @options = options
    end

    def scrape
      puts "Getting: #{@authority.url}"

      from_date = @params[:received_from]&.strftime('%d/%m/%Y') || (Date.today - DAYS).strftime('%d/%m/%Y')
      to_date   = @params[:received_to]&.strftime('%d/%m/%Y') || Date.today.strftime('%d/%m/%Y')
      puts "From: #{from_date} To: #{to_date}"

      apps = []
      seen_refs = Set.new

      begin
        Timeout.timeout(900) do   # 15 minutes = 900 seconds
          Playwright.create(playwright_cli_executable_path: 'npx playwright') do |playwright|
            browser = playwright.chromium.launch(headless: false)
            context = browser.new_context
            page = context.new_page

            # --- Load main search page ---
            page.goto(@authority.url, timeout: 60_000)

            # --- Open Advanced Search if needed ---
            if (btn = page.query_selector('button[data-get-url*="AdvanceSearch"]'))
              btn.click
              page.wait_for_selector('#AdvanceSearch_ReceivedToDate', timeout: 10_000)
            end

            # --- Fill Search Form ---
            if page.query_selector('input#AdvanceSearch_ReceivedFromDate')
              page.check('#AdvanceSearch_ReceivedBetween', force: true) rescue nil
              page.fill('#AdvanceSearch_ReceivedFromDate', from_date) rescue nil
              page.fill('#AdvanceSearch_ReceivedToDate', to_date) rescue nil

              if @params[:keywords]
                if page.query_selector('#AdvanceSearch_OneOfTheseWords')
                  page.check('input[name="AdvanceSearchWordSearch"][value="OneOfTheseWords"]', force: true) rescue nil
                  page.fill('#AdvanceSearch_OneOfTheseWords', @params[:keywords]) rescue nil
                elsif page.query_selector('#AdvanceSearch_AllOfTheseWords')
                  page.check('input[name="AdvanceSearchWordSearch"][value="AllOfTheseWords"]', force: true) rescue nil
                  page.fill('#AdvanceSearch_AllOfTheseWords', @params[:keywords]) rescue nil
                end
              end

              if (button = page.query_selector('button.btn.btn-primary[onclick*="SubmitAdvanceForm"]'))
                button.click
              else
                puts "⚠️ Submit button not found."
                File.write("debug_output.html", page.content)
                return []
              end
            else
              puts "⚠️ Advanced search form not found."
              File.write("debug_output.html", page.content)
              return []
            end

            # --- Wait for results ---
            begin
              page.wait_for_selector('#divOnlinePlanningSearchResults', timeout: 30_000)
            rescue StandardError
              puts "⚠️ Timeout waiting for results container."
              File.write("debug_output.html", page.content)
              context.close
              browser.close
              return []
            end

            page.wait_for_timeout(2000)

            # --- PAGINATION LOOP ---
            loop do
              visited_refs_before = seen_refs.size
              results_container = page.query_selector('#divOnlinePlanningSearchResults')
              links = results_container.query_selector_all('a[href*="OnlinePlanningOverview"]') rescue []

              puts "Found #{links.size / 4} applications on current page."

              links.each do |link|
                href = link.get_attribute('href')
                next unless href
                full_url = URI.join(@authority.url, href).to_s
                ref = href[/applicationNumber=([^&]+)/, 1]
                next if ref.nil? || seen_refs.include?(ref)

                # --- Build Application Object ---
                app = Application.new
                app.authority_name = @authority.name
                app.council_reference = ref
                app.info_url = full_url

                # --- DETAIL PAGE SCRAPE ---
                begin
                  detail_page = context.new_page
                  detail_page.goto(full_url, timeout: 60_000)

                  # Wait for core detail block
                  detail_page.wait_for_selector('label#applicationDisplayAddress, div.row.btspace.tpspace', timeout: 15_000)

                  # --- Extract Address ---
                  address_el = detail_page.query_selector('label#applicationDisplayAddress')
                  app.address = address_el&.inner_text&.strip

                  # --- Extract Description (2nd col-xs-12 label) ---
                  label_blocks = detail_page.query_selector_all('div.row.btspace.tpspace div.col-xs-12 label')
                  if label_blocks && label_blocks.size >= 2
                    app.description = label_blocks[2].inner_text.strip rescue nil
                  end

                  # --- Extract Date (Timeline table - right column) ---
                  date_label = detail_page.query_selector('div.divTimeLine table.boxBorderLightGrey tr:nth-of-type(1) td:nth-of-type(2) label')
                  if date_label
                    raw_date = date_label.inner_text.strip
                    app.date_received = Date.parse(raw_date) rescue nil
                  end

                  detail_page.close
                rescue StandardError
                  puts "⚠️ Timeout loading details for #{ref}"
                  detail_page.close rescue nil
                rescue => e
                  puts "⚠️ Error scraping detail for #{ref}: #{e.class} - #{e.message}"
                  detail_page.close rescue nil
                end

                # --- Add app to list if valid ---
                if app.valid?
                  apps << app
                  seen_refs << ref
                  puts "✅ Added #{app.council_reference}"
                  puts "   Address: #{app.address}"
                  puts "   Description: #{app.description}"
                  puts "   Date received: #{app.date_received}"
                  puts "   URL: #{app.info_url}"
                end

                sleep @options[:delay] if @options[:delay]
              end

              # --- Pagination logic (unchanged) ---
              pagination_info = page.query_selector('input[name="PageCount"], input#PageCount')
              current_index_el = page.query_selector('input[name="CurrentPageIndex"], input#CurrentPageIndex')
              navigated = false

              if pagination_info && current_index_el
                page_count = (pagination_info.get_attribute('value') || '0').to_i
                current_index_str = current_index_el.get_attribute('value') rescue nil
                current_index = (current_index_str && !current_index_str.to_s.strip.empty?) ? current_index_str.to_i : 0

                if current_index < (page_count - 1)
                  next_index = current_index + 1
                  anchors = page.query_selector_all('ul.pagination a, ul.pager a, ul.tablePagingRow a, a.btn-primary')
                  anchors.each do |a|
                    onclick = a.get_attribute('onclick') rescue nil
                    text = a.inner_text.to_s.strip rescue ''
                    if onclick && onclick.include?("PagingClick('#{next_index}')")
                      a.click
                      navigated = true
                      break
                    elsif text == (next_index + 1).to_s
                      a.click
                      navigated = true
                      break
                    end
                  end

                  unless navigated
                    js = <<~JS
                      (() => {
                        try {
                          if (typeof PagingClick === 'function') {
                            PagingClick(#{next_index});
                            return true;
                          }
                        } catch(e) { return false; }
                        return false;
                      })()
                    JS
                    res = page.evaluate(js) rescue false
                    navigated = true if res
                  end

                  if navigated
                    page.wait_for_selector('#divOnlinePlanningSearchResults', timeout: 30_000) rescue nil
                    page.wait_for_timeout(1500)
                  else
                    puts "⚠️ Could not move to next page."
                  end
                else
                  break
                end
              else
                break
              end

              break if seen_refs.size == visited_refs_before
            end

            context.close
            browser.close
          end
        end
      rescue Timeout::Error
        puts "❌ Timeout after 15 minutes while scraping #{@authority.name} (NorthgateES). " \
             "Returning partial results (#{apps.size} applications already collected)."
      rescue StandardError => e
        puts "❌ Unexpected error in NorthgateES scraper for #{@authority.name}: #{e.class} - #{e.message}"
      end

      apps
    end
  end
end