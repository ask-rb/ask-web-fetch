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

        # Agent-first content negotiation: many sites now serve clean
        # markdown when asked via Accept: text/markdown, a .md URL twin,
        # or an /llms.txt manifest. We probe these low-cost paths before
        # falling back to full HTML scrape + DOM conversion.
        #
        # Order: (1) Accept: text/markdown on the original URL — the
        # cheapest probe, one extra GET; (2) the .md twin — Mintlify-
        # style sites redirect .md with content-type text/plain; (3) the
        # full HTML scrape. llms.txt manifests are upstream of individual
        # pages (they index the site) and are tried by the MCP tool
        # layer, not per-URL — that avoids duplicate fetches when the
        # same manifest covers multiple URLs.
        def fetch(url)
          # Probe 1: server content negotiation
          md_body, md_ct, md_redirect = fetch_markdown(url)
          if md_body && !md_body.empty?
            return assemble_page(md_body, url, md_redirect, source: :accept_header)
          end

          # Probe 2: .md URL twin (Mintlify, Docusaurus, some Hugo sites)
          twin = "#{url.chomp('/')}.md"
          md_body, md_ct, md_redirect = fetch_markdown(twin)
          if md_body && !md_body.empty?
            return assemble_page(md_body, url, md_redirect, source: :md_twin, twin_url: twin)
          end

          # Probe 3: full HTML scrape (legacy path)
          body, content_type, redirect = fetch_html(url)
          raise FetchError, "expected HTML from #{url}, got #{content_type}" unless content_type.include?('html')
          raise FetchError, "challenge page at #{url}" if challenge_page?(body)

          page = to_markdown(body, url)
          page[:redirected] = redirect
          # Parked-domain pages are not content: the domain owner parked it
          # with a registrar and the page is an ad for buying the domain
          # (GoDaddy/Namecheap/Sedo parking). A content company must never
          # store these as if they were the site. The shared guard checks
          # the raw server HTML first (parked pages are fully
          # server-rendered — the HTML-only markers live in scripts and
          # assets), then the content minimum, then the JS-shell
          # completeness signal below.
          guard_page!(url, page[:content], raw_body: body)
          # The completeness signal: a JS-app shell whose server HTML
          # renders little is a TRUNCATED page, not a complete one — the
          # real content awaits client-side JS that Local cannot run.
          # Storing the shell as success would silently under-deliver
          # (airbnb: 613KB server HTML -> 143 chars of markdown); failing
          # through lets the chain prefer a rendering backend (Browser),
          # and keeps a partial page from ever being stored as the real
          # thing. Two detectors: known framework markers, or a large
          # HTML page with almost no server-rendered text.
          if js_app_shell?(body) && page[:content].length < SHELL_DEFER_THRESHOLD
            raise EmptyContentError,
              "JS-app shell at #{url} — server HTML renders only #{page[:content].length} chars; a rendering backend is required"
          end

          page
        rescue Errno::ECONNREFUSED, Errno::ECONNRESET, SocketError, URI::InvalidURIError => e
          # The transport maps its own failures to TimeoutError; this guard
          # keeps the "only Ask::WebFetch errors escape" invariant even if
          # a transport bug lets a raw socket error through.
          raise TimeoutError, "#{e.class}: #{e.message}"
        end

        # Client-rendered framework markers: the server HTML is (at least
        # partly) a shell awaiting JS. Deliberately narrow — generic terms
        # like "script" or "root" appear on every page; these are the
        # specific footprints of React/Vue/Next/Nuxt app shells.
        JS_APP_SHELL_MARKERS = /id=["'](?:root|app|__next|site-content)["']|__NEXT_DATA__|window\.__NUXT__|ng-app|data-reactroot/

        # A framework marker (React/Vue/Next) alone is NOT emptiness: a
        # marked page can server-render real content (careers.abb job
        # pages: 2,162 chars of job description) and must be stored as-is
        # when the rendering backends cannot do better — dropping it lost
        # real pages (2026-08-14). The shell deferral fires only when the
        # extraction is genuinely little: below this, the page is a true
        # shell (airbnb: 613KB HTML -> 143 chars). Tunable; the chain
        # turns the signal into "prefer Browser for this URL".
        SHELL_DEFER_THRESHOLD = 500

        # The ratio detector's own bar, kept for compatibility with the
        # comment below (large HTML + near-empty text is a shell whatever
        # the framework).
        SHELL_CONTENT_THRESHOLD = 4_000

        # A page whose server HTML is large but yields almost no text is a
        # shell whatever framework it uses (airbnb: 613KB HTML -> 143 chars
        # of markdown). Framework markers miss these; the size ratio
        # catches them. nytimes (1.4MB -> 7.5k text) stays above the text
        # floor and is correctly left to Local.
        SHELL_HTML_BYTES = 20_000

        def js_app_shell?(body)
          body.to_s.match?(JS_APP_SHELL_MARKERS) ||
            (body.to_s.bytesize > SHELL_HTML_BYTES && markdown_visible_chars(body) < SHELL_CONTENT_THRESHOLD)
        end

        # A cheap text estimate from the raw HTML (tags stripped) — the
        # "how much did the server actually render" number. Deliberately
        # rough: it only feeds a shell-vs-page heuristic.
        def markdown_visible_chars(body)
          body.to_s.gsub(/<script[\s\S]*?<\/script>/i, "")
            .gsub(/<style[\s\S]*?<\/style>/i, "")
            .gsub(/<[^>]+>/, " ")
            .gsub(/\s+/, " ").strip.length
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

        # Probes +url+ with Accept: text/markdown. Returns
        # [body, content_type, redirect] on a text/markdown response, or
        # nils when the server returned HTML (or anything else the caller
        # shouldn't treat as agent-native). Follows one redirect hop —
        # enough for Mintlify's 307 → .md twin.
        def fetch_markdown(url)
          uri = URI(url)
          response = self.class.http.get(
            uri.to_s,
            headers: { 'accept' => 'text/markdown' }
          )
          return [nil, nil, nil] unless response
          return [nil, nil, nil] if response.status >= 400

          redirect_info = nil

          # Follow a single redirect (Mintlify 307 → .md twin)
          if (300..399).cover?(response.status) && !response.location.empty?
            redirect_uri = URI.join(uri, response.location)
            redirect_info = { status: response.status, url: redirect_uri.to_s }
            response = self.class.http.get(
              redirect_uri.to_s,
              headers: { 'accept' => 'text/markdown' }
            )
            return [nil, nil, nil] unless response && response.status == 200
          end

          ct = response.content_type.to_s.downcase
          return [nil, nil, nil] unless ct.include?('text/markdown') && response.status == 200

          [response.body, ct, redirect_info]
        rescue StandardError
          [nil, nil, nil]
        end

        # Assembles a page hash from agent-native markdown (Accept or .md
        # twin), skipping the HTML→markdown conversion pipeline. Runs the
        # shared guards (parked domain, minimum content) so downstream
        # behavior is identical regardless of source.
        def assemble_page(markdown, url, redirect, source:, twin_url: nil)
          source_url = twin_url || url
          page = {
            title: nil,
            description: nil,
            content: Markdown.clean(markdown),
            redirected: redirect,
            licenses: [],
            outlinks: markdown_outlinks(markdown, source_url)
          }
          guard_page!(url, page[:content])

          page
        end
      end
    end
  end
end
