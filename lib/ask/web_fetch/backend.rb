# frozen_string_literal: true

require_relative 'version'

module Ask
  module WebFetch
    # Raised by backends on any failure; the tool catches it and tries the
    # next backend in the chain.
    class Error < StandardError; end

    # A backend that failed to fetch because the URL itself is bad — 4xx,
    # challenge page, non-HTML response, redirect loop. Deterministic:
    # retrying won't change the outcome.
    class FetchError < Error; end

    # A backend that fetched the page but found nothing usable in it.
    class EmptyContentError < Error; end

    # A backend that fetched a REGISTRAR PARKING PAGE — an ad for a
    # parked (for-sale) domain, not the site's content. Deterministic and
    # terminal: retrying will never turn a parking ad into content, so
    # the pipeline must classify (not retry) it. A subclass of
    # EmptyContentError so existing empty-content handling still applies.
    class ParkedDomainError < EmptyContentError; end

    # Network-level failure — timeout, connection refused/reset, bad
    # socket. Transient: the same URL may succeed on retry.
    class TimeoutError < Error; end

    # The service or the target server answered 5xx/429. Transient:
    # retrying after backoff may succeed.
    class ServerError < Error; end

    # Base class for fetch backends, plus the errors they raise.
    #
    # A backend turns a URL into LLM-ready markdown. To add a new backend:
    #
    #   1. subclass Backend and implement #fetch(url)
    #   2. #fetch must return { title: String|nil, content: String }
    #   3. #fetch must raise FetchError (hard failure) or
    #      EmptyContentError (page fetched but nothing usable) on failure
    #   4. run the page's markdown through Ask::WebFetch::Markdown.clean
    #      before returning it — backends that hold HTML get this from
    #      Markdown.generate, backends fed pre-converted markdown (Jina,
    #      Crawl4AI) must call it explicitly so the shared noise removal
    #      and whitespace normalization apply everywhere
    #   5. register the class in Ask::Tools::WebFetch.backends
    #
    # The tool tries each backend in order and returns the first success.
    class Backend
      # Identity sent on every request, browser-like plus a gem tag.
      USER_AGENT = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) ' \
                   'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36 ' \
                   "ask-web-fetch/#{Ask::WebFetch::VERSION}".freeze

      # Content shorter than this is treated as a page with no usable
      # content (e.g. a JS-rendered shell with nothing server-side). Low on
      # purpose: the content hub keeps everything that is a real page, and
      # the crawler's soft-404 detection (not length) is what separates
      # pages from error shells.
      MIN_CONTENT_LENGTH = 40

      # Cloudflare-style anti-bot signatures. Deliberately narrow:
      # challenge/interstitial pages carry these markers, while legitimate
      # pages can contain the word "captcha" in unrelated config/JS (e.g.
      # Wikipedia embeds an hcaptcha edit-config flag on every page).
      CHALLENGE_RE = /just a moment|checking your browser|cf-chl/i

      # Registrar parking-page markers: the page is an ad for a parked
      # (for-sale) domain, not the site's content. A content company must
      # never store these as if they were the site. Observed live on the
      # CC list, three shapes: (a) GoDaddy's parking-lander JS app
      # (ap:"parking" flag, parking-lander asset, LANDER_SYSTEM="PW")
      # served at /lander, (b) Namecheap's parking app (utm_campaign=
      # nc_market + parkingpage links), and (c) static registrar pages
      # ("is parked free, courtesy of GoDaddy.com", "is registered at
      # Namecheap"). Deliberately specific — generic terms like "domain"
      # or "for sale" appear on real pages.
      PARKED_DOMAIN_MARKERS = /ap:"parking"|parking-lander|LANDER_SYSTEM="PW"|utm_campaign=nc_market|utm_source=parkingpage|is parked free, courtesy of GoDaddy|is available on GoDaddy Auctions|is registered at Namecheap/i

      def self.backend_name
        name.split('::').last
      end

      # Fetches +url+ and returns { title:, description:, content:,
      # redirected:, licenses:, outlinks: } — licenses being the page's
      # declared license signals (hrefs/values) and outlinks the page's
      # raw link set ([] when the backend can't see any), both consumed by
      # the crawler's classification/discovery layers.
      # Raises FetchError or EmptyContentError on failure.
      def fetch(url)
        raise NotImplementedError, "#{self.class} must implement #fetch(url)"
      end

      # --- outlinks (crawler discovery) ---

      # The page's raw outlinks from HTML: every <a href> resolved against
      # the base URL and scheme-filtered to absolute http(s). Nav and
      # footer are included — a crawler's discovery reads the full link set
      # even when the stored content is pruned by the ContentFilter. Shared
      # by every backend that holds the page's HTML.
      def outlink_urls(html, base_url)
        Nokogiri::HTML(html).css('a[href]').filter_map do |anchor|
          href = anchor['href'].to_s.strip
          next if href.empty? || href.start_with?('javascript:', 'mailto:', 'tel:', '#', 'data:')

          uri = URI.join(base_url, href)
          next unless %w[http https].include?(uri.scheme)

          uri.to_s
        rescue URI::InvalidURIError
          next
        end.uniq
      end

      # Fallback for backends that only see rendered markdown (Jina,
      # Crawl4AI's markdown output): the markdown's [text](url) links,
      # resolved and scheme-filtered. Same shape as #outlink_urls, one
      # implementation for every backend that lacks the raw HTML.
      def markdown_outlinks(content, base_url)
        content.to_s.scan(/\]\(([^)\s]+)\)/).filter_map do |match|
          dest = match[0]
          next if dest.start_with?('javascript:', 'mailto:', 'tel:', '#', 'data:')

          uri = URI.join(base_url, dest)
          next unless %w[http https].include?(uri.scheme)

          uri.to_s
        rescue URI::InvalidURIError
          next
        end.uniq
      end

      private

      def challenge_page?(body)
        body.to_s.match?(CHALLENGE_RE)
      end

      def parked_domain?(body)
        body.to_s.match?(PARKED_DOMAIN_MARKERS)
      end

      def usable_content?(content)
        content.to_s.strip.length >= MIN_CONTENT_LENGTH
      end
    end
  end
end
