# frozen_string_literal: true
# Compatibility shim for playwright-ruby-client.
#
# 1. Loads the playwright-ruby-client gem and verifies that all the
#    internal classes Playwright.create depends on are actually defined.
# 2. Ensures Playwright::Error and Playwright::TimeoutError exist.
# 3. Provides a single, reliable playwright_cli_executable_path so every
#    scraper calls Playwright.create with the same, correct value.
# 4. Does NOT override Playwright.create — the gem provides it natively.

require 'playwright'

# The gem's main file should load these, but on some Windows setups the
# require chain fails partway and leaves Playwright::Transport undefined.
# Load them explicitly and hard-fail if they're still missing.
%w[
  playwright/transport
  playwright/connection
  playwright/playwright_api
].each do |f|
  begin
    require f
  rescue LoadError => e
    warn "FATAL: could not load '#{f}': #{e.message}"
    warn "The playwright-ruby-client gem may be incompletely installed."
    warn "Try: bundle install"
    raise
  end
end

module Playwright
  unless defined?(::Playwright::Error)
    class Error < StandardError; end
  end

  unless defined?(::Playwright::TimeoutError)
    class TimeoutError < StandardError; end
  end

  # Verify that the gem's internals are loaded. If Transport or Connection
  # is missing, Playwright.create will fail at runtime with a confusing
  # NameError. Fail fast here with an actionable message instead.
  unless defined?(::Playwright::Transport)
    raise LoadError,
          "Playwright::Transport is not defined after loading the gem. " \
          "Reinstall the 'playwright-ruby-client' gem: gem uninstall playwright-ruby-client && bundle install"
  end
  unless defined?(::Playwright::Connection)
    raise LoadError,
          "Playwright::Connection is not defined after loading the gem. " \
          "Reinstall the 'playwright-ruby-client' gem: gem uninstall playwright-ruby-client && bundle install"
  end

  # Sanity check: the gem must provide Playwright.create.
  # module_function methods are private, so we check with include_all = true.
  unless respond_to?(:create, true)
    raise LoadError,
          "Playwright.create is not available. The 'playwright-ruby-client' gem " \
          "may be missing or too old. Run: bundle install"
  end

  # Resolve the CLI executable path once at load time.
  # Prefer the local node_modules/.bin/playwright-core (the gem's recommended
  # approach), then fall back to playwright, then npx as a last resort.
  CLI_EXECUTABLE_PATH = begin
    root = File.expand_path('../../..', __dir__) # project root
    candidates = [
      File.join(root, 'node_modules', '.bin', 'playwright-core'),
      File.join(root, 'node_modules', '.bin', 'playwright'),
    ]
    found = candidates.find { |p| File.executable?(p) }
    found || 'npx playwright'
  end.freeze
end
