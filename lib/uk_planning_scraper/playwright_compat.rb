# frozen_string_literal: true

# Compatibility layer for playwright-ruby-client.
#
# The Ruby gem (playwright-ruby-client) does NOT bundle a Node CLI — it
# needs an external `playwright-core` Node package whose version matches
# the gem's COMPATIBLE_PLAYWRIGHT_VERSION constant. If the installed
# playwright-core is a different version, the gem looks for the wrong
# Chromium revision and fails with "Executable doesn't exist".
#
# This file:
#   1. Loads the gem (vendored or system).
#   2. Reads COMPATIBLE_PLAYWRIGHT_VERSION to find the exact Node CLI version.
#   3. Ensures playwright-core@<that version> is installed in node_modules.
#   4. Sets CLI_EXECUTABLE_PATH to the matching playwright-core binary.

require 'concurrent'
require 'base64'
require 'mime/types/data'
require 'mime/types'
require 'open3'
require 'fileutils'
require 'json'

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

module Playwright
  PROJECT_ROOT = File.expand_path('../..', __dir__)
  NODE_MODULES = File.join(PROJECT_ROOT, 'node_modules')

  # Read the version of playwright-core that this gem was built against.
  # @example "1.44.0" or "1.52.0"
  def self.compatible_cli_version
    return COMPATIBLE_PLAYWRIGHT_VERSION if defined?(COMPATIBLE_PLAYWRIGHT_VERSION)
    # Older gem versions may not define it — fall back to 1.44.0 (chromium-1076).
    '1.44.0'
  end

  # Path to the playwright-core CLI entry point (cli.js).
  # We use cli.js directly (invoked via `node`) instead of the .bin/.cmd
  # wrapper, because Ruby's system() calling a .cmd wrapper on Windows
  # can hang or fail to pass arguments correctly.
  def self.core_cli_path
    File.join(NODE_MODULES, 'playwright-core', 'cli.js')
  end

  # Read the version of the currently installed playwright-core package.
  def self.installed_core_version
    pkg = File.join(NODE_MODULES, 'playwright-core', 'package.json')
    return nil unless File.file?(pkg)
    json = JSON.parse(File.read(pkg))
    json['version']
  end

  # Ensure the correct playwright-core Node package is installed.
  # We chdir into PROJECT_ROOT and run `npm install` there, because
  # `npm install --prefix "path with spaces (parens)"` is unreliable on
  # Windows — npm truncates the path at spaces/parens and fails with EPERM.
  def self.ensure_matching_playwright_core!
    needed = compatible_cli_version
    installed = installed_core_version

    if installed == needed
      return needed
    end

    puts "Playwright version alignment:"
    puts "  Ruby gem needs:     playwright-core@#{needed}"
    puts "  Installed:          #{installed || 'none'}"
    puts "  Installing matching playwright-core..."

    # Run npm install from inside the project directory. We pass the
    # package spec as the sole argument and let npm use the cwd as the
    # project root. This avoids --prefix path-quoting issues entirely.
    stdout, status = Dir.chdir(PROJECT_ROOT) do
      Open3.capture3('npm', 'install', "playwright-core@#{needed}", '--no-save')
    end
    puts stdout[0]

    unless status.success?
      raise <<~MSG
        Failed to install playwright-core@#{needed}.

        Try running this manually from your project folder:
            npm install playwright-core@#{needed}

        If that also fails with EPERM, make sure:
          1. No other program (editor, antivirus) is locking the folder.
          2. You are running from the project directory (not the drive root).
          3. Try running the command prompt as Administrator.
      MSG
    end

    # Verify it actually installed correctly.
    actual = installed_core_version
    unless actual == needed
      raise "Installed playwright-core but version is #{actual}, expected #{needed}."
    end

    puts "  Installed playwright-core@#{needed} successfully."
    needed
  end

  # Make sure the correct playwright-core is installed, then set CLI path.
  ensure_matching_playwright_core!

  unless const_defined?(:CLI_EXECUTABLE_PATH, false)
    CLI_EXECUTABLE_PATH = core_cli_path
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
        3. Reinstall the gem:  gem install playwright-ruby-client
        4. Always run with:  bundle exec ruby scrape.rb
    MSG
  end
end
