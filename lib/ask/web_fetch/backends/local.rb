# frozen_string_literal: true

require 'net/http'
require 'uri'
require_relative '../backend'
require_relative '../content_filter'
require_relative '../markdown'

module Ask
  module WebFetch
    module Backends
      # Default backend: pure Ruby Net::HTTP + Nokogiri + reverse_markdown.
      # No external service or API key; mirrors ask-web-search's self-hosted
      # SearXNG approach.
      #
      # HTML is converted through Ask::WebFetch::Markdown with a default
      # ContentFilter, so the "fit" content — pruned by text density rather
      # than by keyword — is what comes back.
      class Local < Backend
        MAX_REDIRECTS = 5
        OPEN_TIMEOUT = 5
        READ_TIMEOUT = 15

        class << self
          # The ContentFilter applied to every page by default. Set to nil to
          # convert the article/main region without pruning.
          attr_writer :content_filter

          # Dynamic threshold (crawl4ai's default is fixed 0.48): loosens the
          # bar for content-carrying tags and text-heavy nodes, and tightens
          # it for link-heavy ones — which is what catches the classic
          # sidebar-of-links that the fixed bar lets through.
          def content_filter
            @content_filter ||= ContentFilter.new(threshold_type: :dynamic)
          end
        end

        def fetch(url)
          body, content_type, redirect = fetch_html(url)
          raise FetchError, "expected HTML from #{url}, got #{content_type}" unless content_type.include?('html')
          raise FetchError, "challenge page at #{url}" if challenge_page?(body)

          page = to_markdown(body, url)
          page[:redirected] = redirect
          raise EmptyContentError, "no readable content at #{url}" unless usable_content?(page[:content])

          page
        rescue Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNREFUSED,
               Errno::ECONNRESET, SocketError, URI::InvalidURIError => e
          raise TimeoutError, "#{e.class}: #{e.message}"
        end

        # Parses +html+ and returns { title:, description:, content: } where
        # content is clean markdown and description is the page's own meta
        # description (meta name=description, then og:description) — what the
        # site says about itself, free and authoritative.
        def to_markdown(html, url)
          Markdown.generate(html, base_url: url, filter: self.class.content_filter)
        end

        private

        # GET with redirect following (max MAX_REDIRECTS hops). Returns
        # [body, content_type, redirect] where redirect is nil when the
        # URL answered directly, else {status: first hop's status,
        # url: final destination} — the chain the crawler followed.
        def fetch_html(url)
          uri = URI(url)
          hops = 0
          first_hop_status = nil
          loop do
            http = Net::HTTP.new(uri.host, uri.port)
            http.open_timeout = OPEN_TIMEOUT
            http.read_timeout = READ_TIMEOUT
            http.use_ssl = uri.scheme == 'https'
            req = Net::HTTP::Get.new(uri)
            req['User-Agent'] = USER_AGENT
            req['Accept'] = 'text/html,application/xhtml+xml'
            res = http.request(req)
            return [res.body, res['content-type'].to_s, redirect_info(first_hop_status, uri)] if res.code.start_with?('2')

            unless res.code.start_with?('3') && res['location']
              # 4xx (other than 429) = the URL is dead; 429/5xx = transient.
              code = res.code.to_i
              raise(code == 429 || code >= 500 ? ServerError : FetchError, "got #{res.code} from #{url}")
            end
            raise FetchError, "hit a redirect loop at #{url}" if (hops += 1) > MAX_REDIRECTS

            first_hop_status ||= res.code.to_i
            uri = URI.join(uri, res['location'])
          end
        end

        def redirect_info(status, uri)
          status && {status: status, url: uri.to_s}
        end
      end
    end
  end
end
