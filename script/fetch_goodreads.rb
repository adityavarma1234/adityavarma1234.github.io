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
require "fileutils"

USER_ID = "62461817"
PROFILE_URL = "https://www.goodreads.com/adityavarma1234"
SHELVES = %w[currently-reading read to-read]

def fetch_page(shelf, page)
  uri = URI("https://www.goodreads.com/review/list_rss/#{USER_ID}?shelf=#{shelf}&page=#{page}")
  request = Net::HTTP::Get.new(uri)
  # A generic/scripty User-Agent is more likely to get blocked by Goodreads'
  # (Amazon/CloudFront) edge WAF than a normal browser UA, especially from
  # datacenter IP ranges like GitHub Actions runners use.
  request["User-Agent"] = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36"
  request["Accept"] = "application/rss+xml, application/xml;q=0.9, */*;q=0.8"

  response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |http| http.request(request) }
  unless response.is_a?(Net::HTTPSuccess)
    raise "Goodreads RSS request failed for shelf=#{shelf} page=#{page}: #{response.code} #{response.message}\n#{response.body&.slice(0, 500)}"
  end

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

data_dir = File.join(__dir__, "..", "_data")
FileUtils.mkdir_p(data_dir)
File.write(File.join(data_dir, "goodreads.yml"), data.to_yaml)
puts "Wrote _data/goodreads.yml (#{data["shelf_counts"]})"
