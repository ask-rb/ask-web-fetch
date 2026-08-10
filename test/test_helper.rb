# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'ask-web-fetch'

require 'minitest/autorun'

require 'webmock/minitest'

# One-hop transport stub for the Local backend's injectable HTTP seam.
# The handler receives (url, headers) and returns an
# Ask::WebFetch::Http::Response, or raises whatever the backend should
# wrap (Errno, Ask::WebFetch::TimeoutError, ...). Production wires the
# same seam to the pooled httpx Ask::WebFetch::Http.
class StubHttp
  attr_accessor :handler

  def initialize(&handler)
    @handler = handler
  end

  def get(url, headers: {})
    handler.call(url, headers)
  end
end

# Builds a hop's answer for StubHttp handlers.
def http_response(status, body, content_type: 'text/html', location: nil)
  Ask::WebFetch::Http::Response.new(status: status, body: body,
                                    content_type: content_type, location: location)
end
