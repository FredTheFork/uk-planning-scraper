# frozen_string_literal: true
# Compatibility shim for playwright-ruby-client
# Ensures Playwright::Error, Playwright::TimeoutError, and Playwright.create
# exist regardless of gem version.
require 'playwright'

module Playwright
  unless defined?(::Playwright::Error)
    class Error < StandardError; end
  end

  unless defined?(::Playwright::TimeoutError)
    class TimeoutError < StandardError; end
  end

  # Some versions of the gem don't expose `create` as a module method.
  # Define it ourselves using the gem's internal classes.
  unless respond_to?(:create)
    unless defined?(::Playwright::Execution)
      class Execution
        def initialize(connection, playwright, browser = nil)
          @connection = connection
          @playwright = playwright
          @browser = browser
        end

        def stop
          @browser&.close
          @connection.stop
        end

        attr_reader :playwright, :browser
      end
    end

    module_function def create(playwright_cli_executable_path:, &block)
      transport = Transport.new(playwright_cli_executable_path: playwright_cli_executable_path)
      connection = Connection.new(transport)
      connection.async_run
      execution =
        begin
          playwright = connection.initialize_playwright
          Execution.new(connection, PlaywrightApi.wrap(playwright))
        rescue
          connection.stop
          raise
        end
      if block
        begin
          block.call(execution.playwright)
        ensure
          execution.stop
        end
      else
        execution
      end
    end
  end
end
