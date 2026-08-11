# frozen_string_literal: true

# Vendored gems — no `gem install` required.
# Load order matters: concurrent-ruby and base64 before playwright,
# mime-types-data before mime-types.
vendor_lib = File.expand_path('../../../vendor', __dir__)

%w[
  concurrent-ruby/lib
  base64/lib
  mime-types-data/lib
  mime-types/lib
  playwright-ruby-client/lib
].each do |sub|
  path = File.join(vendor_lib, sub)
  $LOAD_PATH.unshift(path) unless $LOAD_PATH.include?(path)
end

require 'concurrent'
require 'base64'
require 'mime/types/data'
require 'mime/types'
require 'playwright'

# Point Playwright at the local node_modules CLI.
module Playwright
  cli_path = File.expand_path('../../../node_modules/.bin/playwright', __dir__)
  cli_path = "#{cli_path}.cmd" if Gem.win_platform? && File.file?("#{cli_path}.cmd")
  CLI_EXECUTABLE_PATH = cli_path unless const_defined?(:CLI_EXECUTABLE_PATH, false)
end
