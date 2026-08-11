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
require_relative 'uk_planning_scraper/randoms1'
require_relative 'uk_planning_scraper/randoms2'
require_relative 'uk_planning_scraper/randoms3'
require 'logger'

module UKPlanningScraper
  class SystemNotSupported < StandardError; end
  class AuthorityNotFound < StandardError; end
  class TooManySearchResults < StandardError; end
end
