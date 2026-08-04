# frozen_string_literal: true

require 'ask-tools'
require 'net/http'
require 'uri'
require 'nokogiri'
require 'reverse_markdown'

module Ask
  module Tools
    # Fetches a URL and returns its content as clean markdown for LLM
    # consumption. Pure Ruby: Net::HTTP + Nokogiri + reverse_markdown.
    # No external service or API key required.
    class WebFetch < Ask::Tool
      USER_AGENT = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) ' \
                   'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36 ' \
                   "ask-web-fetch/#{Ask::WebFetch::VERSION}".freeze
      DEFAULT_MAX_CHARS = 20_000
      MAX_REDIRECTS = 5
      OPEN_TIMEOUT = 5
      READ_TIMEOUT = 15

      # Class/id fragments that mark navigation chrome worth dropping, e.g.
      # "vector-page-toolbar", "sidebar", "toc".
      NAV_CHROME_RE = /
        (^|[\s_-])(nav|menu|toolbar|breadcrumb|sidebar|toc|footer|header|
        banner|pagination|search|cookie|modal|popup)([\s_-]|$)
      /ix

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
        body, content_type = fetch(url)
        raise "WebFetch expected HTML from #{url}, got #{content_type}" unless content_type.include?('html')

        markdown = to_markdown(body, url)
        markdown = truncate(markdown, max_chars) if max_chars&.positive?
        Ask::Result.ok(data: markdown)
      end

      private

      # GET with redirect following (max MAX_REDIRECTS hops). Raises on
      # non-2xx responses; Ask::Tool#call wraps exceptions into a failure.
      def fetch(url)
        uri = URI(url)
        hops = 0
        loop do
          http = Net::HTTP.new(uri.host, uri.port)
          http.open_timeout = OPEN_TIMEOUT
          http.read_timeout = READ_TIMEOUT
          http.use_ssl = uri.scheme == 'https'
          req = Net::HTTP::Get.new(uri)
          req['User-Agent'] = USER_AGENT
          req['Accept'] = 'text/html,application/xhtml+xml'
          res = http.request(req)
          return [res.body, res['content-type'].to_s] if res.code.start_with?('2')

          raise "WebFetch got #{res.code} from #{url}" unless res.code.start_with?('3') && res['location']
          raise "WebFetch hit a redirect loop at #{url}" if (hops += 1) > MAX_REDIRECTS

          uri = URI.join(uri, res['location'])
        end
      end

      def to_markdown(html, url)
        doc = Nokogiri::HTML(html)
        candidate = extract_main(doc)
        scrub(candidate)
        markdown = ReverseMarkdown.convert(candidate.to_html, unknown_tags: :bypass, github_flavored: true)
        markdown = clean(markdown)
        return "No readable content found at #{url}." if markdown.empty?

        header = +''
        title = doc.at('title')&.text&.strip
        header << "# #{title}\n\n" unless title.to_s.empty?
        header << "Source: #{url}\n\n"
        header + markdown
      end

      def extract_main(doc)
        doc.at('article') || doc.at('main') || doc.at('[role="main"]') || doc.at('body') || doc
      end

      # Remove chrome INSIDE the candidate only, never ancestors.
      def scrub(candidate)
        candidate.css('script, style, noscript, nav, footer, header, iframe, form, svg, aside').each(&:remove)
        candidate.css('*[id], *[class]').each do |el|
          next if el.equal?(candidate)

          id_cls = [el['id'], el['class']].compact.join(' ')
          el.remove if id_cls.match?(NAV_CHROME_RE)
        end
        candidate
      end

      def clean(markdown)
        markdown.gsub(/[ \t]+\n/, "\n")
                .gsub(/\n{3,}/, "\n\n")
                .strip
      end

      def truncate(markdown, max_chars)
        return markdown if markdown.length <= max_chars

        "#{markdown[0, max_chars].rstrip}\n\n…(truncated)"
      end
    end
  end
end

Ask::Tools.register(Ask::Tools::WebFetch) if defined?(Ask::Tools)
