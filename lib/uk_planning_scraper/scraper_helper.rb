# lib/uk_planning_scraper/scraper_helpers.rb
module UKPlanningScraper
  module ScraperHelper
    def safe_text(node)
      node&.text_content&.strip rescue nil
    end

    def safe_attr(node, attr)
      node&.get_attribute(attr) rescue nil
    end

    def parse_date_local(str)
      return nil if str.nil? || str.to_s.strip.empty?
      s = str.to_s.strip.gsub("\u00A0", ' ').strip
      Date.strptime(s, '%d/%m/%Y') rescue nil
    end

    # Playwright locator iteration helper — Ruby Playwright locators are not Enumerable
    # Usage: iterate_locator(locator) { |loc| ... }
    def iterate_locator(locator)
      cnt = locator.count
      (0...cnt).each do |i|
        yield locator.nth(i)
      end
    end

    # Extract file download URLs from a detail page (Playwright page)
    def extract_docs_from_page(page)
      urls = []
      begin
        doc_rows = page.locator('tbody.pr-table__body tr, tr.pr-table__row, tbody.pr-table__body tr.pr-table__row')
        if doc_rows.count > 0
          (0...doc_rows.count).each do |i|
            row = doc_rows.nth(i)
            row.locator('a[href]').all.each do |a|
              href = a.get_attribute('href') rescue nil
              urls << href if href && !href.to_s.strip.empty?
            end
          end
        else
          files = page.locator('a[href*="/servlet.shepherd/version/download"], a[href*="/sfc/servlet.shepherd"], a:has-text("Download")')
          (0...files.count).each do |i|
            href = files.nth(i).get_attribute('href') rescue nil
            urls << href if href
          end
        end
      rescue => _e
      end
      urls.uniq
    end

    # Small builder that returns a new Application instance from attrs
    def build_application(attrs = {})
      app = UKPlanningScraper::Application.new
      app.scraped_at            = attrs[:scraped_at] || Time.now
      app.authority_name        = attrs[:authority_name]
      app.council_reference     = attrs[:council_reference]
      app.date_received         = attrs[:date_received]
      app.date_validated        = attrs[:date_validated]
      app.status                = attrs[:status]
      app.decision              = attrs[:decision]
      app.date_decision         = attrs[:date_decision]
      app.info_url              = attrs[:info_url]
      app.address               = attrs[:address]
      app.description           = attrs[:description]
      app.documents_count       = attrs[:documents_count]
      app.documents_url         = attrs[:documents_url]
      app.alternative_reference = attrs[:alternative_reference]
      app.appeal_status         = attrs[:appeal_status]
      app.appeal_decision       = attrs[:appeal_decision]
      app
    end
  end
end
