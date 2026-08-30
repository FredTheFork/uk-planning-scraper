require_relative "uk_planning_scraper/version"
require_relative "uk_planning_scraper/authority"
require_relative "uk_planning_scraper/authority_scrape_params"
require_relative "uk_planning_scraper/application"
require_relative 'uk_planning_scraper/idox'
require_relative 'uk_planning_scraper/northgate'
require_relative 'uk_planning_scraper/agileplanning'
require_relative 'uk_planning_scraper/Advancedsearch'
require_relative 'uk_planning_scraper/agileapps'
require_relative 'uk_planning_scraper/arcus'
require_relative 'uk_planning_scraper/northgate_es'
require_relative 'uk_planning_scraper/ocella'
require_relative 'uk_planning_scraper/systemni'
require_relative 'uk_planning_scraper/Randoms1'
require_relative 'uk_planning_scraper/Randoms2'
require_relative 'uk_planning_scraper/Randoms3'
require_relative 'uk_planning_scraper/servlet'
require 'logger'

module UKPlanningScraper
  class SystemNotSupported < StandardError; end
  class AuthorityNotFound < StandardError; end
  class TooManySearchResults < StandardError; end
end
