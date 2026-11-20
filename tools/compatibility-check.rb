#!/usr/bin/env ruby
# Checks the compatibility database in site/_apps: every app file's front matter, its reports and
# screenshots, and that site/ holds nothing but text the site is built from.
#
#   ruby tools/compatibility-check.rb
#
# Exits non-zero, naming the file, at the first problem it finds in each file. Standard library only,
# and no network access.

require "date"
require "yaml"

ROOT = File.expand_path("..", __dir__)
SITE = File.join(ROOT, "site")
APPS = File.join(SITE, "_apps")

APP_KEYS = %w[name platform kind developer reports].freeze
APP_REQUIRED = %w[name platform kind reports].freeze
REPORT_KEYS = %w[date bridge32 pr guest app_version level source notes screenshots].freeze
REPORT_REQUIRED = %w[date bridge32 level source notes].freeze
SCREENSHOT_KEYS = %w[url caption].freeze

PLATFORMS = %w[ios macos].freeze
KINDS = %w[app game].freeze
GUESTS = %w[armv6 armv7 i386 ppc].freeze
SOURCES = %w[pr commit readme screenshot].freeze

SCREENSHOT_FORMS = [
  %r{\Ahttps://github\.com/user-attachments/assets/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z},
  %r{\Ahttps://github\.com/colemancda/Bridge32/assets/\d+/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z},
  %r{\Ahttps://user-images\.githubusercontent\.com/\d+/[A-Za-z0-9._-]+\z}
].freeze

SITE_EXTENSIONS = %w[.md .yml .html .css].freeze
SITE_NAMES = %w[Gemfile .gitignore].freeze
# Build products and installed gems, which site/.gitignore keeps out of the repository.
SITE_IGNORED = %w[_site .jekyll-cache .bundle vendor Gemfile.lock].freeze

ROMAN = { "ii" => "2", "iii" => "3", "iv" => "4", "v" => "5", "vi" => "6",
          "vii" => "7", "viii" => "8", "ix" => "9", "x" => "10" }.freeze

class CheckError < StandardError; end

# An app's file name: lowercase ASCII, runs of anything else as one hyphen, Roman numerals as numbers.
def slug(name)
  ascii = name.unicode_normalize(:nfkd).encode("ASCII", invalid: :replace, undef: :replace, replace: "")
  words = ascii.downcase.split(/[^a-z0-9]+/).reject(&:empty?)
  words.map { |word| ROMAN.fetch(word, word) }.join("-")
end

def front_matter(text)
  match = text.match(/\A---\s*\n(.*?)\n---\s*(\n|\z)/m)
  raise CheckError, "has no front matter" unless match

  data = begin
    YAML.safe_load(match[1], permitted_classes: [Date])
  rescue Psych::Exception => e
    raise CheckError, "front matter doesn't parse: #{e.message}"
  end
  raise CheckError, "front matter isn't a mapping" unless data.is_a?(Hash)

  data
end

def check_keys(hash, allowed, required, where)
  raise CheckError, "#{where} isn't a mapping" unless hash.is_a?(Hash)

  unknown = hash.keys - allowed
  raise CheckError, "#{where} has a key this format doesn't define: #{unknown.join(', ')}" unless unknown.empty?

  missing = required.reject { |key| hash.key?(key) && !hash[key].nil? }
  raise CheckError, "#{where} is missing #{missing.join(', ')}" unless missing.empty?
end

def check_value(value, allowed, what)
  raise CheckError, "#{what} is #{value.inspect}, not one of #{allowed.join(', ')}" unless allowed.include?(value)
end

def check_report(report, where, urls, file)
  check_keys(report, REPORT_KEYS, REPORT_REQUIRED, where)

  raise CheckError, "#{where}: date #{report['date'].inspect} isn't a date" unless report["date"].is_a?(Date)
  unless report["bridge32"].is_a?(String) && report["bridge32"].match?(/\A[0-9a-f]{8}\z/)
    raise CheckError, "#{where}: bridge32 #{report['bridge32'].inspect} isn't a quoted string of 8 hexadecimal characters"
  end
  if report.key?("pr") && !(report["pr"].is_a?(Integer) && report["pr"].positive?)
    raise CheckError, "#{where}: pr #{report['pr'].inspect} isn't a positive integer"
  end
  check_value(report["guest"], GUESTS, "#{where}: guest") if report.key?("guest")
  if report.key?("app_version") && !report["app_version"].is_a?(String)
    raise CheckError, "#{where}: app_version #{report['app_version'].inspect} isn't a quoted string"
  end
  unless report["level"].is_a?(Integer) && (1..5).cover?(report["level"])
    raise CheckError, "#{where}: level #{report['level'].inspect} isn't an integer from 1 to 5"
  end
  check_value(report["source"], SOURCES, "#{where}: source")
  raise CheckError, "#{where}: notes aren't text" unless report["notes"].is_a?(String) && !report["notes"].strip.empty?
  raise CheckError, "#{where}: source is pr but there's no pr" if report["source"] == "pr" && !report.key?("pr")

  return unless report.key?("screenshots")

  shots = report["screenshots"]
  raise CheckError, "#{where}: screenshots isn't a list" unless shots.is_a?(Array) && !shots.empty?
  raise CheckError, "#{where} has screenshots but no pr" unless report.key?("pr")

  shots.each_with_index do |shot, index|
    shot_where = "#{where}, screenshot #{index + 1}"
    check_keys(shot, SCREENSHOT_KEYS, SCREENSHOT_KEYS, shot_where)
    url = shot["url"]
    unless url.is_a?(String) && SCREENSHOT_FORMS.any? { |form| form.match?(url) }
      raise CheckError, "#{shot_where}: #{url.inspect} isn't a pull request attachment URL"
    end
    raise CheckError, "#{shot_where}: #{url} is also in #{urls[url]}" if urls.key?(url)
    raise CheckError, "#{shot_where}: caption isn't text" unless shot["caption"].is_a?(String) && !shot["caption"].strip.empty?

    urls[url] = file
  end
end

def check_app(path, urls, names)
  file = path.delete_prefix("#{ROOT}/")
  data = front_matter(File.read(path, encoding: "UTF-8"))
  check_keys(data, APP_KEYS, APP_REQUIRED, "the app")

  name = data["name"]
  raise CheckError, "name isn't text" unless name.is_a?(String) && !name.strip.empty?
  check_value(data["platform"], PLATFORMS, "platform")
  check_value(data["kind"], KINDS, "kind")
  raise CheckError, "developer isn't text" if data.key?("developer") && !data["developer"].is_a?(String)

  expected = "#{slug(name)}.md"
  raise CheckError, "is named #{File.basename(path)}, but #{name.inspect} should be #{expected}" unless File.basename(path) == expected
  raise CheckError, "has the same name as #{names[name]}" if names.key?(name)

  names[name] = file

  reports = data["reports"]
  raise CheckError, "reports isn't a list with at least one report" unless reports.is_a?(Array) && !reports.empty?

  reports.each_with_index { |report, index| check_report(report, "report #{index + 1}", urls, file) }
  reports.each_cons(2).with_index do |(earlier, later), index|
    raise CheckError, "report #{index + 2} is dated before report #{index + 1}" if later["date"] < earlier["date"]
  end

  reports.size
end

def stray_site_files
  Dir.glob("**/*", File::FNM_DOTMATCH, base: SITE).filter_map do |relative|
    next if relative.split("/").any? { |part| SITE_IGNORED.include?(part) }
    next if File.directory?(File.join(SITE, relative))
    next if SITE_NAMES.include?(relative)
    next if SITE_EXTENSIONS.include?(File.extname(relative))

    "site/#{relative}"
  end
end

failures = []
urls = {}
names = {}
reports = 0
apps = Dir.glob(File.join(APPS, "*.md")).sort

failures << "site/_apps has no app files" if apps.empty?
apps.each do |path|
  reports += check_app(path, urls, names)
rescue CheckError => e
  failures << "#{path.delete_prefix("#{ROOT}/")}: #{e.message}"
end
stray_site_files.each { |file| failures << "#{file}: site/ holds only .md, .yml, .html and .css files" }

if failures.empty?
  puts "#{apps.size} apps, #{reports} reports"
else
  warn failures
  exit 1
end
