# frozen_string_literal: true

module Ask
  module WebFetch
    # Strips decorative symbol noise from markdown: the long, letter-free,
    # repetitive character streams pages render as animated backgrounds,
    # marquees and section dividers — e.g. Hugging Face's storage page
    # ships a "+ = · ( ~ @ # % & * ? / : ; < > [ ] { } | ^ $ !" stream as
    # its page background. Runs on CONVERTED markdown, so every backend
    # benefits: Local and Browser already convert through Markdown, and
    # Jina and Crawl4AI hand the gem pre-converted markdown — the
    # DOM-level ContentFilter never sees either case.
    #
    # Conservative by design. A line is dropped only when ALL hold:
    #
    #   * it is long enough to matter (>= min_length characters)
    #   * it contains no letters or digits at all
    #   * it is repetitive — at least two distinct characters, with a
    #     distinct/length ratio below max_entropy (a repeated stream,
    #     not prose punctuation)
    #   * it is not markdown structure: fenced or indented code, table
    #     rows, headings, blockquotes, inline code, raw HTML, math
    #
    # Short decorative fragments (an ASCII-art header like "*****"),
    # single-character runs ("-----" dividers), and everything containing
    # words survive. Lines whose only content is invisible characters
    # (zero-width spaces, combining marks) are always dropped — they carry
    # nothing. Blank lines are untouched.
    class NoiseFilter
      # Longest line that is never touched, whatever its contents.
      DEFAULT_MIN_LENGTH = 32

      # Highest distinct-chars/length ratio a line may have and still
      # count as repetitive. Below this the line reads as a repeated
      # stream; above it, as prose punctuation (kept).
      DEFAULT_MAX_ENTROPY = 0.3

      # Characters that never render: zero-width space/joiner and bidi
      # controls, the BOM, and combining marks.
      INVISIBLE_RE = /[\u200B-\u200F\uFEFF\u2060\u00AD\p{Mn}]/.freeze

      # A line starting with one of these is structure, not noise:
      # headings, blockquotes, inline code, raw HTML, math, table rows.
      STRUCTURE_PREFIX_RE = /\A[#>`<$|]/.freeze

      # GFM table separator rows — "| --- | --- |" or the pipe-only
      # "--- | ---" variant — are dashes, pipes, colons and spaces only.
      # Kept as structure; the noise streams this filter targets always
      # mix in other symbol types (+ = · ~ @ # % …), which this narrow
      # pattern cannot match, so it is safe to exempt the whole class.
      TABLE_SEPARATOR_RE = /\A\|?[\s\-:|]+\|?\z/.freeze

      # Fenced code opener/closer: three or more backticks or tildes,
      # optionally with an info string.
      FENCE_RE = /\A(?:`{3,}|~{3,})/.freeze

      class << self
        # Returns +markdown+ with decorative noise lines removed. The
        # options override the conservative defaults.
        def filter(markdown, min_length: DEFAULT_MIN_LENGTH, max_entropy: DEFAULT_MAX_ENTROPY)
          new(min_length: min_length, max_entropy: max_entropy).filter(markdown)
        end
      end

      def initialize(min_length: DEFAULT_MIN_LENGTH, max_entropy: DEFAULT_MAX_ENTROPY)
        @min_length = min_length
        @max_entropy = max_entropy
      end

      def filter(markdown)
        out = +''
        in_fence = false
        in_indented_code = false
        prev_blank = false

        markdown.each_line do |line|
          stripped = line.strip

          # Fenced code: flip on any fence opener/closer, then pass the
          # whole block through untouched — code may legitimately be
          # nothing but symbols.
          if stripped.match?(FENCE_RE)
            in_fence = !in_fence
            out << line
            next
          end
          if in_fence
            out << line
            next
          end

          # Indented code (GFM-ish: 4+ leading spaces, ends at a blank
          # line). Passed through untouched for the same reason.
          if in_indented_code && stripped.empty?
            in_indented_code = false
            out << line
            next
          end
          indented = line.start_with?('    ', "\t")
          if indented && (in_indented_code || prev_blank)
            in_indented_code = true
            out << line
            next
          end

          prev_blank = stripped.empty?
          out << line unless noise_line?(stripped)
        end
        out
      end

      private

      def noise_line?(stripped)
        # Blank lines are structure — never touched.
        return false if stripped.empty?

        # Nothing but invisible characters renders as blank: pure waste.
        return true if stripped.gsub(INVISIBLE_RE, '').empty?

        # Words and numbers are content, whatever surrounds them.
        return false if stripped.match?(/[A-Za-z0-9]/)

        # Structural markers and anything too short to matter survive
        # even when symbol-only.
        return false if stripped.match?(STRUCTURE_PREFIX_RE)
        return false if stripped.length < @min_length

        # Table separator rows ("--- | ---") are structure even without a
        # leading pipe — dash/pipe/colon-only lines are dividers either
        # way, and real noise streams never match their narrow alphabet.
        return false if stripped.match?(TABLE_SEPARATOR_RE)

        chars = stripped.gsub(/\s/, '')
        distinct = chars.chars.uniq.length
        return false if distinct < 2
        return false if distinct.fdiv(chars.length) >= @max_entropy

        true
      end
    end
  end
end
