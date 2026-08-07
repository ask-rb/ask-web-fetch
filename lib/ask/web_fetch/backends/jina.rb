# frozen_string_literal: true

require 'net/http'
require 'uri'
require_relative '../backend'

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
            raise EmptyContentError, 'empty response from Jina' unless usable_content?(body)

            { title: nil, description: nil, content: body.strip }
          when '429'
            raise FetchError, 'rate limited by Jina (429)'
          when '401', '403'
            raise FetchError, "Jina access error (#{res.code})"
          else
            raise FetchError, "Jina returned #{res.code}"
          end
        rescue Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNREFUSED,
               Errno::ECONNRESET, SocketError, URI::InvalidURIError => e
          raise FetchError, "Jina #{e.class}: #{e.message}"
        end
      end
    end
  end
end
