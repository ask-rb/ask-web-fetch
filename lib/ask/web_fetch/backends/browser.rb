# frozen_string_literal: true

require 'ferrum'
require 'json'
require 'net/http'
require 'set'
require 'uri'
require_relative '../backend'
require_relative '../content_filter'
require_relative '../markdown'
require_relative 'attached_browser'

module Ask
  module WebFetch
    module Backends
      # Last-resort backend: a real Chrome driven over CDP via Ferrum.
      # Renders JavaScript, so it reads SPAs and client-side pages that
      # Local's plain HTTP cannot, and it lets Cloudflare-style *managed*
      # challenges that auto-solve for real browsers complete themselves —
      # neither Local (no JS engine) nor Jina (known datacenter renderer)
      # can do either.
      #
      # Two modes:
      #
      # * Launched — a fresh Chrome the backend starts itself (default when
      #   a binary is found). Honest limitation, measured in the wild: sites
      #   running aggressive bot protection (patronview.com, npmjs.com,
      #   stackoverflow.com all soft-block a freshly launched browser from a
      #   datacenter IP) never clear their invisible challenge for a fresh
      #   automation profile, however real the Chrome.
      # * Attached — connects to an already-running Chrome via CDP
      #   (ASK_WEB_FETCH_CDP_URL, e.g. http://127.0.0.1:9222). That browser
      #   is a *trusted context*: long-lived, mature profile, any cookies it
      #   has already earned (cf_clearance). Sites that soft-block fresh
      #   profiles load normally there. See AttachedBrowser.
      #
      # Opt-in, like Crawl4AI: joins the chain only when a Chrome/Chromium
      # binary is found or ASK_WEB_FETCH_CDP_URL is set. Configure the
      # binary with ASK_WEB_FETCH_CHROME_PATH and a persistent profile
      # directory with ASK_WEB_FETCH_PROFILE (a profile keeps solved cookies
      # across restarts; within one process the browser is reused anyway).
      #
      # HTML is converted through the same Markdown pipeline as Local, with
      # the same default adaptive ContentFilter.
      class Browser < Backend
        # Seconds to let a Cloudflare-style challenge auto-solve before
        # giving up (tunable via Browser.challenge_timeout).
        CHALLENGE_TIMEOUT = 10

        # Seconds to wait for the network to go quiet after the page loads,
        # so lazy-loaded content is in before we read the DOM.
        IDLE_TIMEOUT = 5

        # How often to poll for the challenge to clear.
        POLL_INTERVAL = 0.5

        # Brave paths — Brave's fingerprinting resistance (canvas, WebGL,
        # audio randomization) helps against Cloudflare/DataDome, but
        # benchmarks show Chrome renders SPAs (reddit) more reliably.
        # Chrome is preferred; Brave is the fallback. Override either
        # with ASK_WEB_FETCH_BROWSER_PATH.
        BRAVE_PATHS = [
          '/Applications/Brave Browser.app/Contents/MacOS/Brave Browser',
          '/usr/bin/brave-browser',
          '/usr/bin/brave-browser-stable',
          '/opt/brave.com/brave/brave-browser'
        ].freeze

        DEFAULT_PATHS = [
          '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
          '/Applications/Chromium.app/Contents/MacOS/Chromium',
          '/usr/bin/google-chrome',
          '/usr/bin/google-chrome-stable',
          '/usr/bin/chromium',
          '/usr/bin/chromium-browser',
          '/opt/google/chrome/chrome'
        ].freeze

        # Random viewport dimensions (FHD to 2K) — a fixed window size is
        # a fingerprinting signal. Each fetch gets a fresh random size.
        VIEWPORT_WIDTH_RANGE = (1920..2560).freeze
        VIEWPORT_HEIGHT_RANGE = (1080..1440).freeze

        class << self
          # The shared browser (or a test double). Reuse keeps the solved
          # challenge cookie warm across fetches within one process.
          attr_writer :browser

          # The ContentFilter applied to every page by default.
          attr_writer :content_filter

          # Absolute path to a Chrome/Chromium/Brave binary; nil when not found.
          # Prefers Brave (fingerprinting resistance) over Chrome/Chromium.
          # Override with ASK_WEB_FETCH_BROWSER_PATH (any Chromium-based
          # browser) or the legacy ASK_WEB_FETCH_CHROME_PATH.
          attr_writer :path

          # CDP endpoint of an already-running browser ("http://host:port",
          # "…/json/version", or a ws:// browser URL) to attach to instead.
          attr_writer :cdp_url

          attr_writer :challenge_timeout, :poll_interval, :viewport

          # Domains already given a warm pass this process — a failed warm
          # (DataDome-class wall) is not re-paid at CHALLENGE_TIMEOUT on
          # every fetch of that domain.
          def warmed_domains
            @warmed_domains ||= Set.new
          end

          # A shared browser, built once and reused. Ferrum is loaded lazily
          # so consumers who never hit this backend pay nothing for it.
          def browser
            return @browser if @browser

            browser_mutex.synchronize { @browser ||= build_browser }
          end

          # Drops the shared browser so the next use builds a fresh
          # session — called when the current one died mid-fetch.
          def reset_browser
            browser_mutex.synchronize { @browser = nil }
          end

          def content_filter
            @content_filter ||= ContentFilter.default
          end

          def path
            @path || ENV['ASK_WEB_FETCH_BROWSER_PATH'] || ENV['ASK_WEB_FETCH_CHROME_PATH'] ||
              DEFAULT_PATHS.find { |p| File.exist?(p) } ||
              BRAVE_PATHS.find { |p| File.exist?(p) }
          end

          # A fresh random viewport for each browser launch — a fixed
          # window size is a fingerprinting signal. Returns { width:,
          # height: } in the FHD-to-2K range. Override with
          # Browser.viewport = { width: 1920, height: 1080 } for tests.
          def viewport
            @viewport || {
              width: rand(VIEWPORT_WIDTH_RANGE),
              height: rand(VIEWPORT_HEIGHT_RANGE)
            }
          end

          # True when the configured binary is Brave (fingerprinting-
          # resistant) rather than stock Chrome/Chromium.
          def brave?
            path.to_s.match?(/brave/i)
          end

          def cdp_url
            @cdp_url || ENV['ASK_WEB_FETCH_CDP_URL']
          end

          def challenge_timeout
            @challenge_timeout || CHALLENGE_TIMEOUT
          end

          def poll_interval
            @poll_interval || POLL_INTERVAL
          end

          def configured?
            !path.to_s.empty? || !cdp_url.to_s.empty?
          end

          # Turns an ASK_WEB_FETCH_CDP_URL into the browser-level WebSocket
          # URL. Accepts a ws:// URL as-is, or an HTTP endpoint
          # ("http://127.0.0.1:9222" or "…/json/version") which is probed
          # for its webSocketDebuggerUrl — the same discovery puppeteer's
          # connect does.
          def ws_url_for(cdp_url)
            return cdp_url if cdp_url.start_with?('ws://', 'wss://')

            version_url = cdp_url.end_with?('/json/version') ? cdp_url : "#{cdp_url.chomp('/')}/json/version"
            body = Net::HTTP.get(URI(version_url))
            JSON.parse(body)['webSocketDebuggerUrl']
          rescue Errno::ECONNREFUSED, SocketError => e
            raise FetchError, "cannot reach CDP endpoint #{version_url}: #{e.message}"
          rescue JSON::ParserError => e
            raise FetchError, "bad CDP version response from #{version_url}: #{e.message}"
          end

          private

          def browser_mutex
            @browser_mutex ||= Mutex.new
          end

          def build_browser
            return AttachedBrowser.new(ws_url_for(cdp_url), timeout: CHALLENGE_TIMEOUT + IDLE_TIMEOUT) if cdp_url

            vp = viewport
            Ferrum::Browser.new(
              browser_path: path,
              headless: true,
              user_data_dir: ENV['ASK_WEB_FETCH_PROFILE'],
              timeout: CHALLENGE_TIMEOUT + IDLE_TIMEOUT,
              window_size: [vp[:width], vp[:height]]
            )
          end
        end

        def fetch(url)
          page = nil
          raise FetchError, 'no Chrome/Chromium found and no CDP endpoint set' unless self.class.configured?
          raise FetchError, 'ferrum gem unavailable' unless self.class.browser

          page = self.class.browser.create_page
          fetch_attempt(page, url)
        rescue Ferrum::DeadBrowserError => e
          # The shared browser died mid-fetch (the browserless server
          # killed the session's browser). A dead browser is transient —
          # the next session starts a fresh one — so reconnect and retry
          # ONCE instead of failing the page (observed 2026-08-14: the
          # server's session limits killed browsers and pages were
          # silently dropped).
          self.class.reset_browser
          page = self.class.browser.create_page
          fetch_attempt(page, url)
        rescue Ferrum::TimeoutError, Ferrum::ProcessTimeoutError => e
          raise TimeoutError.new("#{e.class}: #{e.message}",
                                 hint: "page load timed out — site may be slow or blocking automation")
        rescue Ferrum::StatusError => e
          raise FetchError.new("browser could not load #{url}: #{e.message}",
                               hint: "navigation failed — URL may be invalid or unreachable")
        rescue Ferrum::Error => e
          raise ServerError.new("browser #{e.class}: #{e.message}",
                                hint: "browser error — check Chrome/CDP connection")
        rescue Errno::ECONNREFUSED, SocketError => e
          raise TimeoutError.new("browser connection #{e.class}: #{e.message}",
                                 hint: "CDP endpoint unreachable — is Chrome running with --remote-debugging-port?")
        ensure
          page&.close
        end

        # One fetch of +url+ on the page, with the warm-and-retry pass: a
        # challenge page means this domain hasn't issued the profile a
        # clearance cookie yet. Visiting the DOMAIN ROOT first (where a
        # managed challenge auto-solves for a trusted browser) earns the
        # cookie — pinned to this browser + IP and persisted in the
        # profile — then the URL is retried once. Subsequent fetches for
        # the same domain find the cookie and never warm again. Bounded:
        # one warm per domain per process (warmed_domains), one retry per
        # fetch — a still-challenged URL fails as before, never wedging
        # the queue on a DataDome-class wall.
        def fetch_attempt(page, url, warmed: false)
          page.go_to(url)
          wait_for_challenge(page)
          wait_for_idle(page)

          status = page.network.status
          if status && status >= 400
            error_class = status == 404 ? NotFoundError : FetchError
            raise error_class.new("got #{status} at #{url}", status: status)
          end

          body = page.body
          if challenge_page?(body)
            raise FetchError, "challenge page at #{url}" if warmed
            raise FetchError, "challenge page at #{url}" unless warm_domain(page, url)

            return fetch_attempt(page, url, warmed: true)
          end
          # Browser renders the parked page a JS redirect lands on (the
          # server shell hands /lander to JS) — Local never sees it. The
          # shared guard catches it on the rendered HTML (raw_body) and
          # the converted content; the distinct ParkedDomainError lets the
          # pipeline classify (never retry) it.
          result = Markdown.generate(body, base_url: url, filter: self.class.content_filter)
          result[:outlinks] = outlink_urls(body, url)
          guard_page!(url, result[:content], raw_body: body)

          result
        end

        # Earns the domain's clearance cookie: navigates to the domain
        # root (the challenge JS runs there, not on the deep URL), waits
        # for the managed challenge to auto-solve, and lets the cookie
        # land in the profile. Returns true when the domain is now warm.
        # Domains already attempted this process are skipped — a failed
        # warm is not re-paid at CHALLENGE_TIMEOUT per fetch.
        def warm_domain(page, url)
          domain = URI(url).host
          return false if self.class.warmed_domains.include?(domain)

          self.class.warmed_domains << domain
          page.go_to(domain_root(url))
          wait_for_challenge(page)
          wait_for_idle(page)
          true
        rescue Ferrum::Error, URI::InvalidURIError
          false
        end

        def domain_root(url)
          uri = URI(url)
          "#{uri.scheme}://#{uri.host}"
        end

        private

        # Cloudflare's managed challenge solves itself in a real browser (JS
        # proof-of-work -> cf_clearance cookie -> reload). We just wait for
        # the interstitial's title to leave the page. If it never does, the
        # challenge is one we can't pass — deterministic, so FetchError.
        def wait_for_challenge(page)
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + self.class.challenge_timeout
          while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
            return unless challenge_active?(page)

            sleep self.class.poll_interval
          end
          raise FetchError, "challenge did not auto-solve for #{page.url}"
        end

        def challenge_active?(page)
          challenge_page?(page.title.to_s)
        rescue Ferrum::Error
          # Mid-navigation (the post-solve reload): the JS context is gone,
          # keep waiting.
          true
        end

        # Give lazy-loading pages a moment to settle; never fail the fetch
        # on it — some pages stream or poll forever and never go quiet.
        def wait_for_idle(page)
          page.network.wait_for_idle(duration: 0.5, timeout: IDLE_TIMEOUT)
        rescue Ferrum::Error
          nil
        end
      end
    end
  end
end
