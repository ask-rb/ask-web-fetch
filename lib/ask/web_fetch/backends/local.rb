# frozen_string_literal: true

require 'uri'
require_relative '../backend'
require_relative '../content_filter'
require_relative '../markdown'
require_relative '../http'

module Ask
  module WebFetch
    module Backends
      # Default backend: pure Ruby httpx + Nokogiri + reverse_markdown.
      # No external service or API key; mirrors ask-web-search's self-hosted
      # SearXNG approach.
      #
      # HTML is converted through Ask::WebFetch::Markdown with a default
      # ContentFilter, so the "fit" content — pruned by text density rather
      # than by keyword — is what comes back.
      class Local < Backend
        MAX_REDIRECTS = 5

        class << self
          # The ContentFilter applied to every page by default. Set to nil to
          # convert the article/main region without pruning.
          attr_writer :content_filter

          def content_filter
            @content_filter ||= ContentFilter.default
          end

          # The single-hop HTTP transport, Ask::WebFetch::Http by default:
          # a pooled keep-alive httpx session. Swappable in tests — and the
          # seam any future transport swap goes through.
          attr_writer :http

          def http
            @http ||= Http
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
        rescue Errno::ECONNREFUSED, Errno::ECONNRESET, SocketError, URI::InvalidURIError => e
          # The transport maps its own failures to TimeoutError; this guard
          # keeps the "only Ask::WebFetch errors escape" invariant even if
          # a transport bug lets a raw socket error through.
          raise TimeoutError, "#{e.class}: #{e.message}"
        end

        # Parses +html+ and returns { title:, description:, content:,
        # licenses:, outlinks: } where content is clean markdown (pruned by
        # the ContentFilter), licenses are the page's declared license
        # signals ([] when it declares none), and outlinks are the page's
        # RAW hrefs, resolved and scheme-filtered — nav and footer included,
        # because a crawler's discovery layer reads these even when the
        # stored content is pruned.
        def to_markdown(html, url)
          Markdown.generate(html, base_url: url, filter: self.class.content_filter)
            .merge(licenses: license_signals(html), outlinks: outlink_urls(html, url))
        end

        private

        # The page's declared license signals: <link rel="license">, the
        # license meta tags (meta name/property license, cc:license,
        # dc.rights), and schema.org [itemprop=license] — hrefs first, then
        # contents. Best-effort and conservative: nothing here decides what
        # the page IS licensed under, it only reports what the page says
        # about itself. The consumer (the crawler's license classifier)
        # maps known markers; unknown signals are ignored there, never here.
        def license_signals(html)
          doc = Nokogiri::HTML(html)
          selectors = [
            'link[rel~="license"]',
            'meta[name="license"], meta[property="license"]',
            'meta[name="cc:license"], meta[property="cc:license"]',
            'meta[name="dc.rights"], meta[property="dc.rights"]',
            '[itemprop="license"]'
          ]
          doc.css(selectors.join(',')).filter_map do |node|
            value = node['href'] || node['content'] || node.text
            value = value.to_s.strip
            value unless value.empty?
          end.uniq
        end

        # GET with redirect following (max MAX_REDIRECTS hops). Returns
        # [body, content_type, redirect] where redirect is nil when the
        # URL answered directly, else {status: first hop's status,
        # url: final destination} — the chain the crawler followed.
        def fetch_html(url)
          uri = URI(url)
          hops = 0
          first_hop_status = nil
          loop do
            response = self.class.http.get(uri.to_s, headers: { 'accept' => 'text/html,application/xhtml+xml' })
            return [response.body, response.content_type, redirect_info(first_hop_status, uri)] if (200..299).cover?(response.status)

            unless (300..399).cover?(response.status) && !response.location.empty?
              # 4xx (other than 429) = the URL is dead; 429/5xx = transient.
              code = response.status
              raise(code == 429 || code >= 500 ? ServerError : FetchError, "got #{code} from #{url}")
            end
            raise FetchError, "hit a redirect loop at #{url}" if (hops += 1) > MAX_REDIRECTS

            first_hop_status ||= response.status
            uri = URI.join(uri, response.location)
          end
        end

        def redirect_info(status, uri)
          status && { status: status, url: uri.to_s }
        end
      end
    end
  end
end
