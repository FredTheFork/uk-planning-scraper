# frozen_string_literal: true
# Compatibility shim for playwright-ruby-client 1.52+.
# Ensures Playwright::Error / Playwright::TimeoutError exist and
# that Playwright.create is callable as a public class method.
require 'playwright'

module Playwright
  unless defined?(::Playwright::Error)
    class Error < StandardError; end
  end

  unless defined?(::Playwright::TimeoutError)
    class TimeoutError < StandardError; end
  end

  # The gem defines `create` as a module_function (private instance method
  # + public class method).  Some call sites check `respond_to?(:create)`
  # which returns false for private methods, so make sure it's public.
  class << self
    public :create if method_defined?(:create, true) && !public_methods.include?(:create)
  end

  project_root = File.expand_path('../..', __dir__)
  playwright_bin = File.join(project_root, 'node_modules', '.bin', 'playwright-core')
  playwright_bin += '.cmd' if Gem.win_platform? && File.file?("#{playwright_bin}.cmd")
  CLI_EXECUTABLE_PATH = playwright_bin unless const_defined?(:CLI_EXECUTABLE_PATH, false)
end
