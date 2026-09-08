# frozen_string_literal: true

require_relative 'version'

module Ask
  module WebFetch
    # Raised by backends on any failure; the tool catches it and tries the
    # next backend in the chain.
    class Error < StandardError; end

    # A backend that failed to fetch because the URL itself is bad —
    # challenge page, non-HTML response, redirect loop. Deterministic:
    # retrying won't change the outcome.
    class FetchError < Error
      attr_reader :status

      def initialize(message = nil, status: nil)
        @status = status
        msg = status ? "[#{status}] #{message}" : message
        super(msg)
      end
    end

    # HTTP 404 — the URL does not exist. Some 404 pages still carry
    # usable content (custom error pages with navigation, suggestions);
    # the backend tries to extract it before giving up.
    class NotFoundError < FetchError; end

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
    class ServerError < Error
      attr_reader :status

      def initialize(message = nil, status: nil)
        @status = status
        msg = status ? "[#{status}] #{message}" : message
        super(msg)
      end
    end

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
    #   5. run the extracted page through #guard_page! — the parked-domain
    #      and empty-content verdicts are identical in every backend
    #   6. register the class in Ask::WebFetch.backends
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
      # Cf-chl: a Turnstile form widget uses `cf-chl-widget-*` + `cf-turnstile-response`
      # (a per-form CAPTCHA, not the `cf-chl` managed challenge that gates
      # the whole page), so matching bare `cf-chl` on the body misclassifies
      # every Turnstile form (openai.com/form/codex-for-oss) as a challenge.
      # Accept both the classic managed-challenge markers (`challenge-platform`,
      # `_cf_chl_opt`) and the bare `cf-chl` id, but the plain widget id is
      # explicitly NOT a challenge — see challenge_page? below.
      CHALLENGE_RE = /just a moment|checking your browser|cf-chl|challenge-platform|_cf_chl_opt/i

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

      # The shared page guard, run by EVERY backend at the same point in
      # its flow — after extraction, before returning: a registrar parking
      # page raises ParkedDomainError, content below the minimum raises
      # EmptyContentError. Same verdicts, same messages, everywhere; a
      # backend's only job is to pass the strings it has.
      #
      # raw_body: the raw HTML the backend saw, where it saw it (Local,
      # Browser) — the HTML-only markers (ap:"parking", parking-lander,
      # LANDER_SYSTEM="PW") live in scripts and assets that never survive
      # conversion to markdown. content: what the backend would return
      # (all four) — the prose markers survive conversion, so a backend
      # that only ever sees rendered text (Jina, Crawl4AI) still rejects
      # the ad.
      #
      # Parked is checked BEFORE the content minimum on purpose: a parking
      # page can render above it (puncta.ai: 395c of Namecheap auction
      # ads) and must still be rejected.
      def guard_page!(url, content, raw_body: nil)
        raise ParkedDomainError,
              "parked domain at #{url} — registrar parking page, not site content" if parked_domain?(raw_body) || parked_domain?(content)
        raise EmptyContentError, "no readable content at #{url}" unless usable_content?(content)
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
        text = body.to_s
        return false unless text.match?(CHALLENGE_RE)
        # Bare `cf-chl-widget-*` is a Turnstile form widget, not the
        # Cloudflare managed challenge interstitial. The interstitial's
        # `cf-chl` comes with `challenge-platform` / `_cf_chl_opt` /
        # "just a moment" next to it; a page whose only hit is the widget
        # id (openai.com form pages) is NOT a challenge.
        return false if text.include?('cf-chl-widget') &&
                        !text.match?(/challenge-platform|_cf_chl_opt|just a moment|checking your browser/i)

        true
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
