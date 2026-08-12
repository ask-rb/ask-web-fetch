# frozen_string_literal: true

require 'ferrum'

module Ask
  module WebFetch
    module Backends
      # Drives an already-running Chrome — one started with
      # `--remote-debugging-port=9222` — over the Chrome DevTools Protocol,
      # reusing Ferrum's battle-tested CDP WebSocket client.
      #
      # This is the mode the Browser backend uses when ASK_WEB_FETCH_CDP_URL
      # is set (e.g. http://127.0.0.1:9222). It is the *trusted context* a
      # freshly launched automation browser can never be: a long-lived Chrome
      # with a mature profile and any cookies (like cf_clearance) it has
      # already earned, so sites whose invisible challenges soft-block fresh
      # profiles load normally here.
      #
      # Each page is its own CDP target, created and closed by us — existing
      # tabs are never touched.
      class AttachedBrowser
        def initialize(ws_url, timeout:, client: nil)
          @ws_url = ws_url
          @timeout = timeout
          @client = client
        end

        # Creates a page as a fresh tab in the attached browser.
        def create_page
          # Capture the frontmost app once per browser instance, not per
          # page: a batch of fetches steals focus once and restores to the
          # same app, and consecutive fetches don't fight each other.
          @frontmost_app ||= FocusRestorer.capture_frontmost
          Page.new(client, timeout: @timeout, restore_focus_to: @frontmost_app)
        end

        private

        def client
          @client ||= Ferrum::Client.new(
            Addressable::URI.parse(@ws_url),
            Ferrum::Browser::Options.new(timeout: @timeout, ws_max_receive_size: 20 * 1024 * 1024)
          )
        end

        # One tab in the attached browser, closed with #close. Speaks just
        # enough CDP for the Browser backend: navigate, read title/URL/HTML,
        # and report the main-document HTTP status.
        class Page
          def initialize(client, timeout:, restore_focus_to: nil)
            @client = client
            @timeout = timeout
            @restore_focus_to = restore_focus_to
            @target_id = @client.command('Target.createTarget', url: 'about:blank')['targetId']
            @session = @client.session(
              @client.command('Target.attachToTarget', targetId: @target_id, flatten: true)['sessionId']
            )
            # Subscribed BEFORE any navigation so the idle wait sees the
            # page's real load traffic (lazy SPAs render in waves).
            @network = Network.new(self)
          end

          # Navigates and does not return until the document has actually
          # loaded — Page.navigate only *starts* the navigation, and reading
          # the page before it commits yields an empty document (the very
          # failure mode this class exists to avoid).
          def go_to(url)
            result = @session.command('Page.navigate', url: url)
            error = result['errorText']
            if error && error != 'net::ERR_ABORTED'
              raise Ferrum::StatusError, "Request to #{url} failed (#{error})"
            end

            wait_for_load
          end
          def title
            evaluate('document.title')
          end

          def url
            evaluate('location.href')
          end

          def body
            evaluate('document.documentElement.outerHTML') || ''
          end

          # Minimal network facade for the Browser backend: status from the
          # Navigation Timing API, idle from CDP Network events (subscribed
          # in the constructor, before navigation).
          def network
            @network
          end

          def close
            @client.command('Target.closeTarget', targetId: @target_id)
          rescue Ferrum::Error
            nil
          ensure
            # The attached dev Chrome window steals focus when a tab is
            # created; give it back once the tab is gone — but only to an
            # app that ISN'T Chrome, so a fetch while the user is already
            # looking at Chrome doesn't ping-pong.
            FocusRestorer.restore_frontmost(@restore_focus_to)
          end

          def evaluate(expression)
            response = @session.command('Runtime.evaluate', expression: expression, returnByValue: true)
            # Ferrum's command() unwraps CDP's outer "result", leaving
            # { "result" => RemoteObject, "exceptionDetails" => ... }.
            response.dig('result', 'value')
          end

          private

          # Wait for the DOM to be parsed, not for the load event: many
          # pages (lazy images, analytics, keep-alive connections) never
          # reach readyState "complete", but the content is fully readable
          # at "interactive".
          def wait_for_load
            deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @timeout
            while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
              state = ready_state
              return if state && state != 'loading'

              sleep 0.1
            end
            raise Ferrum::TimeoutError, "page did not finish loading within #{@timeout}s"
          end

          def ready_state
            evaluate('document.readyState')
          rescue Ferrum::Error
            # Mid-navigation: the execution context is gone, keep waiting.
            nil
          end

          # Real network-idle detection for the attached browser, via CDP's
          # Network domain events. The launched-browser path gets idle
          # waiting from Ferrum's network; the attached path previously
          # skipped it entirely (a no-op), which read lazy-loading SPAs too
          # early — reddit's post list renders in waves, and the fetch saw
          # only the first 2.6k of an 8k+ body. Tracks requestStarted /
          # requestFinished events on the page session and waits until the
          # network has been quiet for +duration+, capped at +timeout+.
          class Network
            def initialize(page)
              @page = page
              @session = page.instance_variable_get(:@session)
              @in_flight = 0
              @quiet_since = Process.clock_gettime(Process::CLOCK_MONOTONIC)
              @mutex = Mutex.new
              subscribe
            end

            def status
              @page.evaluate(
                "performance.getEntriesByType('navigation')[0] ? " \
                "performance.getEntriesByType('navigation')[0].responseStatus : 0"
              ) || 0
            rescue Ferrum::Error
              0
            end

            def wait_for_idle(duration:, timeout:)
              deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
              loop do
                quiet = @mutex.synchronize { @in_flight.zero? }
                if quiet && Process.clock_gettime(Process::CLOCK_MONOTONIC) - @quiet_since >= duration
                  return
                end
                raise Ferrum::TimeoutError, "network did not go idle within #{timeout}s" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

                sleep 0.1
              end
            end

            private

            # CDP events arrive on the session's message loop; Ferrum's
            # session dispatches them to subscribed handlers. Track the
            # request lifecycle so "quiet" means no request has been in
            # flight for the duration — the signal lazy SPAs settle on.
            # Defensive: a minimal/mock session without event support
            # (some test doubles) just skips subscription — the load-wait
            # in go_to is still the floor.
            def subscribe
              return unless @session.respond_to?(:on)

              @session.on('Network.requestWillBeSent') { @mutex.synchronize { @in_flight += 1 } }
              @session.on('Network.responseReceived') { @mutex.synchronize { @quiet_since = Process.clock_gettime(Process::CLOCK_MONOTONIC) } }
              @session.on('Network.loadingFinished') { @mutex.synchronize { @in_flight -= 1 if @in_flight.positive? } }
              @session.on('Network.loadingFailed') { @mutex.synchronize { @in_flight -= 1 if @in_flight.positive? } }
              @session.command('Network.enable')
            rescue Ferrum::Error
              # Some attached browsers reject Network.enable (unlikely);
              # fall back to the load-wait already done in go_to.
              nil
            end
          end
        end
      end

      # macOS dev convenience: the attached Chrome window steals focus when
      # a tab is created, and a developer working in another app wants it
      # back once the tab is closed. Captures the frontmost app before the
      # page is created and re-activates it after close. Deliberately
      # cheap and quiet: one osascript each way, rescued to nil everywhere
      # else (prod is headless Linux — this module is a no-op there, and
      # even on macOS a failure must never fail a fetch).
      module FocusRestorer
        # The command runner, injectable for tests (minitest 6 ships no
        # mock support, so tests swap this instead of stubbing).
        class << self
          attr_writer :runner

          def runner
            @runner ||= method(:system)
          end
        end

        def self.capture_frontmost
          return nil unless RUBY_PLATFORM.include?('darwin')

          out = `osascript -e 'tell application "System Events" to get name of first application process whose frontmost is true' 2>/dev/null`.strip
          out.empty? ? nil : out
        rescue StandardError
          nil
        end

        def self.restore_frontmost(app)
          return if app.nil? || app.empty?

          # Never ping-pong: if the user is already looking at Chrome (or
          # headless/CI has no frontmost app at all), there's nothing to
          # give back.
          return if app == 'Google Chrome'

          runner.call("osascript -e 'tell application \"#{app}\" to activate' 2>/dev/null")
          nil
        rescue StandardError
          nil
        end
      end
    end
  end
end
