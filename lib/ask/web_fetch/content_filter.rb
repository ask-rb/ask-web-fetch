# frozen_string_literal: true

require 'nokogiri'

module Ask
  module WebFetch
    # Density-based content pruning, ported from crawl4ai's
    # PruningContentFilter (Apache-2.0, https://github.com/unclecode/crawl4ai).
    #
    # Scores every element in the page by how much of it is real text versus
    # markup and links, then removes elements scoring below a threshold. Where
    # a keyword scraper fails ("remove anything with 'nav' in the class"),
    # this keeps content that scores well regardless of its label and drops
    # link-farms that happen to dodge the keywords.
    #
    # Two deliberate deviations from crawl4ai, both adding tags crawl4ai's own
    # included_tags list marks as content but whose tag_weights map left out
    # (they defaulted to 0.5 and could be pruned despite being article
    # content): <main> joins <article>/<section> at the top tier, and the
    # table/pre/code family gets content-worthy weights. Third: the class/id
    # chrome penalty actually subtracts from the score — crawl4ai floors it at
    # zero (max(0, ...)), which makes its negative-patterns metric inert.
    class ContentFilter
      # Structural boilerplate, removed before scoring ever runs. The
      # preserve_* whitelist cannot save these.
      EXCLUDED_TAGS = %w[nav footer header aside script style form iframe noscript].freeze

      # Class/id fragments that mark non-content chrome; matching one knocks
      # 0.5 off the node's score.
      NEGATIVE_PATTERNS = /nav|footer|header|sidebar|ads|comment|promo|advert|social|share/i.freeze

      # Semantic tag weights: how likely a tag is to carry article content.
      TAG_WEIGHTS = {
        'div' => 0.5, 'p' => 1.0, 'article' => 1.5, 'section' => 1.0, 'main' => 1.4,
        'span' => 0.3, 'li' => 0.5, 'ul' => 0.5, 'ol' => 0.5,
        'h1' => 1.2, 'h2' => 1.1, 'h3' => 1.0, 'h4' => 0.9, 'h5' => 0.8, 'h6' => 0.7,
        'table' => 1.0, 'tr' => 0.8, 'td' => 0.8, 'th' => 0.8,
        'pre' => 1.0, 'code' => 0.9, 'blockquote' => 1.0
      }.freeze

      # Used only by the dynamic threshold, which loosens the bar for tags
      # that usually carry content.
      TAG_IMPORTANCE = {
        'article' => 1.5, 'main' => 1.4, 'section' => 1.3, 'p' => 1.2,
        'h1' => 1.4, 'h2' => 1.3, 'h3' => 1.2, 'div' => 0.7, 'span' => 0.6
      }.freeze

      METRIC_WEIGHTS = {
        text_density: 0.4, link_density: 0.2, tag_weight: 0.2,
        class_id_weight: 0.1, text_length: 0.1
      }.freeze

      DEFAULT_THRESHOLD = 0.48

      # threshold::   score below this removes the element
      # threshold_type:: :fixed or :dynamic — dynamic loosens the bar for
      #                important tags and text-heavy, link-light nodes
      # min_word_threshold:: elements with fewer words are removed outright
      # preserve_classes:: class names never pruned, regardless of score
      # preserve_tags::   tag names never pruned, regardless of score
      def initialize(threshold: DEFAULT_THRESHOLD, threshold_type: :fixed,
                     min_word_threshold: nil, preserve_classes: [], preserve_tags: [])
        @threshold = threshold
        @threshold_type = threshold_type.to_sym
        @min_word_threshold = min_word_threshold
        @preserve_classes = preserve_classes
        @preserve_tags = preserve_tags
      end

      # html -> [String] the surviving top-level blocks, as HTML fragments.
      # Empty input yields an empty array; malformed HTML is parsed with
      # Nokogiri's recover mode and never raises.
      def filter_content(html)
        return [] if html.nil? || html.empty?

        doc = Nokogiri::HTML(html)
        body = doc.at_css('body') || doc.at_css('html')
        return [] unless body

        remove_comments(doc)
        body.css(EXCLUDED_TAGS.join(',')).each(&:remove)
        body.element_children.each { |child| prune(child) }

        body.element_children.select { |el| el.text.strip.length.positive? }.map(&:to_html)
      end

      # html -> String, the surviving blocks wrapped in <div>s, ready for
      # markdown conversion. Mirrors crawl4ai's generator, which wraps the
      # filtered blocks before converting them.
      def fit_html(html)
        filter_content(html).map { |block| "<div>#{block}</div>" }.join
      end

      private

      def prune(node)
        if preserved?(node)
          # A whitelisted node survives whole — no scoring, no child pruning.
          return
        end

        text_len = node.text.gsub(/\s+/, '').length
        tag_len = node.inner_html.length
        link_text_len = node.element_children
                             .select { |child| child.name == 'a' }
                             .sum { |a| a.text.strip.length }

        if should_remove?(node, text_len, tag_len, link_text_len)
          node.remove
        else
          node.element_children.each { |child| prune(child) }
        end
      end

      def preserved?(node)
        return true if @preserve_tags.include?(node.name)

        classes = node['class']
        classes && @preserve_classes.any? { |c| classes.split.include?(c) }
      end

      def should_remove?(node, text_len, tag_len, link_text_len)
        if @threshold_type == :dynamic
          threshold = @threshold
          importance = TAG_IMPORTANCE.fetch(node.name, 0.7)
          text_ratio = tag_len.positive? ? text_len.to_f / tag_len : 0.0
          link_ratio = text_len.positive? ? link_text_len.to_f / text_len : 1.0
          threshold *= 0.8 if importance > 1.0
          threshold *= 0.9 if text_ratio > 0.4
          threshold *= 1.2 if link_ratio > 0.6
          score(node, text_len, tag_len, link_text_len) < threshold
        else
          score(node, text_len, tag_len, link_text_len) < @threshold
        end
      end

      # Weighted composite in [0, ~1.4]: text density, link density, semantic
      # tag weight, class/id chrome penalty, and log-scaled text length.
      #
      # text_len is measured with all whitespace removed, matching
      # BeautifulSoup's get_text(strip=True) that crawl4ai uses — stripping
      # only the ends would let inter-tag whitespace inflate the density and
      # length metrics and keep link-farms alive.
      def score(node, text_len, tag_len, link_text_len)
        return -1.0 if @min_word_threshold && node.text.split.size < @min_word_threshold

        density = tag_len.positive? ? text_len.to_f / tag_len : 0.0
        link_density = text_len.positive? ? 1.0 - (link_text_len.to_f / text_len) : 0.0
        tag_score = TAG_WEIGHTS.fetch(node.name, 0.5)
        class_score = class_id_score(node)

        weighted = 0.0
        weighted += METRIC_WEIGHTS[:text_density] * density
        weighted += METRIC_WEIGHTS[:link_density] * link_density
        weighted += METRIC_WEIGHTS[:tag_weight] * tag_score
        weighted += METRIC_WEIGHTS[:class_id_weight] * class_score
        weighted += METRIC_WEIGHTS[:text_length] * Math.log(text_len + 1)
        weighted / METRIC_WEIGHTS.values.sum
      end

      def class_id_score(node)
        score = 0.0
        score -= 0.5 if node['class'].to_s.match?(NEGATIVE_PATTERNS)
        score -= 0.5 if node['id'].to_s.match?(NEGATIVE_PATTERNS)
        score
      end

      def remove_comments(doc)
        doc.xpath('//comment()').each(&:remove)
      end
    end
  end
end
