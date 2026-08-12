# frozen_string_literal: true

require 'ask-tools'

module Ask
  module Tools
    # The native agent tool for web fetch — the Ask::Tool framing of the
    # library. Consumed WITHOUT MCP by agent frameworks (ask-agent's
    # `tool: :web_fetch`, ask-app-server, llm-proxy) that resolve tools
    # from the Ask::Tools registry. It is a pure adapter: the capability
    # (chain, collapse, format) lives in Ask::WebFetch, and this file is
    # loaded only when ask-tools is present (see lib/ask/web_fetch.rb), so
    # the library itself never depends on it.
    class WebFetch < Ask::Tool
      # Chain configuration delegates to the library — swap or extend
      # backends here or via Ask::WebFetch.backends.
      def self.backends
        Ask::WebFetch.backends
      end

      def self.backends=(chain)
        Ask::WebFetch.backends = chain
      end

      description 'Fetch a URL and return its content as clean markdown for LLM consumption. ' \
                  'Use this to read web pages, articles, and documentation.'

      params(
        type: 'object',
        properties: {
          url: { type: 'string', description: 'The URL to fetch' },
          max_chars: { type: 'integer', description: 'Maximum number of characters to return (default 20000)' }
        },
        required: ['url']
      )

      def execute(url:, max_chars: Ask::WebFetch::DEFAULT_MAX_CHARS)
        Ask::Result.ok(data: Ask::WebFetch.fetch(url, max_chars: max_chars))
      end
    end
  end
end

Ask::Tools.register(Ask::Tools::WebFetch)
