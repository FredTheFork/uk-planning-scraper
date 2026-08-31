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
      from_str = from_date.strftime('%d/%m/%Y')
      to_str   = to_date.strftime('%d/%m/%Y')

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

            # === Deselect non-planning checkboxes ===
            %w[SearchEnforcement SearchBuildingControl SearchTreePreservationOrders].each do |id|
              begin
                el = page.query_selector("input##{id}")
                if el && el['checked']
                  page.uncheck("input##{id}", force: true)
                  puts "✔️ Unchecked #{id}"
                end
              rescue => e
                puts "⚠️ Could not uncheck #{id}: #{e.message}"
              end
            end

            # Ensure Planning checkbox is checked
            begin
              planning_cb = page.query_selector('input#SearchPlanning')
              if planning_cb && !planning_cb['checked']
                page.check('input#SearchPlanning', force: true)
                puts "✔️ Checked SearchPlanning"
              end
            rescue => e
              puts "⚠️ Could not check SearchPlanning: #{e.message}"
            end

            # === Expand Planning section if collapsed ===
            begin
              planning_summary = page.query_selector('summary:has-text("Planning")')
              if planning_summary
                details = planning_summary.evaluate('el => el.closest("details") ? el.closest("details").open : null')
                unless details
                  planning_summary.click
                  puts "✔️ Expanded Planning section"
                  page.wait_for_timeout(500)
                end
              end
            rescue => e
              puts "⚠️ Could not expand Planning section: #{e.message}"
            end

            # === Fill date received fields ===
            begin
              from_input = page.locator('input#DateReceivedFrom')
              to_input   = page.locator('input#DateReceivedTo')

              if from_input.count > 0
                from_input.fill(from_str)
                puts "✔️ Filled DateReceivedFrom: #{from_str}"
              else
                # Fallback: try by name
                page.fill('input[name="DateReceivedFrom"]', from_str) rescue nil
                puts "✔️ Filled DateReceivedFrom via name: #{from_str}"
              end

              if to_input.count > 0
                to_input.fill(to_str)
                puts "✔️ Filled DateReceivedTo: #{to_str}"
              else
                page.fill('input[name="DateReceivedTo"]', to_str) rescue nil
                puts "✔️ Filled DateReceivedTo via name: #{to_str}"
              end
            rescue => e
              puts "⚠️ Could not fill date fields: #{e.class} - #{e.message}"
            end

            # === Click Apply button ===
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

            # === Wait for results ===
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

            # === Parse results with pagination ===
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

                  # Address: from the anchor's aria-label or inner_text
                  link = row.query_selector('a.h5')
                  if link
                    href = link.get_attribute('href')
                    app.info_url = href ? URI.join(@base_url, href).to_s : nil
                    # Address is the link text (may contain line breaks)
                    raw_addr = link.inner_text.strip.gsub(/\s+/, ' ')
                    app.address = raw_addr
                  end

                  # Description: last col-xs-12 col-md-12 div (the proposal text)
                  desc_divs = row.query_selector_all('div.col-xs-12')
                  if desc_divs && desc_divs.size > 1
                    app.description = desc_divs[desc_divs.size - 1].inner_text.strip.gsub(/\s+/, ' ')
                  end

                  # Status: second span in the h2 container
                  spans = row.query_selector_all('h2.fs-6 ~ span, h2.fs-6 + span, div.col-xs-12 span')
                  if spans && spans.size >= 2
                    app.status = spans[1].inner_text.strip
                  end

                  next if app.council_reference.nil? || seen_refs.include?(app.council_reference)
                  seen_refs << app.council_reference

                  puts "------------------------------------------------------------"
                  puts "  Ref:        #{app.council_reference}"
                  puts "  Address:    #{app.address}"
                  puts "  Description:#{app.description}"
                  puts "  Status:     #{app.status}"
                  puts "  Link:       #{app.info_url}"
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
