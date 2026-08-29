# frozen_string_literal: true

# Compatibility layer for playwright-ruby-client.
#
# Ensures the Node playwright-core package version matches the Ruby gem,
# and that the correct Chromium browser binary is downloaded and available.
# This file runs at require time so every script that loads it gets a
# working browser automatically.

require 'concurrent'
require 'base64'
require 'mime/types/data'
require 'mime/types'
require 'open3'
require 'fileutils'
require 'json'
require 'net/http'
require 'uri'
require 'zip'
require 'open-uri'

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

  # The version the Ruby gem needs. This comes from the gem's own
  # COMPATIBLE_PLAYWRIGHT_VERSION constant. If not defined, fall back
  # to the version pinned in package.json / Gemfile.
  def self.compatible_cli_version
    return COMPATIBLE_PLAYWRIGHT_VERSION if defined?(COMPATIBLE_PLAYWRIGHT_VERSION)
    '1.52.0'
  end

  def self.core_cli_path
    File.join(NODE_MODULES, 'playwright-core', 'cli.js')
  end

  # Windows can't execute .js files directly, so we create a .bat wrapper.
  def self.cli_wrapper_path
    wrapper_dir = File.join(PROJECT_ROOT, 'bin')
    FileUtils.mkdir_p(wrapper_dir) unless File.directory?(wrapper_dir)

    if Gem.win_platform?
      wrapper = File.join(wrapper_dir, 'playwright-cli-wrapper.bat')
      cli = core_cli_path.gsub('/', '\\')
      unless File.file?(wrapper) && File.read(wrapper) =~ /#{Regexp.escape(cli)}/
        File.write(wrapper, "@echo off\r\nnode \"#{cli}\" %*\r\n")
      end
      wrapper
    else
      core_cli_path
    end
  end

  def self.browsers_base_dir
    if Gem.win_platform?
      ENV['PLAYWRIGHT_BROWSERS_PATH'] || File.join(ENV['USERPROFILE'] || Dir.home, 'AppData', 'Local', 'ms-playwright')
    else
      ENV['PLAYWRIGHT_BROWSERS_PATH'] || File.join(Dir.home, '.cache', 'ms-playwright')
    end
  end

  # Read the Chromium revision from the installed playwright-core's browsers.json.
  def self.chromium_revision
    browsers_json = File.join(NODE_MODULES, 'playwright-core', 'browsers.json')
    return nil unless File.file?(browsers_json)
    data = JSON.parse(File.read(browsers_json))
    chromium_entry = data['browsers']&.find { |b| b['name'] == 'chromium' }
    chromium_entry ? chromium_entry['revision'] : nil
  end

  # Path to the Chromium browser binary.
  def self.chromium_browser_path
    revision = chromium_revision
    return nil unless revision

    dir = File.join(browsers_base_dir, "chromium-#{revision}")

    if Gem.win_platform?
      standard = File.join(dir, 'chrome-win', 'chrome.exe')
      return standard if File.file?(standard)
      find_chrome_exe(dir)
    else
      File.join(dir, 'chrome-linux', 'chrome')
    end
  end

  def self.find_chrome_exe(dir)
    return nil unless File.directory?(dir)
    Dir.glob(File.join(dir, '**', 'chrome{.exe,}')).first
  end

  def self.chromium_installed?
    path = chromium_browser_path
    !path.nil? && File.file?(path)
  end

  def self.chromium_download_info
    revision = chromium_revision
    return nil unless revision

    browsers_json = File.join(NODE_MODULES, 'playwright-core', 'browsers.json')
    data = JSON.parse(File.read(browsers_json))
    chromium_entry = data['browsers']&.find { |b| b['name'] == 'chromium' }

    if Gem.win_platform?
      {
        revision: revision,
        download_url: chromium_entry['downloadURL'] || "https://cdn.playwright.dev/dbazure/download/playwright/builds/chromium/#{revision}/chromium-win64.zip",
        dest_dir: File.join(browsers_base_dir, "chromium-#{revision}"),
        marker_file: File.join(browsers_base_dir, "chromium-#{revision}", 'INSTALLATION_COMPLETE')
      }
    else
      {
        revision: revision,
        download_url: chromium_entry['downloadURL'] || "https://cdn.playwright.dev/dbazure/download/playwright/builds/chromium/#{revision}/chromium-linux.zip",
        dest_dir: File.join(browsers_base_dir, "chromium-#{revision}"),
        marker_file: File.join(browsers_base_dir, "chromium-#{revision}", 'INSTALLATION_COMPLETE')
      }
    end
  end

  # Download and extract Chromium entirely in Ruby, bypassing the Node CLI
  # which hangs during zip extraction on some Windows systems.
  def self.install_chromium_ruby!
    info = chromium_download_info
    raise "Could not read Chromium download info from browsers.json" unless info

    dest_dir = info[:dest_dir]
    marker = info[:marker_file]
    download_url = info[:download_url]

    return true if chromium_installed?

    if File.directory?(dest_dir)
      FileUtils.rm_rf(dest_dir)
    end
    FileUtils.mkdir_p(dest_dir)

    zip_path = File.join(dest_dir, 'chromium.zip')

    puts "Downloading Chromium (revision #{info[:revision]})..."
    puts "  URL: #{download_url}"
    puts "  Dest: #{dest_dir}"

    total = 0
    last_print = [0]

    URI.open(download_url, 'rb',
      'User-Agent' => 'Mozilla/5.0',
      read_timeout: 600,
      content_length_proc: ->(len) { total = len.to_i },
      progress_proc: ->(size) {
        now = Time.now.to_i
        if now - last_print[0] >= 3
          if total > 0
            pct = (size * 100 / total)
            print "\r  Downloaded: #{pct}% (#{(size / 1048576.0).round(1)} MB)"
          else
            print "\r  Downloaded: #{(size / 1048576.0).round(1)} MB"
          end
          last_print[0] = now
        end
      }
    ) do |response|
      puts "  Size: #{(total / 1048576.0).round(1)} MB" if total > 0
      File.open(zip_path, 'wb') do |f|
        while (chunk = response.read(65536))
          f.write(chunk)
        end
      end
    end

    puts ""
    puts "  Download complete. Extracting..."

    Zip.on_exists_proc = true
    Zip::File.open(zip_path) do |zip_file|
      zip_file.each do |entry|
        entry_path = File.join(dest_dir, entry.name)
        FileUtils.mkdir_p(File.dirname(entry_path))
        entry.extract(entry_path)
      end
    end

    File.delete(zip_path)
    File.write(marker, Time.now.to_s)

    puts "  Extraction complete."
    puts "  Chromium installed at: #{chromium_browser_path}"
    true
  end

  def self.installed_core_version
    pkg = File.join(NODE_MODULES, 'playwright-core', 'package.json')
    return nil unless File.file?(pkg)
    json = JSON.parse(File.read(pkg))
    json['version']
  end

  # Ensure the Node playwright-core package matches the gem's version.
  def self.ensure_matching_playwright_core!
    needed = compatible_cli_version
    installed = installed_core_version

    return needed if installed == needed

    puts "Playwright version alignment:"
    puts "  Ruby gem needs:     playwright-core@#{needed}"
    puts "  Installed:          #{installed || 'none'}"
    puts "  Installing matching playwright-core..."

    stdout, stderr, status = Dir.chdir(PROJECT_ROOT) do
      Open3.capture3('npm', 'install', "playwright-core@#{needed}", '--no-save')
    end
    puts stdout
    warn stderr unless stderr.to_s.strip.empty?

    unless status.success?
      raise "Failed to install playwright-core@#{needed}. Try: npm install playwright-core@#{needed}"
    end

    actual = installed_core_version
    unless actual == needed
      raise "Installed playwright-core but version is #{actual}, expected #{needed}."
    end

    puts "  Installed playwright-core@#{needed} successfully."
    needed
  end

  # Create directory junctions/symlinks so the gem finds the browser binary
  # at the revision it expects, even if the browser was downloaded under
  # a different revision number.
  def self.ensure_browser_symlinks!
    base = browsers_base_dir
    return unless File.directory?(base)

    actual_revision = chromium_revision
    return unless actual_revision

    actual_dir = File.join(base, "chromium-#{actual_revision}")
    actual_binary = if Gem.win_platform?
      File.join(actual_dir, 'chrome-win', 'chrome.exe')
    else
      File.join(actual_dir, 'chrome-linux', 'chrome')
    end
    actual_binary = find_chrome_exe(actual_dir) unless actual_binary && File.file?(actual_binary)

    # If the browser binary exists at the expected revision, we're done.
    return if actual_binary && File.file?(actual_binary)

    # Scan for any chromium-* folder that contains a real binary,
    # and create a junction/symlink from the expected revision to it.
    Dir.glob(File.join(base, 'chromium-*')).each do |existing_dir|
      next if existing_dir == actual_dir

      binary = if Gem.win_platform?
        File.join(existing_dir, 'chrome-win', 'chrome.exe')
      else
        File.join(existing_dir, 'chrome-linux', 'chrome')
      end
      binary = find_chrome_exe(existing_dir) unless File.file?(binary)
      next unless binary && File.file?(binary)

      if File.directory?(actual_dir) || File.symlink?(actual_dir)
        FileUtils.rm_rf(actual_dir)
      end

      if Gem.win_platform?
        system('cmd', '/c', 'mklink', '/J', actual_dir, existing_dir)
      else
        FileUtils.ln_s(existing_dir, actual_dir)
      end

      puts "  Linked #{actual_dir} -> #{existing_dir}"
      break
    end
  end

  # Full browser setup: align node package, download browser if missing,
  # create symlinks for revision mismatches. Called at load time.
  def self.ensure_browser!
    # Step 1: Align the Node playwright-core package to the gem version.
    ensure_matching_playwright_core!

    # Step 2: Set CLI_EXECUTABLE_PATH to the wrapper.
    if const_defined?(:CLI_EXECUTABLE_PATH, false)
      remove_const(:CLI_EXECUTABLE_PATH)
    end
    CLI_EXECUTABLE_PATH = cli_wrapper_path

    # Step 3: If the browser already exists at the right revision, we're done.
    if chromium_installed?
      puts "Chromium is already installed at: #{chromium_browser_path}"
      return
    end

    # Step 4: Try symlinking from an existing browser under a different revision.
    ensure_browser_symlinks!
    return if chromium_installed?

    # Step 5: No browser exists anywhere — download it.
    puts "Chromium browser not found. Downloading now..."
    begin
      install_chromium_ruby!
      ensure_browser_symlinks!
    rescue => e
      # Ruby download failed — try the Node CLI as fallback.
      puts "Ruby-based download failed: #{e.class} - #{e.message}"
      puts "Trying Node CLI to install chromium..."
      cli = core_cli_path
      if File.file?(cli)
        system('node', cli, 'install', 'chromium')
        ensure_browser_symlinks!
      end
    end

    unless chromium_installed?
      warn "WARNING: Chromium browser could not be installed automatically."
      warn "Run manually: node node_modules/playwright-core/cli.js install chromium"
    end
  end

  # Run the full browser setup at load time.
  ensure_browser!

  unless respond_to?(:create)
    raise <<~MSG
      Playwright.create is not defined.

      The playwright-ruby-client gem could not be loaded properly.
      Possible fixes:
        1. Run:  bundle install
        2. If using vendored gems, ensure the vendor/ directory exists.
        3. Reinstall the gem:  gem install playwright-ruby-client
        4. Always run with:  bundle exec ruby scrape.rb
    MSG
  end
end
