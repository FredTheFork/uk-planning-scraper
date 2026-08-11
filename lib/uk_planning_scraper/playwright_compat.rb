# frozen_string_literal: true
# Compatibility shim for playwright-ruby-client
# Ensures Playwright::Error and Playwright::TimeoutError exist regardless of gem version
require 'playwright'

module Playwright
  unless defined?(::Playwright::Error)
    class Error < StandardError; end
  end

  unless defined?(::Playwright::TimeoutError)
    class TimeoutError < StandardError; end
  end

  unless respond_to?(:create)
    begin
      require 'playwright/playwright'
    rescue LoadError
      begin
        require 'playwright/connection'
        require 'playwright/transport'
      rescue LoadError
      end
    end
  end
end
