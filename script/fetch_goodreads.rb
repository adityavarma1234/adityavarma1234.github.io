#!/usr/bin/env ruby
# Pulls this site's Goodreads shelves via the public per-shelf RSS feeds
# (the Goodreads API itself has been deprecated since 2020, but the RSS
# feeds are still served) and writes the result to _data/goodreads.yml
# so Jekyll can render it like any other site.data.
#
# Run before `jekyll build`. Safe to run locally (writes into _data/),
# and is what the scheduled GitHub Actions workflow runs before deploying.

require "net/http"
require "uri"
require "rexml/document"
require "yaml"
require "time"

USER_ID = "62461817"
PROFILE_URL = "https://www.goodreads.com/adityavarma1234"
SHELVES = %w[currently-reading read to-read]

def fetch_page(shelf, page)
  uri = URI("https://www.goodreads.com/review/list_rss/#{USER_ID}?shelf=#{shelf}&page=#{page}")
  request = Net::HTTP::Get.new(uri)
  request["User-Agent"] = "Mozilla/5.0 (compatible; goodreads-fetch-script)"

  response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |http| http.request(request) }
  raise "Goodreads RSS request failed for shelf=#{shelf} page=#{page}: #{response.code}" unless response.is_a?(Net::HTTPSuccess)

  doc = REXML::Document.new(response.body)
  REXML::XPath.match(doc, "//item").map do |item|
    text = ->(tag) { item.elements[tag]&.text&.strip }
    {
      "title" => text.call("title"),
      "author" => text.call("author_name"),
      "link" => text.call("link"),
      "image" => text.call("book_large_image_url"),
      "date_added" => text.call("user_date_added"),
      "read_at" => text.call("user_read_at"),
    }
  end
end

# The RSS feed is paginated at 100 items/page with no total-count field,
# so we page through until a page comes back short of the full page size.
def fetch_shelf(shelf)
  books = []
  page = 1
  loop do
    batch = fetch_page(shelf, page)
    books.concat(batch)
    break if batch.size < 100
    page += 1
  end
  books
end

begin
  shelves = SHELVES.each_with_object({}) { |shelf, memo| memo[shelf] = fetch_shelf(shelf) }

  currently_reading = shelves["currently-reading"]
    .sort_by { |b| Time.parse(b["date_added"]) rescue Time.at(0) }
    .reverse

  recently_read = shelves["read"]
    .sort_by { |b| Time.parse(b["read_at"] || b["date_added"]) rescue Time.at(0) }
    .reverse
    .first(6)

  data = {
    "updated_at" => Time.now.utc.iso8601,
    "profile_url" => PROFILE_URL,
    "shelf_counts" => {
      "currently_reading" => shelves["currently-reading"].size,
      "read" => shelves["read"].size,
      "to_read" => shelves["to-read"].size,
    },
    "currently_reading" => currently_reading,
    "recently_read" => recently_read,
  }

  File.write(File.join(__dir__, "..", "_data", "goodreads.yml"), data.to_yaml)
  puts "Wrote _data/goodreads.yml (#{data["shelf_counts"]})"
rescue StandardError => e
  # Goodreads is an external dependency outside our control (outage, rate
  # limit, markup change). A failure here should never take down the rest
  # of the site's build/deploy — the books page falls back to a plain
  # profile link when _data/goodreads.yml is absent. Exit 0 on purpose.
  warn "Skipping Goodreads sync: #{e.class}: #{e.message}"
end
