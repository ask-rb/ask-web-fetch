# frozen_string_literal: true

require 'net/http'
require 'uri'
require_relative '../backend'
require_relative '../markdown'

module Ask
  module WebFetch
    module Backends
      # Jina Reader free tier: GET https://r.jina.ai/<url>.
      #
      # Free without a key (~20 req/min per IP). Set JINA_API_KEY for higher
      # rate limits. The endpoint runs headless Chromium, so it renders JS
      # pages that the Local backend cannot.
      class Jina < Backend
        BASE_URL = 'https://r.jina.ai'
        OPEN_TIMEOUT = 5
        READ_TIMEOUT = 30

        def fetch(url)
          uri = URI("#{BASE_URL}/#{url}")
          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = true
          http.open_timeout = OPEN_TIMEOUT
          http.read_timeout = READ_TIMEOUT
          req = Net::HTTP::Get.new(uri)
          req['User-Agent'] = USER_AGENT
          req['Accept'] = 'text/markdown, text/plain, text/html'
          req['Authorization'] = "Bearer #{ENV['JINA_API_KEY']}" if ENV['JINA_API_KEY']

          res = http.request(req)
          case res.code
          when '200'
            body = res.body.to_s
            raise FetchError, 'challenge page from Jina' if challenge_page?(body)

            content = Markdown.clean(body)
            # Jina only sees rendered markdown — outlinks come from its
            # links, resolved against the requested URL. Content runs
            # through the same Markdown.clean as the converting backends,
            # so decorative symbol noise is stripped here too; a page
            # whose only "content" was noise falls through as empty. A
            # registrar parking page renders fine through Jina — the
            # shared guard's prose markers catch it (the HTML-only
            # markers never reach a markdown-only backend), so the ad is
            # rejected, not returned as the site's content.
            guard_page!(url, content)

            { title: nil, description: nil, content: content, outlinks: markdown_outlinks(body, url) }
          when '429'
            raise ServerError.new('rate limited by Jina', status: 429,
                                  hint: "Jina free tier limit hit — wait or set JINA_API_KEY")
          when '401', '403'
            raise FetchError.new("Jina access error", status: res.code.to_i,
                                 hint: "site blocked automated requests or Jina denied access")
          else
            # 5xx = Jina-side blip (transient); other 4xx = the URL is dead.
            code = res.code.to_i
            error_class = code == 404 ? NotFoundError : (code >= 500 ? ServerError : FetchError)
            raise error_class.new("Jina returned #{res.code}", status: code,
                                  hint: code >= 500 ? "Jina-side error — try again later" : nil)
          end
        rescue Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNREFUSED,
               Errno::ECONNRESET, SocketError, URI::InvalidURIError => e
          raise TimeoutError.new("Jina #{e.class}: #{e.message}",
                                 hint: "Jina service unreachable — try another backend")
        end
      end
    end
  end
end
