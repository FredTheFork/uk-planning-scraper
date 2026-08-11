# frozen_string_literal: true

require 'playwright'

module Playwright
  cli_path = File.expand_path('../../node_modules/.bin/playwright-core', __dir__)
  cli_path = "#{cli_path}.cmd" if Gem.win_platform? && File.file?("#{cli_path}.cmd")
  CLI_EXECUTABLE_PATH = cli_path unless const_defined?(:CLI_EXECUTABLE_PATH, false)

  unless respond_to?(:create)
    def self.create(playwright_cli_executable_path:, &block)
      transport = Transport.new(playwright_cli_executable_path: playwright_cli_executable_path)
      connection = Connection.new(transport)
      connection.async_run

      execution = begin
        playwright = connection.initialize_playwright
        Execution.new(connection, PlaywrightApi.wrap(playwright))
      rescue StandardError
        connection.stop
        raise
      end

      return execution unless block

      begin
        block.call(execution.playwright)
      ensure
        execution.stop
      end
    end
  end

  unless const_defined?(:Execution, false)
    class Execution
      attr_reader :playwright, :browser

      def initialize(connection, playwright, browser = nil)
        @connection = connection
        @playwright = playwright
        @browser = browser
      end

      def stop
        @browser&.close
        @connection.stop
      end
    end
  end
end
