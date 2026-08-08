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
          Page.new(client, timeout: @timeout)
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
          def initialize(client, timeout:)
            @client = client
            @timeout = timeout
            @target_id = @client.command('Target.createTarget', url: 'about:blank')['targetId']
            @session = @client.session(
              @client.command('Target.attachToTarget', targetId: @target_id, flatten: true)['sessionId']
            )
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

          # Minimal network facade for the Browser backend. The status comes
          # from the Navigation Timing API (the main document's HTTP status);
          # attached pages need no idle wait — they only exist once loaded.
          def network
            @network ||= Network.new(self)
          end

          def close
            @client.command('Target.closeTarget', targetId: @target_id)
          rescue Ferrum::Error
            nil
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

          # Status + no-op idle for the Browser backend's fetch flow.
          class Network
            def initialize(page)
              @page = page
            end

            def status
              @page.evaluate(
                "performance.getEntriesByType('navigation')[0] ? " \
                "performance.getEntriesByType('navigation')[0].responseStatus : 0"
              ) || 0
            rescue Ferrum::Error
              0
            end

            def wait_for_idle(*)
              nil
            end
          end
        end
      end
    end
  end
end
