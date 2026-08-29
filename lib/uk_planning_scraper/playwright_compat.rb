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
#   4. Sets CLI_EXECUTABLE_PATH to a wrapper that invokes cli.js via node
#      (fixes Errno::ENOEXEC on Windows where .js files can't be exec'd directly).
#   5. Creates directory junctions so the gem finds the browser binary
#      at the revision it expects, even if the actual browser was installed
#      under a different revision number.

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

  # Read the version of playwright-core that this gem was built against.
  # @example "1.44.0" or "1.52.0"
  def self.compatible_cli_version
    return COMPATIBLE_PLAYWRIGHT_VERSION if defined?(COMPATIBLE_PLAYWRIGHT_VERSION)
    '1.52.0'
  end

  # Path to the playwright-core CLI entry point (cli.js).
  def self.core_cli_path
    File.join(NODE_MODULES, 'playwright-core', 'cli.js')
  end

  # On Windows, the gem tries to execute cli.js directly, which fails with
  # Errno::ENOEXEC because Windows can't run .js files without node.
  # We create a .bat wrapper that invokes `node cli.js` and pass that path
  # to the gem via CLI_EXECUTABLE_PATH.
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
      # On non-Windows, the shebang in cli.js works fine.
      core_cli_path
    end
  end

  # The base directory where Playwright stores browser binaries.
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

  # Path to the Chromium browser binary, based on the playwright-core
  # package's browsers.json metadata. Returns nil if not found.
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

  # Recursively find chrome.exe / chrome binary in a directory
  def self.find_chrome_exe(dir)
    return nil unless File.directory?(dir)
    Dir.glob(File.join(dir, '**', 'chrome{.exe,}')).first
  end

  # Check if the Chromium browser binary already exists on disk.
  def self.chromium_installed?
    path = chromium_browser_path
    !path.nil? && File.file?(path)
  end

  # Read the Chromium download URL and revision from browsers.json
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

  # Read the version of the currently installed playwright-core package.
  def self.installed_core_version
    pkg = File.join(NODE_MODULES, 'playwright-core', 'package.json')
    return nil unless File.file?(pkg)
    json = JSON.parse(File.read(pkg))
    json['version']
  end

  # Ensure the correct playwright-core Node package is installed.
  # If the installed version already matches the gem's compatible version,
  # do nothing. If not, install the matching version.
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

    stdout, stderr, status = Dir.chdir(PROJECT_ROOT) do
      Open3.capture3('npm', 'install', "playwright-core@#{needed}", '--no-save')
    end
    puts stdout
    warn stderr unless stderr.to_s.strip.empty?

    unless status.success?
      raise <<~MSG
        Failed to install playwright-core@#{needed}.

        Try running this manually from your project folder:
            npm install playwright-core@#{needed}
      MSG
    end

    actual = installed_core_version
    unless actual == needed
      raise "Installed playwright-core but version is #{actual}, expected #{needed}."
    end

    puts "  Installed playwright-core@#{needed} successfully."
    needed
  end

  # Create directory junctions/symlinks so the gem finds the browser binary
  # at the revision it expects, even if the actual browser was installed
  # under a different revision number.
  #
  # The gem reads COMPATIBLE_PLAYWRIGHT_VERSION and internally knows which
  # browser revision it expects (e.g. 1076 for playwright 1.44.0). But the
  # installed playwright-core may specify a different revision in its
  # browsers.json (e.g. 1169 for playwright 1.52.0). After ensure_matching_playwright_core!
  # aligns the package version, the browsers.json should match. But if the
  # browser was already downloaded under the OLD revision, we need to link
  # the new revision name to the old directory so the gem finds it.
  def self.ensure_browser_symlinks!
    base = browsers_base_dir
    return unless File.directory?(base)

    actual_revision = chromium_revision
    return unless actual_revision

    actual_dir = File.join(base, "chromium-#{actual_revision}")
    actual_binary = File.join(actual_dir, 'chrome-win', 'chrome.exe') if Gem.win_platform?
    actual_binary ||= File.join(actual_dir, 'chrome-linux', 'chrome') unless Gem.win_platform?
    actual_binary ||= find_chrome_exe(actual_dir)

    # If the actual browser binary exists, we're good — no symlink needed.
    return if actual_binary && File.file?(actual_binary)

    # The browser doesn't exist at the expected revision. Scan the base
    # directory for any chromium-* folder that actually contains a binary,
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

      # Found a real browser in a different revision folder — link it.
      if File.directory?(actual_dir) || File.symlink?(actual_dir)
        FileUtils.rm_rf(actual_dir)
      end

      if Gem.win_platform?
        # Use mklink /J for directory junctions (doesn't require admin rights)
        system('cmd', '/c', 'mklink', '/J', actual_dir, existing_dir)
      else
        FileUtils.ln_s(existing_dir, actual_dir)
      end

      puts "  Linked #{actual_dir} -> #{existing_dir}"
      break
    end
  end

  # Make sure the correct playwright-core is installed, then set CLI path.
  ensure_matching_playwright_core!

  # Create the wrapper and set CLI_EXECUTABLE_PATH to it.
  # Use remove_const to override if the gem already defined it.
  if const_defined?(:CLI_EXECUTABLE_PATH, false)
    remove_const(:CLI_EXECUTABLE_PATH)
  end
  CLI_EXECUTABLE_PATH = cli_wrapper_path

  # Create browser symlinks/junctions so the gem finds the browser binary.
  ensure_browser_symlinks!

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
