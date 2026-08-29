# frozen_string_literal: true

# Compatibility layer for playwright-ruby-client.
#
# Ensures the Node playwright-core package version matches the Ruby gem,
# and that the correct Chromium browser binary AND all required helper
# tools (winldd on Windows, chromium-headless-shell) are downloaded
# and available.  This file runs at require time so every script that
# loads it gets a working browser automatically.

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

  # Read the browsers.json file from the installed playwright-core.
  def self.browsers_json
    path = File.join(NODE_MODULES, 'playwright-core', 'browsers.json')
    return nil unless File.file?(path)
    JSON.parse(File.read(path))
  end

  # Read a specific browser/tool revision from browsers.json.
  def self.browser_revision(name)
    data = browsers_json
    return nil unless data
    entry = data['browsers']&.find { |b| b['name'] == name }
    entry ? entry['revision'] : nil
  end

  def self.chromium_revision
    browser_revision('chromium')
  end

  def self.chromium_headless_shell_revision
    browser_revision('chromium-headless-shell')
  end

  def self.winldd_revision
    browser_revision('winldd')
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

  # Scan ALL chromium-* directories for a real chrome binary.
  # Returns the path to the first real binary found, or nil.
  def self.find_any_chromium_binary
    base = browsers_base_dir
    return nil unless File.directory?(base)

    # Prefer non-symlink directories first, then fallback to symlinks
    Dir.glob(File.join(base, 'chromium-*')).sort do |a, b|
      a_symlink = File.symlink?(a) ? 1 : 0
      b_symlink = File.symlink?(b) ? 1 : 0
      [a_symlink, File.basename(b)] <=> [b_symlink, File.basename(a)]
    end.each do |dir|
      if Gem.win_platform?
        exe = File.join(dir, 'chrome-win', 'chrome.exe')
        return exe if File.file?(exe)
        exe = find_chrome_exe(dir)
        return exe if exe
      else
        exe = File.join(dir, 'chrome-linux', 'chrome')
        return exe if File.file?(exe)
      end
    end
    nil
  end

  # Create symlinks for ALL missing chromium-* revision directories
  # by pointing them to the directory that has the real binary.
  def self.ensure_all_chromium_symlinks!
    base = browsers_base_dir
    return unless File.directory?(base)

    real_dir = nil
    Dir.glob(File.join(base, 'chromium-*')).each do |dir|
      next if File.symlink?(dir)
      has_binary = if Gem.win_platform?
        File.file?(File.join(dir, 'chrome-win', 'chrome.exe')) || !!find_chrome_exe(dir)
      else
        File.file?(File.join(dir, 'chrome-linux', 'chrome'))
      end
      real_dir = dir if has_binary && real_dir.nil?
    end

    return unless real_dir

    Dir.glob(File.join(base, 'chromium-*')).each do |dir|
      next if File.symlink?(dir)
      next if dir == real_dir

      has_binary = if Gem.win_platform?
        File.file?(File.join(dir, 'chrome-win', 'chrome.exe')) || !!find_chrome_exe(dir)
      else
        File.file?(File.join(dir, 'chrome-linux', 'chrome'))
      end

      unless has_binary
        FileUtils.rm_rf(dir) if File.directory?(dir)
        if Gem.win_platform?
          system('cmd', '/c', 'mklink', '/J', dir, real_dir)
        else
          FileUtils.ln_s(real_dir, dir)
        end
        puts "  Linked #{dir} -> #{real_dir}"
      end
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

  # Path to the chromium-headless-shell binary (used by newer Playwright versions).
  def self.chromium_headless_shell_path
    revision = chromium_headless_shell_revision
    return nil unless revision

    dir = File.join(browsers_base_dir, "chromium_headless_shell-#{revision}")

    if Gem.win_platform?
      File.join(dir, 'chrome-win', 'headless_shell.exe')
    else
      File.join(dir, 'chrome-linux', 'headless_shell')
    end
  end

  def self.chromium_headless_shell_installed?
    path = chromium_headless_shell_path
    !path.nil? && File.file?(path)
  end

  # Path to the winldd PrintDeps.exe binary (Windows-only dependency tool).
  def self.winldd_path
    revision = winldd_revision
    return nil unless revision
    File.join(browsers_base_dir, "winldd-#{revision}", 'PrintDeps.exe')
  end

  def self.winldd_installed?
    return false unless Gem.win_platform?
    path = winldd_path
    !path.nil? && File.file?(path)
  end

  # Build the download info hash for any browser/tool entry from browsers.json.
  def self.download_info_for(name)
    data = browsers_json
    return nil unless data
    entry = data['browsers']&.find { |b| b['name'] == name }
    return nil unless entry

    revision = entry['revision']
    base_url = entry['downloadURL'] || "https://cdn.playwright.dev/dbazure/download/playwright/builds"

    # Determine the platform-specific download URL and archive name.
    platform_suffix = Gem.win_platform? ? 'win64' : 'linux'
    url = "#{base_url}/#{name}/#{revision}/#{name}-#{platform_suffix}.zip"

    # The directory name convention differs per tool.
    dir_name = case name
               when 'chromium' then "chromium-#{revision}"
               when 'chromium-headless-shell' then "chromium_headless_shell-#{revision}"
               when 'winldd' then "winldd-#{revision}"
               else "#{name}-#{revision}"
               end

    {
      name: name,
      revision: revision,
      download_url: url,
      dest_dir: File.join(browsers_base_dir, dir_name),
      marker_file: File.join(browsers_base_dir, dir_name, 'INSTALLATION_COMPLETE')
    }
  end

  def self.chromium_download_info
    download_info_for('chromium')
  end

  # Generic download-and-extract for any browser/tool entry.
  def self.install_tool_ruby!(name)
    info = download_info_for(name)
    raise "Could not read download info for #{name} from browsers.json" unless info

    dest_dir = info[:dest_dir]
    marker = info[:marker_file]
    download_url = info[:download_url]

    # Check if already installed (by binary presence, not just marker).
    installed_check = case name
                      when 'chromium' then chromium_installed?
                      when 'chromium-headless-shell' then chromium_headless_shell_installed?
                      when 'winldd' then winldd_installed?
                      else File.file?(marker)
                      end
    return true if installed_check

    if File.directory?(dest_dir)
      FileUtils.rm_rf(dest_dir)
    end
    FileUtils.mkdir_p(dest_dir)

    zip_path = File.join(dest_dir, "#{name}.zip")

    puts "Downloading #{name} (revision #{info[:revision]})..."
    puts "  URL: #{download_url}"
    puts "  Dest: #{dest_dir}"

    total = 0
    last_print = [0]

    begin
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
    rescue OpenURI::HTTPError => e
      # Some tools (e.g. winldd on non-Windows, or chromium-headless-shell
      # on older revisions) may not have a download available for this
      # platform.  That's OK — skip gracefully.
      puts "  ⚠️  No download available for #{name} on this platform (#{e.message}). Skipping."
      FileUtils.rm_rf(dest_dir) if File.directory?(dest_dir)
      return false
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
    true
  end

  # Backwards-compatible alias.
  def self.install_chromium_ruby!
    install_tool_ruby!('chromium')
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

    link_revision = lambda do |name, expected_revision|
      next unless expected_revision

      expected_dir = File.join(base, "#{name == 'chromium-headless-shell' ? 'chromium_headless_shell' : name}-#{expected_revision}")

      # Check if the binary already exists at the expected revision.
      binary_check = case name
                     when 'chromium'
                       path = File.join(expected_dir, 'chrome-win', 'chrome.exe')
                       path = find_chrome_exe(expected_dir) unless Gem.win_platform? && File.file?(path)
                       path && File.file?(path)
                     when 'winldd'
                       File.file?(File.join(expected_dir, 'PrintDeps.exe'))
                     else
                       File.directory?(expected_dir)
                     end
      next if binary_check

      # Scan for any folder matching this tool that has the real binary.
      pattern = case name
                when 'chromium' then 'chromium-*'
                when 'chromium-headless-shell' then 'chromium_headless_shell-*'
                when 'winldd' then 'winldd-*'
                else "#{name}-*"
                end

      Dir.glob(File.join(base, pattern)).each do |existing_dir|
        next if existing_dir == expected_dir

        has_binary = case name
                     when 'chromium'
                       f = File.join(existing_dir, 'chrome-win', 'chrome.exe')
                       f = find_chrome_exe(existing_dir) unless Gem.win_platform? && File.file?(f)
                       f && File.file?(f)
                     when 'winldd'
                       File.file?(File.join(existing_dir, 'PrintDeps.exe'))
                     else
                       File.directory?(existing_dir)
                     end
        next unless has_binary

        if File.directory?(expected_dir) || File.symlink?(expected_dir)
          FileUtils.rm_rf(expected_dir)
        end

        if Gem.win_platform?
          system('cmd', '/c', 'mklink', '/J', expected_dir, existing_dir)
        else
          FileUtils.ln_s(existing_dir, expected_dir)
        end

        puts "  Linked #{expected_dir} -> #{existing_dir}"
        break
      end
    end

    link_revision.call('chromium', chromium_revision)
    link_revision.call('chromium-headless-shell', chromium_headless_shell_revision)
    link_revision.call('winldd', winldd_revision) if Gem.win_platform?
  end

  # Full browser setup: align node package, download browser + tools if
  # missing, create symlinks for revision mismatches. Called at load time.
  def self.ensure_browser!
    # Step 1: Align the Node playwright-core package to the gem version.
    ensure_matching_playwright_core!

    # Step 2: Set CLI_EXECUTABLE_PATH to the wrapper.
    if const_defined?(:CLI_EXECUTABLE_PATH, false)
      remove_const(:CLI_EXECUTABLE_PATH)
    end
    const_set(:CLI_EXECUTABLE_PATH, cli_wrapper_path)

    # Step 3: Check what's missing. We must NOT return early just because
    # Chromium exists — winldd or chromium-headless-shell may still be
    # missing, which causes "Executable doesn't exist" errors at runtime.
    chromium_ok = chromium_installed?
    winldd_ok = Gem.win_platform? ? winldd_installed? : true

    # Also check if ANY chromium binary exists (even under a different revision)
    any_chrome = find_any_chromium_binary

    if chromium_ok && winldd_ok
      puts "Chromium is already installed at: #{chromium_browser_path}"
      return
    end

    # If the specific revision isn't found but another revision's binary
    # exists, create symlinks for ALL missing revision directories
    if !chromium_ok && any_chrome
      puts "Chromium revision mismatch detected. Creating symlinks for all missing revisions..."
      ensure_all_chromium_symlinks!
      ensure_browser_symlinks!
      chromium_ok = chromium_installed?
      if chromium_ok
        puts "Chromium linked to existing revision at: #{chromium_browser_path}"
        return if winldd_ok
      end
    end

    # Step 4: Try symlinking from existing browsers/tools under different
    # revisions before downloading anything.
    ensure_browser_symlinks!

    chromium_ok = chromium_installed?
    winldd_ok = Gem.win_platform? ? winldd_installed? : true

    if chromium_ok && winldd_ok
      puts "Chromium linked to existing revision at: #{chromium_browser_path}"
      return
    end

    # Step 5: Download whatever is still missing.
    unless chromium_ok
      puts "Chromium browser not found. Downloading now..."
      begin
        install_tool_ruby!('chromium')
      rescue => e
        puts "Ruby-based Chromium download failed: #{e.class} - #{e.message}"
        puts "Trying Node CLI to install chromium..."
        cli = core_cli_path
        system('node', cli, 'install', 'chromium') if File.file?(cli)
      end
    end

    # chromium-headless-shell is optional — scrapers use headless: false.
    # Try to install it but don't block if it fails.
    unless chromium_headless_shell_installed?
      puts "chromium-headless-shell not found. Attempting download (optional)..."
      begin
        install_tool_ruby!('chromium-headless-shell')
      rescue => e
        puts "chromium-headless-shell download failed (non-blocking): #{e.class} - #{e.message}"
      end
    end

    if Gem.win_platform? && !winldd_ok
      puts "winldd (PrintDeps.exe) not found. Downloading now..."
      begin
        install_tool_ruby!('winldd')
      rescue => e
        puts "winldd download failed: #{e.class} - #{e.message}"
        puts "Trying Node CLI..."
        cli = core_cli_path
        system('node', cli, 'install', 'winldd') if File.file?(cli)
      end
    end

    # Re-run symlinks in case downloads created new revision folders.
    ensure_browser_symlinks!

    # Final verification — only chromium and winldd are required.
    missing = []
    missing << 'chromium' unless chromium_installed?
    missing << 'winldd' if Gem.win_platform? && !winldd_installed?

    if missing.any?
      warn "WARNING: Required Playwright components could not be installed: #{missing.join(', ')}"
      warn "Run manually: node node_modules/playwright-core/cli.js install"
    else
      puts "Chromium is ready at: #{chromium_browser_path}"
      puts "chromium-headless-shell: #{chromium_headless_shell_installed? ? 'installed' : 'not installed (optional, scrapers use headless: false)'}"
    end
  end

  # Monkey-patch BrowserType#launch to always pass executablePath
  # so Playwright never looks for a revision-specific directory that
  # might not exist (the gem's expected revision can differ from
  # the Node playwright-core's browsers.json revision).
  def self.patch_browser_launch!
    return if @browser_launch_patched
    @browser_launch_patched = true

    return unless defined?(::Playwright::BrowserType)

    browser_type_class = ::Playwright::BrowserType
    original_launch = browser_type_class.instance_method(:launch)

    browser_type_class.define_method(:launch) do |**opts|
      exe_path = ::Playwright.find_any_chromium_binary
      if exe_path && File.file?(exe_path)
        unless opts.key?(:executablePath) || opts.key?(:executable_path)
          opts[:executablePath] = exe_path
        end
      end
      original_launch.bind(self).call(**opts)
    end

    puts "Patched BrowserType#launch to use explicit executablePath" if ENV['PW_DEBUG']
  end

  # Run the full browser setup at load time.
  ensure_browser!

  # After browser setup, patch the launch method
  patch_browser_launch!

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
