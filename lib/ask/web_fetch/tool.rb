# frozen_string_literal: true

require 'ask-tools'
require_relative '../web_fetch/backend'
require_relative '../web_fetch/backends/local'
require_relative '../web_fetch/backends/crawl4ai'
require_relative '../web_fetch/backends/jina'

module Ask
  module Tools
    # Fetches a URL and returns its content as clean markdown for LLM
    # consumption. Tries each configured backend in order and returns the
    # first success.
    #
    # Chain: Crawl4AI first (self-hosted headless-Chromium renderer; used
    # when the CRAWL4AI_URL service is present, fails fast when it isn't),
    # then the local fetcher, Jina Reader as the last resort, and a real
    # Chrome (via Ferrum) at the very end for pages whose Cloudflare-style
    # challenges the others cannot pass — appended only when a browser
    # binary is present.
    class WebFetch < Ask::Tool
      DEFAULT_MAX_CHARS = 20_000

      # Backend chain, tried in order. Crawl4AI leads when configured
      # (CRAWL4AI_URL), so a present self-hosted renderer is preferred;
      # otherwise Local, with Jina as the last resort, and Browser appended
      # when Chrome is available. Swap or extend for future backends; each
      # must subclass Ask::WebFetch::Backend and implement #fetch(url).
      def self.backends
        @backends ||= begin
          chain = [Ask::WebFetch::Backends::Local, Ask::WebFetch::Backends::Jina]
          if Ask::WebFetch::Backends::Crawl4Ai.configured?
            chain.unshift(Ask::WebFetch::Backends::Crawl4Ai)
          end
          chain << Ask::WebFetch::Backends::Browser if Ask::WebFetch::Backends::Browser.configured?
          chain
        end
      end

      class << self
        attr_writer :backends
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

      def execute(url:, max_chars: DEFAULT_MAX_CHARS)
        page = fetch_page(url)
        markdown = format(page, url)
        markdown = truncate(markdown, max_chars) if max_chars&.positive?
        Ask::Result.ok(data: markdown)
      end

      private

      # Try each configured backend in order; return the first success.
      def fetch_page(url)
        failures = []
        self.class.backends.each do |backend_class|
          return backend_class.new.fetch(url)
        rescue Ask::WebFetch::Error => e
          failures << "#{backend_class.backend_name}: #{e.message}"
        end
        raise Ask::WebFetch::Error,
              "all web fetch backends failed for #{url} (#{failures.join('; ')})"
      end

      def format(page, url)
        header = +''
        title = page[:title]
        header << "# #{title}\n\n" unless title.to_s.empty?
        header << "Source: #{url}\n\n"
        header + page[:content]
      end

      def truncate(markdown, max_chars)
        return markdown if markdown.length <= max_chars

        "#{markdown[0, max_chars].rstrip}\n\n…(truncated)"
      end
    end
  end
end

Ask::Tools.register(Ask::Tools::WebFetch) if defined?(Ask::Tools)
