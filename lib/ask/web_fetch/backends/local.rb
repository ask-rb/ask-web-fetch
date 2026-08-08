# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'nokogiri'
require 'reverse_markdown'
require_relative '../backend'

module Ask
  module WebFetch
    module Backends
      # Default backend: pure Ruby Net::HTTP + Nokogiri + reverse_markdown.
      # No external service or API key; mirrors ask-web-search's self-hosted
      # SearXNG approach.
      class Local < Backend
        MAX_REDIRECTS = 5
        OPEN_TIMEOUT = 5
        READ_TIMEOUT = 15

        # Class/id fragments that mark navigation chrome worth dropping, e.g.
        # "vector-page-toolbar", "sidebar", "toc".
        NAV_CHROME_RE = /
          (^|[\s_-])(nav|menu|toolbar|breadcrumb|sidebar|toc|footer|header|
          banner|pagination|search|cookie|modal|popup)([\s_-]|$)
        /ix

        def fetch(url)
          body, content_type, redirect = fetch_html(url)
          raise FetchError, "expected HTML from #{url}, got #{content_type}" unless content_type.include?('html')
          raise FetchError, "challenge page at #{url}" if challenge_page?(body)

          page = to_markdown(body, url)
          page[:redirected] = redirect
          raise EmptyContentError, "no readable content at #{url}" unless usable_content?(page[:content])

          page
        rescue Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNREFUSED,
               Errno::ECONNRESET, SocketError, URI::InvalidURIError => e
          raise TimeoutError, "#{e.class}: #{e.message}"
        end

        # Parses +html+ and returns { title:, description:, content: } where
        # content is clean markdown and description is the page's own meta
        # description (meta name=description, then og:description) — what the
        # site says about itself, free and authoritative.
        def to_markdown(html, _url)
          doc = Nokogiri::HTML(html)
          candidate = extract_main(doc)
          scrub(candidate)
          markdown = ReverseMarkdown.convert(candidate.to_html, unknown_tags: :bypass, github_flavored: true)
          markdown = clean(markdown)
          title = doc.at('title')&.text&.strip
          { title: title, description: meta_description(doc), content: markdown }
        end

        def meta_description(doc)
          desc = doc.at('meta[name="description"]')&.[]('content')&.strip
          desc = doc.at('meta[property="og:description"]')&.[]('content')&.strip if desc.to_s.empty?
          desc
        end

        private

        # GET with redirect following (max MAX_REDIRECTS hops). Returns
        # [body, content_type, redirect] where redirect is nil when the
        # URL answered directly, else {status: first hop's status,
        # url: final destination} — the chain the crawler followed.
        def fetch_html(url)
          uri = URI(url)
          hops = 0
          first_hop_status = nil
          loop do
            http = Net::HTTP.new(uri.host, uri.port)
            http.open_timeout = OPEN_TIMEOUT
            http.read_timeout = READ_TIMEOUT
            http.use_ssl = uri.scheme == 'https'
            req = Net::HTTP::Get.new(uri)
            req['User-Agent'] = USER_AGENT
            req['Accept'] = 'text/html,application/xhtml+xml'
            res = http.request(req)
            return [res.body, res['content-type'].to_s, redirect_info(first_hop_status, uri)] if res.code.start_with?('2')

            unless res.code.start_with?('3') && res['location']
              # 4xx (other than 429) = the URL is dead; 429/5xx = transient.
              code = res.code.to_i
              raise(code == 429 || code >= 500 ? ServerError : FetchError, "got #{res.code} from #{url}")
            end
            raise FetchError, "hit a redirect loop at #{url}" if (hops += 1) > MAX_REDIRECTS

            first_hop_status ||= res.code.to_i
            uri = URI.join(uri, res['location'])
          end
        end

        def redirect_info(status, uri)
          status && {status: status, url: uri.to_s}
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
      end
    end
  end
end
