# frozen_string_literal: true

require 'ferrum'
require 'json'
require 'net/http'
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
        CHALLENGE_TIMEOUT = 30

        # Seconds to wait for the network to go quiet after the page loads,
        # so lazy-loaded content is in before we read the DOM.
        IDLE_TIMEOUT = 5

        # How often to poll for the challenge to clear.
        POLL_INTERVAL = 0.5

        DEFAULT_PATHS = [
          '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
          '/Applications/Chromium.app/Contents/MacOS/Chromium',
          '/usr/bin/google-chrome',
          '/usr/bin/google-chrome-stable',
          '/usr/bin/chromium',
          '/usr/bin/chromium-browser',
          '/opt/google/chrome/chrome'
        ].freeze

        class << self
          # The shared browser (or a test double). Reuse keeps the solved
          # challenge cookie warm across fetches within one process.
          attr_writer :browser

          # The ContentFilter applied to every page by default.
          attr_writer :content_filter

          # Absolute path to a Chrome/Chromium binary; nil when not found.
          attr_writer :path

          # CDP endpoint of an already-running Chrome ("http://host:port",
          # "…/json/version", or a ws:// browser URL) to attach to instead.
          attr_writer :cdp_url

          attr_writer :challenge_timeout, :poll_interval

          # A shared browser, built once and reused. Ferrum is loaded lazily
          # so consumers who never hit this backend pay nothing for it.
          def browser
            return @browser if @browser

            browser_mutex.synchronize { @browser ||= build_browser }
          end

          def content_filter
            @content_filter ||= ContentFilter.default
          end

          def path
            @path || ENV['ASK_WEB_FETCH_CHROME_PATH'] || DEFAULT_PATHS.find { |p| File.exist?(p) }
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

            Ferrum::Browser.new(
              browser_path: path,
              headless: true,
              user_data_dir: ENV['ASK_WEB_FETCH_PROFILE'],
              timeout: CHALLENGE_TIMEOUT + IDLE_TIMEOUT
            )
          end
        end

        def fetch(url)
          page = nil
          raise FetchError, 'no Chrome/Chromium found and no CDP endpoint set' unless self.class.configured?
          raise FetchError, 'ferrum gem unavailable' unless self.class.browser

          page = self.class.browser.create_page
          page.go_to(url)
          wait_for_challenge(page)
          wait_for_idle(page)

          status = page.network.status
          raise FetchError, "got #{status} at #{url}" if status && status >= 400

          body = page.body
          raise FetchError, "challenge page at #{url}" if challenge_page?(body)

          result = Markdown.generate(body, base_url: url, filter: self.class.content_filter)
          raise EmptyContentError, "no readable content at #{url}" unless usable_content?(result[:content])

          result
        rescue Ferrum::TimeoutError, Ferrum::ProcessTimeoutError, Ferrum::DeadBrowserError => e
          raise TimeoutError, "#{e.class}: #{e.message}"
        rescue Ferrum::StatusError => e
          raise FetchError, "browser could not load #{url}: #{e.message}"
        rescue Ferrum::Error => e
          raise ServerError, "browser #{e.class}: #{e.message}"
        rescue Errno::ECONNREFUSED, SocketError => e
          raise TimeoutError, "browser connection #{e.class}: #{e.message}"
        ensure
          page&.close
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
