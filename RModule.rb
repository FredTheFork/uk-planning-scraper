# systemtest.rb
require_relative 'lib/uk_planning_scraper/authority'
require_relative 'lib/uk_planning_scraper/Randoms1.rb'
require_relative 'lib/uk_planning_scraper/Randoms2.rb'
require_relative 'lib/uk_planning_scraper/Randoms3.rb'
require_relative 'lib/uk_planning_scraper/application'



DAYS = 3




puts "Select scraper set(s) to run:"
puts "1 = Randoms1, 2 = Randoms2, 3 = Randoms3"
puts "4 = Randoms1 + Randoms2, 5 = Randoms2 + Randoms3, 6 = Randoms1 + Randoms3"
puts "7 = All (Randoms1 + Randoms2 + Randoms3)"
print "Enter option: "
choice = gets.to_i

UKPlanningScraper::Authority.load

total_scraped = 0

def scrape_randoms(tag, scraper_class)
  authorities = UKPlanningScraper::Authority.tagged(tag)
  puts "\nScraping #{authorities.size} authorities using #{scraper_class.name}…"
  total_apps = 0
  authorities.each do |authority|
    puts "\n==> Scraping: #{authority.name} (#{tag})"
    begin
      apps = scraper_class.scrape(authority)
      total_apps += apps.size
      puts "✅ Scraped #{apps.size} applications from #{authority.name}"
    rescue => e
      puts "❌ Error scraping #{authority.name}: #{e.class} - #{e.message}"
      puts e.backtrace.first
    end
  end
  total_apps
end

if [1, 4, 6, 7].include?(choice)
  total_scraped += scrape_randoms('randoms1', UKPlanningScraper::Randoms1Scraper)
end
if [2, 4, 5, 7].include?(choice)
  total_scraped += scrape_randoms('randoms2', UKPlanningScraper::Randoms2Scraper)
end
if [3, 5, 6, 7].include?(choice)
  total_scraped += scrape_randoms('randoms3', UKPlanningScraper::Randoms3Scraper)
end

puts "\nTOTAL applications scraped: #{total_scraped}"
puts "System scrape complete."
