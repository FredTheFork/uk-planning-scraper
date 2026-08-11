# lib/uk_planning_scraper/utils.rb
module UKPlanningScraper
  module Utils
    def self.parse_date(str)
      return nil if str.nil? || str.strip.empty?
      Date.parse(str) rescue nil
    end
  end
end
