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
require 'net/http'
require 'uri'
require 'zip'

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

  # Path to the Chromium browser binary, based on the playwright-core
  # package's browsers.json metadata. Returns nil if not found.
  def self.chromium_browser_path
    browsers_json = File.join(NODE_MODULES, 'playwright-core', 'browsers.json')
    return nil unless File.file?(browsers_json)
    data = JSON.parse(File.read(browsers_json))
    chromium_entry = data['browsers']&.find { |b| b['name'] == 'chromium' }
    return nil unless chromium_entry
    revision = chromium_entry['revision']

    if Gem.win_platform?
      base = ENV['PLAYWRIGHT_BROWSERS_PATH'] || File.join(ENV['USERPROFILE'] || Dir.home, 'AppData', 'Local', 'ms-playwright')
      dir = File.join(base, "chromium-#{revision}")
      # Try the standard path first
      standard = File.join(dir, 'chrome-win', 'chrome.exe')
      return standard if File.file?(standard)
      # Fallback: search for chrome.exe anywhere in the revision folder
      # (extraction may be partial or use a different layout)
      find_chrome_exe(dir)
    else
      base = ENV['PLAYWRIGHT_BROWSERS_PATH'] || File.join(Dir.home, '.cache', 'ms-playwright')
      File.join(base, "chromium-#{revision}", 'chrome-linux', 'chrome')
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
    browsers_json = File.join(NODE_MODULES, 'playwright-core', 'browsers.json')
    return nil unless File.file?(browsers_json)
    data = JSON.parse(File.read(browsers_json))
    chromium_entry = data['browsers']&.find { |b| b['name'] == 'chromium' }
    return nil unless chromium_entry
    revision = chromium_entry['revision']

    if Gem.win_platform?
      base = ENV['PLAYWRIGHT_BROWSERS_PATH'] || File.join(ENV['USERPROFILE'] || Dir.home, 'AppData', 'Local', 'ms-playwright')
      {
        revision: revision,
        download_url: chromium_entry['downloadURL'] || "https://cdn.playwright.dev/dbazure/download/playwright/builds/chromium/#{revision}/chromium-win64.zip",
        dest_dir: File.join(base, "chromium-#{revision}"),
        marker_file: File.join(base, "chromium-#{revision}", 'INSTALLATION_COMPLETE')
      }
    else
      base = ENV['PLAYWRIGHT_BROWSERS_PATH'] || File.join(Dir.home, '.cache', 'ms-playwright')
      {
        revision: revision,
        download_url: chromium_entry['downloadURL'] || "https://cdn.playwright.dev/dbazure/download/playwright/builds/chromium/#{revision}/chromium-linux.zip",
        dest_dir: File.join(base, "chromium-#{revision}"),
        marker_file: File.join(base, "chromium-#{revision}", 'INSTALLATION_COMPLETE')
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

    # Already installed?
    return true if chromium_installed?

    # Clean up any partial extraction
    if File.directory?(dest_dir)
      FileUtils.rm_rf(dest_dir)
    end
    FileUtils.mkdir_p(dest_dir)

    zip_path = File.join(dest_dir, 'chromium.zip')

    puts "Downloading Chromium (revision #{info[:revision]})..."
    puts "  URL: #{download_url}"
    puts "  Dest: #{dest_dir}"

    # Follow redirects (the CDN returns 307) and stream the body to disk.
    # Net::HTTP does NOT follow 307/301/302 automatically.
    current_url = download_url
    max_redirects = 10
    total_bytes = 0
    downloaded_bytes = 0
    last_print = 0
    done = false

    File.open(zip_path, 'wb') do |f|
      until done
        uri = URI(current_url)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == 'https'
        http.read_timeout = 600

        request = Net::HTTP::Get.new(uri)
        request['User-Agent'] = 'Mozilla/5.0'

        response = http.request(request)

        code = response.code.to_i

        if [301, 302, 303, 307, 308].include?(code)
          location = response['Location']
          if location.nil? || location.strip.empty?
            raise "Download failed: redirect (HTTP #{code}) without Location header"
          end
          current_url = location.start_with?('http') ? location : URI.join(current_url, location).to_s
          puts "  Redirected to: #{current_url}"
          max_redirects -= 1
          raise "Download failed: too many redirects" if max_redirects <= 0
          next
        end

        if code != 200
          raise "Download failed: HTTP #{code}"
        end

        total_bytes = response['Content-Length'] ? response['Content-Length'].to_i : 0
        puts "  Size: #{(total_bytes / 1048576.0).round(1)} MB" if total_bytes > 0

        response.read_body do |chunk|
          f.write(chunk)
          downloaded_bytes += chunk.size
          now = Time.now.to_i
          if now - last_print >= 3
            if total_bytes > 0
              pct = (downloaded_bytes * 100 / total_bytes)
              print "\r  Downloaded: #{pct}% (#{(downloaded_bytes / 1048576.0).round(1)} MB)"
            else
              print "\r  Downloaded: #{(downloaded_bytes / 1048576.0).round(1)} MB)"
            end
            last_print = now
          end
        end

        done = true
      end
    end

    puts ""
    puts "  Download complete. Extracting..."

    # Extract the zip using rubyzip
    Zip.on_exists_proc = true
    Zip::File.open(zip_path) do |zip_file|
      zip_file.each do |entry|
        entry_path = File.join(dest_dir, entry.name)
        FileUtils.mkdir_p(File.dirname(entry_path))
        entry.extract(entry_path)
      end
    end

    # Clean up the zip
    File.delete(zip_path)

    # Write the marker file Playwright expects
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
    #
    # NOTE: Open3.capture3 returns THREE values: [stdout, stderr, status].
    # We must capture all three, otherwise the status object gets
    # replaced by the stderr string and .success? crashes.
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
