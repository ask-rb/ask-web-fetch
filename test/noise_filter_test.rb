# frozen_string_literal: true

require_relative 'test_helper'

describe Ask::WebFetch::NoiseFilter do
  def filter(markdown, **kwargs)
    Ask::WebFetch::NoiseFilter.filter(markdown, **kwargs)
  end

  # The exact class of noise that started this: Hugging Face's storage
  # page renders an animated symbol stream as its background, which lands
  # in the DOM — and so in the markdown — as long repeated runs of
  # special characters (reverse_markdown escapes the * < > as markdown).
  SYMBOL_STREAM = ('+ = · ( ~ @ · # % · & \* ? · / : ; · \< \> · [] · { · } | · ^ $ · ! · ' * 6).freeze

  describe 'decorative symbol streams' do
    it 'drops a long letter-free repetitive line' do
      md = "# Storage\n\n#{SYMBOL_STREAM}\n\nReal content.\n"

      # The line filter removes the noise line and leaves the surrounding
      # blank lines alone — collapsing them is Markdown.clean's job.
      _(filter(md)).must_equal "# Storage\n\n\nReal content.\n"
      _(Ask::WebFetch::Markdown.clean(md)).must_equal "# Storage\n\nReal content."
    end

    it 'drops consecutive noise lines' do
      md = "#{SYMBOL_STREAM}\n#{SYMBOL_STREAM}\nReal content.\n"

      filtered = filter(md)
      _(filtered).wont_include '+ = ·'
      _(filtered).must_include 'Real content.'
    end

    it 'leaves noise-free markdown untouched' do
      md = "Hello world.\n\nSome more content here.\n"

      _(filter(md)).must_equal md
    end

    it 'runs as part of Markdown.clean, which every backend uses' do
      md = "Content.\n\n#{SYMBOL_STREAM}\n"

      _(Ask::WebFetch::Markdown.clean(md)).wont_include '+ = ·'
    end

    it 'raises nothing on empty input' do
      _(filter('')).must_equal ''
    end
  end

  describe 'structure that must survive' do
    it 'keeps fenced code blocks full of symbols' do
      code = "```\n=> => => => => => => => => => => => => => => => => =>\n" \
             "+ + + + + + + + + + + + + + + + + + + + + + + +\n```\n"

      _(filter("Text.\n\n#{code}")).must_include code
    end

    it 'keeps indented code blocks full of symbols' do
      code = "    => => => => => => => => => => => => => => => => => =>\n" \
             "    + + + + + + + + + + + + + + + + + + + + + + + +\n"

      _(filter("Text.\n\n#{code}")).must_include '=> => =>'
    end

    it 'keeps GFM table rows and separators' do
      table = "| a | b |\n| --- | --- |\n| 1 | 2 |\n"

      _(filter(table)).must_equal table
    end

    it 'keeps GFM table separators written without a leading pipe' do
      sep = '--------------------------|-------|----------|------------------'
      md = "domain | n_lang | n_pages | lang_counts\n#{sep}\n"

      _(filter(md)).must_equal md
    end

    it 'keeps long dash/pipe divider lines' do
      stream = "#{'-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-|-'}\n"

      _(filter(stream)).must_equal stream
    end

    it 'keeps horizontal rules' do
      _(filter("One.\n\n---\n\nTwo.\n")).must_equal "One.\n\n---\n\nTwo.\n"
      _(filter("***\n")).must_equal "***\n"
      _(filter("___\n")).must_equal "___\n"
    end

    it 'keeps headings, blockquotes, and inline code' do
      md = "# Title\n\n> quoted symbols + = ( ~ @ # %\n\nUse `+=~@#%&*?` inline.\n"

      _(filter(md)).must_equal md
    end

    it 'keeps raw HTML and math lines' do
      html = %(<div class="logo">+ + + + + + + + + + + + + + + + + + + + + + + +\n)
      _(filter(html)).must_equal html

      math = '$+ + + + + + + + + + + + + + + + + + + + + + + +$\n'
      _(filter(math)).must_equal math
    end

    it 'keeps short decorative fragments (ASCII-art headers)' do
      _(filter("*****\n")).must_equal "*****\n"
      _(filter("==== Welcome ====\n")).must_equal "==== Welcome ====\n"
    end

    it 'keeps long single-character runs (dividers)' do
      _(filter("#{'-' * 60}\n")).must_equal "#{'-' * 60}\n"
    end

    it 'keeps lines that mix words and symbols' do
      md = "Privacy Policy +++===--- and terms\n"

      _(filter(md)).must_equal md
    end

    it 'keeps blank lines' do
      md = "One.\n\n\nTwo.\n"

      _(filter(md)).must_equal "One.\n\n\nTwo.\n"
    end
  end

  describe 'invisible content' do
    it 'drops lines made only of zero-width characters' do
      md = "Text.\n\n#{("\u200B" * 40)}\n\nMore.\n"

      filtered = filter(md)
      _(filtered).wont_include "\u200B"
      _(filtered).must_include 'Text.'
      _(filtered).must_include 'More.'
    end
  end

  describe 'tunables' do
    it 'min_length raises the bar' do
      _(filter("#{SYMBOL_STREAM}\n", min_length: 10_000)).must_equal "#{SYMBOL_STREAM}\n"
      _(filter("#{SYMBOL_STREAM}\n", min_length: 10)).wont_include '+ = ·'
    end

    it 'max_entropy loosens or tightens the repetition bar' do
      # '=+-' repeated 20 times: 3 distinct chars over 60 → 0.05 entropy.
      line = ("=+-" * 20) + "\n"
      _(filter(line, max_entropy: 0.01)).must_equal line
      _(filter(line, max_entropy: 0.5)).wont_include '=+-'
    end
  end
end
