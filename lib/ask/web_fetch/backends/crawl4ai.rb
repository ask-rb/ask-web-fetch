# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'
require_relative '../backend'

module Ask
  module WebFetch
    module Backends
      # Self-hosted Crawl4AI (https://docs.crawl4ai.com) — a headless
      # Chromium crawler that renders JavaScript and returns clean markdown.
      # Runs as its own Docker service (default http://localhost:11235), the
      # same self-hosted pattern as ask-web-search's SearXNG. No API key;
      # configure via CRAWL4AI_URL (and CRAWL4AI_TOKEN for 0.9+ JWT-protected
      # servers).
      #
      # Kept FIRST in the default chain: when the service is present it
      # handles the JS-rendered pages the Local backend can't. When it isn't
      # configured — or is unreachable — it fails fast and the chain falls
      # through to Local, with Jina as the last resort.
      class Crawl4Ai < Backend
        DEFAULT_URL = 'http://localhost:11235'
        OPEN_TIMEOUT = 5
        # Browser rendering (plus first-request pool warmup) is slow — the
        # crawl itself gets crawler_config.timeout, so the HTTP read must
        # allow that plus headroom, unlike the plain-HTML backends.
        READ_TIMEOUT = 90
        CRAWL_TIMEOUT = 60

        class << self
          attr_writer :url, :token

          def url
            @url || ENV['CRAWL4AI_URL']
          end

          def token
            @token || ENV['CRAWL4AI_TOKEN']
          end

          # Presence = configuration. The tool's default chain only includes
          # this backend when CRAWL4AI_URL is set, so consumers without a
          # Crawl4AI service see zero behavior change (Local -> Jina).
          def configured?
            !url.to_s.empty?
          end
        end

        def fetch(url)
          raise FetchError, 'Crawl4AI not configured (set CRAWL4AI_URL)' if self.class.url.to_s.empty?

          body = crawl(url)
          raise FetchError, "challenge page at #{url}" if challenge_page?(body)

          page = to_page(body, url)
          raise EmptyContentError, "no readable content at #{url}" unless usable_content?(page[:content])

          page
        rescue Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNREFUSED,
               Errno::ECONNRESET, SocketError, URI::InvalidURIError => e
          raise TimeoutError, "Crawl4AI #{e.class}: #{e.message}"
        end

        private

        def crawl(url)
          uri = URI("#{self.class.url.chomp('/')}/crawl")
          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = uri.scheme == 'https'
          http.open_timeout = OPEN_TIMEOUT
          http.read_timeout = READ_TIMEOUT

          req = Net::HTTP::Post.new(uri)
          req['Content-Type'] = 'application/json'
          req['Accept'] = 'application/json'
          req['User-Agent'] = USER_AGENT
          req['Authorization'] = "Bearer #{self.class.token}" if self.class.token
          req.body = JSON.generate(
            urls: [url],
            crawler_config: { cache_mode: 'bypass', timeout: CRAWL_TIMEOUT }
          )

          res = http.request(req)
          case res.code
          when '200'
            res.body.to_s
          when '401', '403'
            raise FetchError, "Crawl4AI auth error (#{res.code})"
          else
            # The /crawl service itself answering 5xx (or 4xx beyond auth)
            # is a service-side problem — transient, retrying may succeed.
            raise ServerError, "Crawl4AI returned #{res.code}"
          end
        end

        # The /crawl response is {success:, results: [CrawlResult...]} where
        # each result carries markdown (fit_markdown preferred, raw_markdown
        # fallback) and metadata (title, description, ...).
        def to_page(body, url)
          data = JSON.parse(body)
          result = Array(data['results']).first || {}
          if result['success'] == false
            raise FetchError, "Crawl4AI crawl failed: #{result['error_message'] || 'unknown error'}"
          end

          # A rendered page is only content when it actually loaded — a 4xx
          # error page renders fine but is not the page. Crawl4AI reports
          # the target's status on the result; without this check a 404
          # shell passes as a successful fetch.
          status = result['status_code'].to_i
          if status >= 400
            raise(status == 429 || status >= 500 ? ServerError : FetchError, "Crawl4AI got #{status} at #{url}")
          end

          markdown = result.dig('markdown', 'fit_markdown').to_s
          markdown = result.dig('markdown', 'raw_markdown').to_s if markdown.strip.empty?
          {
            title: result.dig('metadata', 'title'),
            description: result.dig('metadata', 'description') ||
              result.dig('metadata', 'og_description'),
            content: markdown
          }
        rescue JSON::ParserError => e
          raise FetchError, "Crawl4AI bad JSON response: #{e.message}"
        end
      end
    end
  end
end
