require 'csv'
require 'date'
require 'openssl'
require_relative 'errors'

module UKPlanningScraper
  class Authority
    attr_reader :name 
    attr_reader :url
    attr_reader :system

    def [](key)
      case key.to_sym
      when :url then @url
      when :name then @name
      when :system then @system
      else
        raise NoMethodError.new("Unknown key #{key}")
      end
    end

    @@authorities = []

    def initialize(name, url)
      @name = name.strip
      @url = url.strip
      @tags = []
      @applications = []
      @scrape_params = {}

      if @url.match(/search\.do\?action=advanced/i)
        @system = 'idox'
      elsif @url.match?(/\/Northgate\/ES\/Presentation\/Planning\/OnlinePlanning\/OnlinePlanningSearch/i) ||
            @url.match?(/\/LPAssure\/ES\/Presentation\/Planning\/OnlinePlanning\/OnlinePlanningSearch/i) ||
            @url.match?(/\/Assure\/ES\/Presentation\/Planning\/OnlinePlanning\/OnlinePlanningSearch/i) ||
            @url.match?(/\/NECSWS\/ES\/Presentation\/Planning\/OnlinePlanning\/OnlinePlanningSearch/i)
        @system = 'northgate_es'

      elsif @url.match(/generalsearch\.aspx/i) && !@url.match(/camden\.gov\.uk/i)
        @system = 'northgate'
      elsif @url.match(/keywordssearch\.aspx/i) && !@url.match(/camden\.gov\.uk/i)
        @system = 'northgate'
      elsif @url.match(/newapplicationssearch\.aspx/i) && !@url.match(/camden\.gov\.uk/i)
        @system = 'northgate'

      elsif @url.match?(%r{planningregister\.planningsystemni\.gov\.uk}i) ||
            @url.match?(%r{planningsystemni\.gov\.uk}i)
        @system = 'systemni'
      elsif @url =~ /ocellaweb|great-yarmouth|hillingdon|havering|sholland|arun/
        @system = 'ocella'
      elsif @url.match(%r{/planning/index\.html\?(?:.*&)?fa=search}i)
        @system = 'agileplanning'

      elsif @url.match(%r{planning\.agileapplications\.co\.uk/.+/search-applications/?$}i)
        @system = 'agileapps'
      elsif @url.match(%r{planning\.richmond\.gov\.uk/richmond/search-applications/?$}i)
        @system = 'agileapps'
      elsif @url.match(%r{planning\.redbridge\.gov\.uk/redbridge/search-applications/?$}i)
        @system = 'agileapps'
      # Arcus family of systems — include various known URL shapes but exclude the specific Wiltshire tabset URL
      elsif @url =~ %r{
              (?:                                     # any of the following (case-insensitive)
                arcus                                  # any URL containing "arcus"
                |/pr\d?/s/.*Arcus_BE_Public_Register   # legacy Arcus_BE_Public_Register pattern
                |arcus.*/pr.*/register-view            # arcus ... /pr.../register-view
                |arcus.*register                       # arcus ... register
                |development\.wiltshire\.gov\.uk/pr/s/ # development.wiltshire pr/s pages (generally Arcus)
              )
            }ix && @url !~ %r{development\.wiltshire\.gov\.uk/pr/s/\?[^#]*tabset-167f1}i
        @system = 'arcus'
      elsif @url.match?(/\/Search\/Advanced/i) &&
            !@url.start_with?("https://webportal.ribblevalley.gov.uk/planningApplication/search/advanced")
        @system = 'advancedsearch'
      elsif @url == "https://pa.fylde.gov.uk/Disclaimer?returnUrl=%2FSearch%2FAdvanced"
        @system = 'advancedsearch'
      elsif @url.include?('/servlets/ApplicationSearchServlet')
        @system = 'servlet'
      else
        @system = 'unknownsystem'
      end
    end

    def scrape(options = {})
      default_options = {
        delay: 10,
      }
      options = default_options.merge(options)
      case system
      when 'idox'
        @applications = scrape_idox(@scrape_params, options)
      when 'northgate'
        @applications = scrape_northgate(@scrape_params, options)
      when 'agileplanning'
        @applications = scrape_agileplanning(@scrape_params, options)
      when 'agileapps'
        @applications = scrape_agileapps(@scrape_params, options)
      when 'systemni'
        @applications = scrape_systemni(@scrape_params, options)
      when 'arcus'
        @applications = scrape_arcus(@scrape_params, options)
      when 'camden'
        @applications = scrape_northgate(@scrape_params, options)
      when 'ocella' 
        @applications = scrape_ocella(@scrape_params, options)
      when 'servlet'
        @applications = scrape_servlet(@scrape_params, options)
      when 'northgate_es'
        @applications = scrape_northgate_es(@scrape_params, options)
      when 'advancedsearch'
        @applications = scrape_advancedsearch(@scrape_params, options)
      when 'randoms1'
        @applications = scrape_randoms1(@scrape_params, options)
      when 'randoms2'
        @applications = scrape_randoms2(@scrape_params, options)
      when 'randoms3'
        @applications = scrape_randoms3(@scrape_params, options)

      else
        raise SystemNotSupported.new("Planning system not supported for #{@name} at URL: #{@url}")
      end

      # Normalize legacy outputs (temporary — remove after migration)
      normalized_apps = []
      @applications.each do |item|
        if item.is_a?(UKPlanningScraper::Application)
          normalized_apps << item
        elsif item.is_a?(Hash)
          # convert legacy hash -> Application
          app = UKPlanningScraper::Application.new
          app.scraped_at            = item[:scraped_at] || item['scraped_at']
          app.authority_name        = item[:authority_name] || item['authority_name']
          app.council_reference     = item[:council_reference] || item['council_reference']
          app.date_received         = item[:date_received] || item['date_received']
          app.date_validated        = item[:date_validated] || item['date_validated']
          app.status                = item[:status] || item['status']
          app.decision              = item[:decision] || item['decision']
          app.date_decision         = item[:date_decision] || item['date_decision']
          app.info_url              = item[:info_url] || item['info_url']
          app.address               = item[:address] || item['address']
          app.description           = item[:description] || item['description']
          app.documents_count       = item[:documents_count] || item['documents_count']
          app.documents_url         = item[:documents_url] || item['documents_url']
          app.alternative_reference = item[:alternative_reference] || item['alternative_reference']
          app.appeal_status         = item[:appeal_status] || item['appeal_status']
          app.appeal_decision       = item[:appeal_decision] || item['appeal_decision']
          normalized_apps << app
        else
          # Ignore unexpected return types (be conservative)
        end
      end

      @applications = normalized_apps

      # Ensure authority_name present for all
      @applications.each { |app| app.authority_name ||= @name }

      output = []
      @applications.each { |app| output << app.to_hash if app.valid? }

      clear_scrape_params

      output
    end

    def tags
      @tags.sort
    end

    def add_tags(tags)
      tags.each { |t| add_tag(t) }
    end

    def add_tag(tag)
      clean_tag = tag.strip.downcase.gsub(' ', '')
      @tags << clean_tag unless tagged?(clean_tag)
    end

    def tagged?(tag)
      @tags.include?(tag)
    end

    def self.all
      @@authorities
    end

    def self.tags
      tags = []
      @@authorities.each { |a| tags << a.tags }
      tags.flatten.uniq.sort
    end

    def self.named(name)
      authority = @@authorities.find { |a| name == a.name }
      raise AuthorityNotFound if authority.nil?
      authority 
    end

    def self.tagged(tag)
      found = []
      @@authorities.each { |a| found << a if a.tagged?(tag) }
      found
    end

    def self.not_tagged(tag)
      found = []
      @@authorities.each { |a| found << a unless a.tagged?(tag) }
      found
    end

    def self.untagged
      found = []
      @@authorities.each { |a| found << a if a.tags.empty? }
      found
    end

    def self.load
      return unless @@authorities.empty?

      CSV.foreach(File.join(File.dirname(__dir__), 'uk_planning_scraper', 'authorities.csv'), headers: true) do |line|
        next if line['authority_name'].nil? || line['url'].nil?
        auth = Authority.new(line['authority_name'], line['url'])

        if line['tags']
          auth.add_tags(line['tags'].split(/\s+/))
          # If CSV tag defines randoms system, override auto-detected system
          if auth.tagged?('randoms1')
            auth.instance_variable_set(:@system, 'randoms1')
          elsif auth.tagged?('randoms2')
            auth.instance_variable_set(:@system, 'randoms2')
          elsif auth.tagged?('randoms3')
            auth.instance_variable_set(:@system, 'randoms3')
          end

        end
        auth.add_tag(auth.system)
        @@authorities << auth
      end
    end

    private
    def scrape_idox(params, options)
      require_relative 'idox'
      UKPlanningScraper::IdoxScraper.scrape(self, params, options)
    end

    def scrape_agileplanning(params, options)
      require_relative 'agileplanning'
      UKPlanningScraper::AgilePlanningScraper.scrape(self, params, options)
    end

    def scrape_agileapps(params, options)
      require_relative 'agileapps'
      UKPlanningScraper::AgileAppsScraper.scrape(self, params, options)
    end

    def scrape_northgate(params, options)
      require_relative 'northgate'
      UKPlanningScraper::NorthgateScraper.scrape(self)
    end

    def scrape_advancedsearch(params, options)
      require_relative 'Advancedsearch'
      UKPlanningScraper::AdvancedsearchScraper.scrape(self, params, options)
    end

    def scrape_ocella(params, options)
      require_relative 'ocella'
      UKPlanningScraper::OcellaScraper.scrape(self, params, options)
    end
    
    def scrape_northgate_es(params, options)
      require_relative 'northgate_es'
      UKPlanningScraper::NorthgateESScraper.new(self, params, options).scrape
    end

    def scrape_arcus(params, options)
      require_relative 'arcus'
      UKPlanningScraper::ArcusScraper.scrape(self, params, options)
    end

    def scrape_servlet(params, options)
      require_relative 'servlet'
      UKPlanningScraper::ServletScraper.scrape(self, params, options)
    end

    def scrape_systemni(params, options)
      require_relative 'systemni'
      UKPlanningScraper::SystemNIScraper.new(self, params, options).scrape
    end

    def scrape_randoms1(params, options)
      require_relative 'Randoms1'
      UKPlanningScraper::Randoms1Scraper.scrape(self, params, options)
    end

    def scrape_randoms2(params, options)
      require_relative 'Randoms2'
      UKPlanningScraper::Randoms2Scraper.scrape(self, params, options)
    end

    def scrape_randoms3(params, options)
      require_relative 'Randoms3'
      UKPlanningScraper::Randoms3Scraper.scrape(self, params, options)
    end

  end
end

UKPlanningScraper::Authority.load
