# frozen_string_literal: true

require_relative 'web_fetch/version'
require_relative 'web_fetch/backend'
require_relative 'web_fetch/content_filter'
require_relative 'web_fetch/markdown'
require_relative 'web_fetch/http'
require_relative 'web_fetch/backends/local'
require_relative 'web_fetch/backends/crawl4ai'
require_relative 'web_fetch/backends/jina'
require_relative 'web_fetch/backends/browser'

# The native agent tool (Ask::Tools::WebFetch) is an OPTIONAL integration:
# it loads and registers only when ask-tools is present. The library works
# standalone — backend-only consumers (crawlers, pipelines) pay nothing —
# while agent frameworks (ask-agent, ask-app-server, llm-proxy) all ship
# ask-tools and get the registry tool with no extra step. Only the
# ask-tools miss is swallowed; any other LoadError is real.
begin
  require 'ask-tools'
  require_relative 'web_fetch/tool'
rescue LoadError => e
  raise unless e.path == 'ask-tools'
end

module Ask
  # Fetches a URL and returns its content as clean markdown for LLM
  # consumption. The capability layer: a pluggable backend chain, a
  # failure collapse, and one entry point. Tool framing — name,
  # parameter schema, result wrapping — lives with the consumers (the
  # MCP servers, the agents) that call this library, not here.
  module WebFetch
    DEFAULT_MAX_CHARS = 20_000

    # Errors that mean "the URL is dead" — no amount of retrying changes
    # the answer. When EVERY backend failed this way, the aggregate
    # re-raises as FetchError so callers can fail fast; any transient
    # failure in the mix (timeout, 5xx, empty render) keeps the base
    # Error, which recovers on retry.
    DETERMINISTIC = [Ask::WebFetch::FetchError, Ask::WebFetch::NotFoundError, Ask::WebFetch::EmptyContentError].freeze

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

    # Fetches +url+ through the chain and returns the first success as
    # { title:, description:, content:, outlinks:, redirected: }. Raises
    # when every backend fails; the raised class carries the verdict (see
    # #collapse) and the message lists every backend and what it said.
    def self.fetch_page(url)
      failures = []
      backends.each do |backend_class|
        return backend_class.new.fetch(url)
      rescue Ask::WebFetch::Error => e
        failures << [backend_class, e]
      end
      collapse(failures, url)
    end

    # Collapses every backend's failure into ONE error whose class
    # carries the best explanation. Precedence, most definitive first: a
    # parked domain beats an empty shell (the shell IS the parking ad's
    # shell — Local sees the JS redirect stub, Browser the lander),
    # empty beats a dead 4xx (the page existed, it just had no content),
    # and any deterministic explanation beats a transient one (transient
    # keeps the retryable base Error). Clients read the class:
    # ParkedDomainError / EmptyContentError / FetchError are terminal —
    # retrying never changes the answer; Error may recover on retry.
    def self.collapse(failures, url)
      # When all backends agree on the same root cause (same HTTP status),
      # say so cleanly instead of listing every backend's echo of the same
      # problem. Status is now on the error object itself (FetchError#status,
      # NotFoundError#status), so we don't parse messages.
      statuses = failures.filter_map { |_, e| e.respond_to?(:status) && e.status }
      detail = if statuses.uniq.size == 1 && statuses.size == failures.size
                 "[#{statuses.first}]"
               else
                 failures.map { |backend, e| "#{backend.backend_name}: #{e.message}" }.join('; ')
               end
      message = "#{detail} #{url}"

      classes = failures.map { |_, e| e.class }
      if classes.any? { |k| k <= Ask::WebFetch::ParkedDomainError }
        raise Ask::WebFetch::ParkedDomainError, message
      end
      if classes.any? { |k| k <= Ask::WebFetch::EmptyContentError }
        raise Ask::WebFetch::EmptyContentError, message
      end
      if classes.any? { |k| k == Ask::WebFetch::NotFoundError }
        raise Ask::WebFetch::NotFoundError, message
      end

      deterministic = failures.all? { |_, e| DETERMINISTIC.any? { |klass| e.is_a?(klass) } }
      raise(deterministic ? Ask::WebFetch::FetchError : Ask::WebFetch::Error, message)
    end

    # Fetches +url+ and returns LLM-ready markdown — "# Title\n\nSource:
    # url\n\ncontent" — capped at +max_chars+ (default 20000; pass nil to
    # skip the cap). The single entry point for "give me this page as
    # markdown"; the raw page hash is #fetch_page.
    def self.fetch(url, max_chars: DEFAULT_MAX_CHARS)
      page = fetch_page(url)
      markdown = format(page, url)
      markdown = truncate(markdown, max_chars) if max_chars&.positive?
      markdown
    end

    def self.format(page, url)
      header = +''
      title = page[:title]
      header << "# #{title}\n\n" unless title.to_s.empty?
      header << "Source: #{url}\n\n"
      header + page[:content]
    end
    private_class_method :format

    def self.truncate(markdown, max_chars)
      return markdown if markdown.length <= max_chars

      "#{markdown[0, max_chars].rstrip}\n\n…(truncated)"
    end
    private_class_method :truncate
  end
end
