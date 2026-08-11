# frozen_string_literal: true

require 'playwright'

module Playwright
  cli_path = File.expand_path('../../node_modules/.bin/playwright-core', __dir__)
  cli_path = "#{cli_path}.cmd" if Gem.win_platform? && File.file?("#{cli_path}.cmd")
  CLI_EXECUTABLE_PATH = cli_path unless const_defined?(:CLI_EXECUTABLE_PATH, false)
end
