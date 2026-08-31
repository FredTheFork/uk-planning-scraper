# frozen_string_literal: true
require_relative 'playwright_compat'
require 'date'
require 'uri'
require 'set'
require 'timeout'
require_relative 'application'

DAYS = 7 unless defined?(DAYS)

module UKPlanningScraper
  class PlanningRegisterScraper
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
      puts "🔍 Scraping PlanningRegister system for #{@authority.name}"

      from_date = @params[:received_from] || @params[:validated_from] || (Date.today - (DAYS - 1))
      to_date   = @params[:received_to]   || @params[:validated_to]   || Date.today

      apps = []
      seen_refs = Set.new

      begin
        Timeout.timeout(900) do
          Playwright.create(playwright_cli_executable_path: Playwright::CLI_EXECUTABLE_PATH) do |playwright|
            browser = playwright.chromium.launch(headless: false)
            context = browser.new_context
            page = context.new_page

            puts "🌐 Navigating to #{@base_url}"
            page.goto(@base_url, timeout: 60_000)
            page.wait_for_load_state
            page.wait_for_timeout(1000)

            # === Step 1: Accept cookie consent banner ===
            begin
              cookie_btn = page.query_selector('button.accept-policy.close')
              if cookie_btn
                cookie_btn.click(force: true)
                page.wait_for_timeout(500)
                puts "✔️ Clicked cookie consent Accept button"
              end
            rescue => e
              puts "⚠️ Could not click cookie consent: #{e.message}"
            end

            # === Step 2: Accept disclaimer (form POST to /Disclaimer/AcceptDisclaimer) ===
            begin
              disclaimer_btn = page.query_selector('form[action="/Disclaimer/AcceptDisclaimer"] button[type="submit"]')
              if disclaimer_btn
                disclaimer_btn.click(force: true)
                page.wait_for_load_state
                page.wait_for_timeout(1000)
                puts "✔️ Clicked disclaimer Accept button"
              end
            rescue => e
              puts "⚠️ Could not click disclaimer: #{e.message}"
            end

            # === Step 3: Deselect non-planning checkboxes via JS ===
            # The HTML uses checked="checked" attribute. JS evaluation is more robust
            # than Playwright's uncheck for these ASP.NET-style checkboxes.
            %w[SearchEnforcement SearchBuildingControl SearchTreePreservationOrders].each do |id|
              begin
                js = %Q{
                  (function(){
                    var el = document.querySelector('input##{id}');
                    if (!el) return false;
                    el.checked = false;
                    el.dispatchEvent(new Event('input', {bubbles:true}));
                    el.dispatchEvent(new Event('change', {bubbles:true}));
                    return true;
                  })();
                }
                result = page.evaluate(js)
                if result
                  puts "✔️ Unchecked #{id}"
                else
                  puts "ℹ️ #{id} checkbox not present"
                end
              rescue => e
                puts "⚠️ Could not uncheck #{id}: #{e.message}"
              end
            end

            # === Step 4: Ensure Planning checkbox is checked ===
            begin
              js = %Q{
                (function(){
                  var el = document.querySelector('input#SearchPlanning');
                  if (!el) return false;
                  if (!el.checked) {
                    el.checked = true;
                    el.dispatchEvent(new Event('input', {bubbles:true}));
                    el.dispatchEvent(new Event('change', {bubbles:true}));
                  }
                  return true;
                })();
              }
              page.evaluate(js)
              puts "✔️ Ensured SearchPlanning is checked"
            rescue => e
              puts "⚠️ Could not check SearchPlanning: #{e.message}"
            end

            # === Step 5: Expand Planning section if collapsed ===
            begin
              planning_summary = page.query_selector('summary:has-text("Planning")')
              if planning_summary
                details_open = page.evaluate(%Q{
                  (function(){
                    var s = document.querySelector('summary:has-text("Planning")');
                    if (!s) return null;
                    var d = s.closest('details');
                    return d ? d.open : null;
                  })();
                })
                unless details_open
                  planning_summary.click
                  puts "✔️ Expanded Planning section"
                  page.wait_for_timeout(500)
                end
              end
            rescue => e
              puts "⚠️ Could not expand Planning section: #{e.message}"
            end

            # === Step 6: Fill date received fields ===
            # Input type is "date" so browser expects YYYY-MM-DD format
            from_str = from_date.strftime('%Y-%m-%d')
            to_str   = to_date.strftime('%Y-%m-%d')

            fill_date_field = lambda do |selector, value|
              begin
                js = %Q{
                  (function(){
                    var el = document.querySelector("#{selector}");
                    if (!el) return false;
                    try { el.focus(); } catch(e){}
                    el.value = "#{value}";
                    el.dispatchEvent(new Event('input', {bubbles:true}));
                    el.dispatchEvent(new Event('change', {bubbles:true}));
                    try { el.blur(); } catch(e){}
                    return true;
                  })();
                }
                result = page.evaluate(js)
                if result
                  puts "✔️ Filled #{selector} with #{value}"
                  return true
                end
                false
              rescue => e
                puts "⚠️ Date fill error for #{selector}: #{e.class} - #{e.message}"
                false
              end
            end

            filled_from = false
            %w[input#DateReceivedFrom input[name="DateReceivedFrom"]].each do |sel|
              filled_from = true and break if fill_date_field.call(sel, from_str)
            end
            puts "⚠️ DateReceivedFrom not found" unless filled_from

            filled_to = false
            %w[input#DateReceivedTo input[name="DateReceivedTo"]].each do |sel|
              filled_to = true and break if fill_date_field.call(sel, to_str)
            end
            puts "⚠️ DateReceivedTo not found" unless filled_to

            page.wait_for_timeout(500)

            # === Step 7: Click Apply button ===
            begin
              apply_btn = page.query_selector('input[type="submit"][value="Apply"]')
              if apply_btn
                apply_btn.click
                puts "✔️ Clicked Apply button"
              else
                raise "Apply button not found"
              end
            rescue => e
              puts "❌ Could not click Apply: #{e.message}"
              File.write("debug_output.html", page.content)
              context.close
              browser.close
              return []
            end

            # === Step 8: Wait for results ===
            begin
              page.wait_for_selector('div#resultsArea div.row.searchResultsCardRow', timeout: 30_000)
              puts "✅ Results loaded"
            rescue => e
              puts "⚠️ No results or timeout: #{e.message}"
              File.write("debug_output.html", page.content)
              context.close
              browser.close
              return []
            end

            # === Step 9: Parse results with pagination ===
            page_num = 1
            loop do
              rows = page.query_selector_all('div#resultsArea div.row.searchResultsCardRow')
              puts "📄 Page #{page_num}: Found #{rows.size} applications"

              rows.each do |row|
                begin
                  app = Application.new
                  app.scraped_at = Time.now
                  app.authority_name = @authority.name

                  # Reference: h2.fs-6 inside the card
                  ref_el = row.query_selector('h2.fs-6')
                  app.council_reference = ref_el&.inner_text&.strip

                  # Address: from the anchor's inner_text
                  link = row.query_selector('a.h5')
                  if link
                    href = link.get_attribute('href')
                    app.info_url = href ? URI.join(@base_url, href).to_s : nil
                    raw_addr = link.inner_text.strip.gsub(/\s+/, ' ')
                    app.address = raw_addr
                  end

                  # Description: last col-xs-12 div (the proposal text)
                  desc_divs = row.query_selector_all('div.col-xs-12')
                  if desc_divs && desc_divs.size > 1
                    app.description = desc_divs[desc_divs.size - 1].inner_text.strip.gsub(/\s+/, ' ')
                  end

                  # Status: look for span elements near the h2
                  spans = row.query_selector_all('h2.fs-6 ~ span, div.col-xs-12 span')
                  if spans && spans.size >= 2
                    app.status = spans[1].inner_text.strip
                  end

                  next if app.council_reference.nil? || seen_refs.include?(app.council_reference)
                  seen_refs << app.council_reference

                  puts "------------------------------------------------------------"
                  puts "  Ref:         #{app.council_reference}"
                  puts "  Address:     #{app.address}"
                  puts "  Description: #{app.description}"
                  puts "  Status:      #{app.status}"
                  puts "  Link:        #{app.info_url}"
                  puts "------------------------------------------------------------"

                  apps << app
                rescue => e
                  puts "⚠️ Error parsing row: #{e.message}"
                end
              end

              # === Pagination ===
              pagination = page.query_selector('ul.pagination.ajax-pager')
              break unless pagination

              total_pages = pagination.get_attribute('data-total-pages').to_i
              break if page_num >= total_pages

              next_page = page_num + 1
              next_span = page.query_selector("span[data-ajax-target*=\"page=#{next_page}\"]")
              break unless next_span

              next_span.click
              page.wait_for_selector('div#resultsArea div.row.searchResultsCardRow', timeout: 15_000)
              page.wait_for_timeout(500)
              page_num += 1
            end

            context.close
            browser.close
          end
        end
      rescue Timeout::Error
        puts "❌ Timeout after 15 minutes while scraping #{@authority.name} (PlanningRegister). " \
             "Returning partial results (#{apps.size} applications already collected)."
      rescue StandardError => e
        puts "❌ Unexpected error in PlanningRegister scraper for #{@authority.name}: #{e.class} - #{e.message}"
        puts e.backtrace.first(5).join("\n")
      end

      puts "  → #{apps.size} applications found."
      apps
    end
  end
end
