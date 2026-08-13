# frozen_string_literal: true

# Compatibility layer for playwright-ruby-client.
#
# Strategy:
#   1. If a vendored copy of the gem exists under vendor/, prefer it (portable, no gem install needed).
#   2. Otherwise, fall back to the system-installed gem (via Bundler / gem install).
#   3. Set CLI_EXECUTABLE_PATH to the local node_modules/.bin/playwright so the Ruby gem
#      talks to the same Node Playwright version that manages the browser binaries.
#   4. Verify that Playwright.create is actually defined — if not, raise a helpful error
#      instead of letting callers fail with a confusing NoMethodError later.

require 'concurrent'
require 'base64'
require 'mime/types/data'
require 'mime/types'

# Try vendored gems first, then fall back to system gem.
vendor_lib = File.expand_path('../../../vendor', __dir__)
vendored_playwright = File.join(vendor_lib, 'playwright-ruby-client', 'lib', 'playwright.rb')

if File.file?(vendored_playwright)
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
end

require 'playwright'

# Point Playwright at the local node_modules CLI.
module Playwright
  unless const_defined?(:CLI_EXECUTABLE_PATH, false)
    cli_path = File.expand_path('../../../node_modules/.bin/playwright', __dir__)
    cli_path = "#{cli_path}.cmd" if Gem.win_platform? && File.file?("#{cli_path}.cmd")
    CLI_EXECUTABLE_PATH = cli_path
  end

  unless respond_to?(:create)
    raise <<~MSG
      Playwright.create is not defined.

      The playwright-ruby-client gem could not be loaded properly.
      Possible fixes:
        1. Run:  bundle install
        2. If using vendored gems, ensure the vendor/ directory exists with:
           vendor/playwright-ruby-client/lib/playwright.rb
           vendor/concurrent-ruby/lib/concurrent.rb
           vendor/base64/lib/base64.rb
           vendor/mime-types-data/lib/mime/types/data.rb
           vendor/mime-types/lib/mime/types.rb
        3. Reinstall the gem:  gem install playwright-ruby-client -v 1.52.0
        4. Always run with:  bundle exec ruby scrape.rb
    MSG
  end
end
