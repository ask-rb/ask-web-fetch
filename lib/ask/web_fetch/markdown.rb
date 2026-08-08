# frozen_string_literal: true

require 'nokogiri'
require 'reverse_markdown'
require 'uri'

module Ask
  module WebFetch
    # HTML -> clean markdown, shared by the backends. Owns the conversion
    # pipeline that used to live inside Local:
    #
    #   1. pick the content region — either a ContentFilter prunes the whole
    #      page by text density, or the article/main/body region is taken
    #   2. drop chrome (scripts, nav, forms, keyword-matched junk)
    #   3. convert with reverse_markdown
    #   4. optionally rewrite inline links as numbered citations (ported from
    #      crawl4ai's DefaultMarkdownGenerator, Apache-2.0)
    module Markdown
      # Class/id fragments that mark navigation chrome worth dropping, e.g.
      # "vector-page-toolbar", "sidebar", "toc".
      NAV_CHROME_RE = /
        (^|[\s_-])(nav|menu|toolbar|breadcrumb|sidebar|toc|footer|header|
        banner|pagination|search|cookie|modal|popup)([\s_-]|$)
      /ix

      # Tags that never carry article content, dropped before conversion.
      EXCLUDED_TAGS = %w[script style noscript nav footer header aside form iframe svg].freeze

      # Matches markdown links, optionally with a title, for citation
      # rewriting. Ported from crawl4ai's LINK_PATTERN.
      LINK_PATTERN = /
        !?\[((?:[^\[\]]|\[(?:[^\[\]]|\[[^\]]*\])*\])*)\]
        \(((?:[^()\s]|\([^()]*\))*)(?:\s+"([^"]*)")?\)
      /x

      module_function

      # html -> { title:, description:, content: }.
      #
      # When +filter+ is given (a ContentFilter), content is the pruned "fit"
      # version. If pruning empties the page the article/main/body region is
      # used instead, so a sparse page never degrades to empty content. When
      # +citations+ is true, inline links become numbered citations with a
      # trailing References section.
      def generate(html, base_url: '', filter: nil, citations: false)
        html = html.to_s
        doc = Nokogiri::HTML(html)
        input = filtered(html, doc, filter)
        markdown = ReverseMarkdown.convert(input, unknown_tags: :bypass, github_flavored: true)
        markdown = clean(markdown)
        markdown = cite(markdown, base_url) if citations

        {
          title: doc.at('title')&.text&.strip,
          description: meta_description(doc),
          content: markdown
        }
      end

      # Picks the article/main/body region and returns it scrubbed, as HTML.
      def cleaned_html(doc)
        candidate = doc.at('article') || doc.at('main') || doc.at('[role="main"]') || doc.at('body') || doc
        scrub(candidate)
        candidate.to_html
      end

      # Remove chrome INSIDE the candidate only, never ancestors.
      def scrub(candidate)
        candidate.css(EXCLUDED_TAGS.join(',')).each(&:remove)
        candidate.css('*[id], *[class]').each do |el|
          next if el.equal?(candidate)

          id_cls = [el['id'], el['class']].compact.join(' ')
          el.remove if id_cls.match?(NAV_CHROME_RE)
        end
        candidate
      end

      def meta_description(doc)
        desc = doc.at('meta[name="description"]')&.[]('content')&.strip
        desc = doc.at('meta[property="og:description"]')&.[]('content')&.strip if desc.to_s.empty?
        desc
      end

      # Converts inline links to numbered citations and returns
      # [converted, references] where references is a "## References" block
      # listing each unique URL once — empty when the markdown had no links.
      # Ported from crawl4ai.
      def convert_links_to_citations(markdown, base_url = '')
        link_map = {} # url => [number, description]
        parts = []
        last_end = 0
        counter = 1

        pos = 0
        while (match = LINK_PATTERN.match(markdown, pos))
          parts << markdown[last_end...match.begin(0)]
          text, url, title = match.captures

          absolute = url.start_with?('http://', 'https://', 'mailto:')
          url = fast_urljoin(base_url, url) if !base_url.to_s.empty? && !absolute

          unless link_map.key?(url)
            description = +''
            description << title.to_s if title
            if text && text != title
              description << (description.empty? ? text.to_s : " - #{text}")
            end
            link_map[url] = [counter, description.empty? ? '' : ": #{description}"]
            counter += 1
          end

          number = link_map[url][0]
          parts << (match[0].start_with?('!') ? "![#{text}⟨#{number}⟩]" : "#{text}⟨#{number}⟩")
          last_end = match.end(0)
          pos = match.end(0)
        end

        return [markdown, ''] if link_map.empty?

        parts << markdown[last_end..].to_s
        references = ["\n\n## References\n\n"]
        link_map.sort_by { |_, (number, _)| number }.each do |url, (number, description)|
          references << "⟨#{number}⟩ #{url}#{description}\n"
        end
        [parts.join, references.join]
      end

      def clean(markdown)
        markdown.gsub(/[ \t]+\n/, "\n")
                .gsub(/\n{3,}/, "\n\n")
                .strip
      end

      # Resolves +url+ against +base+ without re-parsing absolute URLs.
      # crawl4ai's version of this concatenates root-absolute paths onto the
      # base ("/stats" against "https://x.com/news/2026" becomes
      # "…/news/2026/stats"), which mangles root-relative links; URI.join has
      # correct URL semantics and the passthrough covers the hot path.
      def fast_urljoin(base, url)
        return url if url.start_with?('http://', 'https://', 'mailto:', '//')

        URI.join(base, url).to_s
      end

      def filtered(html, doc, filter)
        return cleaned_html(doc) unless filter

        fit = filter.fit_html(html)
        fit.empty? ? cleaned_html(doc) : fit
      end

      def cite(markdown, base_url)
        converted, references = convert_links_to_citations(markdown, base_url)
        "#{converted}#{references}"
      end
    end
  end
end
