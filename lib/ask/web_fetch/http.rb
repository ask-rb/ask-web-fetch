# frozen_string_literal: true

require 'httpx'

module Ask
  module WebFetch
    # Minimal pooled HTTP client for the Local backend. Wraps a per-thread
    # httpx session so every page fetch in a thread reuses its keep-alive
    # connection to the host — no fresh TCP+TLS handshake per page (the
    # thing that made the Net::HTTP crawler cost ~1.25s per page) — with
    # HTTP/2 when the server negotiates it, retries with backoff on
    # transient failures, and automatic gzip/deflate decoding.
    #
    # Deliberately single-hop: the backend follows redirects itself, so the
    # hop-by-hop chain it reports is exactly what happened. Error responses
    # (4xx/5xx) are not errors to the transport — the backend decides what
    # they mean. Transport-level failures (timeout, refused, reset, DNS,
    # TLS) all surface as Ask::WebFetch::TimeoutError, the transient
    # bucket, whatever their underlying class.
    class Http
      CONNECT_TIMEOUT = 3
      READ_TIMEOUT = 8
      WRITE_TIMEOUT = 8
      # Whole-request cap. A page that can't be read in 20s is a
      # problem page, not a stall worth a crawl worker.
      OPERATION_TIMEOUT = 20
      # Retries per request, on top of the crawl ledger's own auto-heal
      # rounds. GETs are idempotent; a couple of cheap retries beat a full
      # ledger round-trip for transient flakiness.
      MAX_RETRIES = 2
      RETRY_ON_STATUS = [429, 500, 502, 503, 504].freeze

      # One hop's answer. Redirects stay the backend's job, so `location`
      # rides along for the backend to resolve.
      Response = Data.define(:status, :body, :content_type, :location)

      def self.get(url, headers: {})
        response = session.get(url, headers: headers)
        return raise_timeout(response) if response.is_a?(HTTPX::ErrorResponse)

        Response.new(
          status: response.status,
          body: response.body.to_s,
          content_type: response.headers['content-type'].to_s,
          location: response.headers['location'].to_s
        )
      end

      # One pooled session per thread — httpx sessions are not thread-safe,
      # and a crawl worker thread reusing its session across every page it
      # fetches is what keeps timeouts and retries configured once.
      # Sessions idle-close themselves after keep-alive timeout, so nothing
      # to reap.
      def self.session
        Thread.current[SESSION_KEY] ||= build_session
      end

      def self.build_session
        # Deliberately NOT :persistent: in httpx 1.8.1 that plugin wedges
        # inside the selector loop when a session that already holds a
        # pooled connection opens one to a NEW host — the operation
        # timeout never fires and the fetch hangs forever (reproduced in
        # plain Ruby: example.com then nytimes.com on one session).
        # Without it httpx opens a fresh connection per host, which for a
        # crawler hitting mostly-distinct hosts costs one TLS handshake
        # per page and never hangs. Retries are explicit so the transient
        # backoff that :persistent loaded internally is kept.
        HTTPX.plugin(:retries).with(
          timeout: {
            connect_timeout: CONNECT_TIMEOUT,
            read_timeout: READ_TIMEOUT,
            write_timeout: WRITE_TIMEOUT,
            operation_timeout: OPERATION_TIMEOUT
          },
          headers: { 'user-agent' => Backend::USER_AGENT },
          max_retries: MAX_RETRIES,
          retry_on: ->(response) { response.respond_to?(:status) && RETRY_ON_STATUS.include?(response.status) }
        )
      end
      private_class_method :build_session

      def self.raise_timeout(response)
        error = response.error
        raise TimeoutError, "#{error.class}: #{error.message}"
      end
      private_class_method :raise_timeout

      SESSION_KEY = :ask_web_fetch_http_session
      private_constant :SESSION_KEY
    end
  end
end
