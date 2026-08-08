# frozen_string_literal: true

require_relative 'test_helper'

# Ported from crawl4ai's tests/test_content_filter_prune.py and
# tests/test_pruning_preserve_whitelist_1900.py (Apache-2.0), adapted to
# the Ruby ContentFilter and its deliberate weight additions.
describe Ask::WebFetch::ContentFilter do
  BASIC_HTML = <<~HTML
    <html>
      <body>
        <article>
          <h1>Main Article</h1>
          <p>This is a high-quality paragraph with substantial text content. It contains enough words to pass the threshold and has good text density without too many links. This kind of content should survive the pruning process.</p>
          <div class="sidebar">Low quality sidebar content</div>
          <div class="social-share">Share buttons</div>
        </article>
      </body>
    </html>
  HTML

  LINK_HEAVY_HTML = <<~HTML
    <html>
      <body>
        <div class="content">
          <p>Good content paragraph that should remain.</p>
          <div class="links">
            <a href="#">Link 1</a>
            <a href="#">Link 2</a>
            <a href="#">Link 3</a>
            <a href="#">Link 4</a>
          </div>
        </div>
      </body>
    </html>
  HTML

  MIXED_CONTENT_HTML = <<~HTML
    <html>
      <body>
        <article>
          <h1>Article Title</h1>
          <p class="summary">Short summary.</p>
          <div class="content">
            <p>Long high-quality paragraph with substantial content that should definitely survive the pruning process. This content has good text density and proper formatting which makes it valuable for retention.</p>
          </div>
          <div class="comments">
            <p>Short comment 1</p>
            <p>Short comment 2</p>
          </div>
        </article>
      </body>
    </html>
  HTML

  # From crawl4ai test #1900: a GitHub issue page with comments, nav, footer.
  GITHUB_COMMENT_HTML = <<~HTML
    <html><body>
    <article class="main-content">
      <h1>Discussion: Feature Request</h1>
      <p>This is a long paragraph about the feature request with enough words to
      pass the pruning threshold easily. The feature would add support for document
      extraction in the crawl pipeline, enabling binary documents like PDFs and
      DOCX files to be processed alongside HTML pages.</p>

      <div class="comment">
        <div class="comment-header">
          <span class="author"><a href="/user/alice">alice</a></span>
          <time>commented Apr 6, 2026</time>
        </div>
        <div class="comment-body">
          <p>I think this is a great idea. We should implement it using a
          pluggable strategy pattern so users can bring their own extraction
          backend. This would keep the core library lean while supporting
          many document types.</p>
        </div>
      </div>

      <div class="comment">
        <div class="comment-header">
          <span class="author"><a href="/user/bob">bob</a></span>
          <time>commented Apr 7, 2026</time>
        </div>
        <div class="comment-body">
          <p>Agreed with alice. The abstract base class approach makes sense.
          We could also add a built-in implementation for PDFs since crawl4ai
          already has PDFContentScrapingStrategy that could be wrapped.</p>
        </div>
      </div>
    </article>

    <nav class="site-nav">
      <a href="/">Home</a>
      <a href="/about">About</a>
    </nav>
    <footer class="site-footer">
      <p>Copyright 2026</p>
    </footer>
    </body></html>
  HTML

  ATTRIBUTION_HTML = <<~HTML
    <html><body>
    <div class="article">
      <p>Long article content that should definitely pass the threshold because it
      contains enough words and text density to score well in the pruning algorithm.
      This paragraph discusses the implementation details of the feature.</p>
      <div class="byline">By <strong>Jane Smith</strong></div>
      <div class="author-bio">Jane is a senior engineer at Example Corp.</div>
    </div>
    </body></html>
  HTML

  SIMPLE_HTML = <<~HTML
    <html><body>
    <div class="content">
      <p>Main content paragraph with enough text to pass pruning easily. This
      discusses important topics that should be preserved in the output.</p>
      <cite class="source">Source: Example Research Paper, 2026</cite>
    </div>
    </body></html>
  HTML

  def combined(filter, html)
    filter.filter_content(html).join(' ').downcase
  end

  describe 'pruning' do
    it 'keeps content and drops sidebar and share chrome' do
      contents = Ask::WebFetch::ContentFilter.new(min_word_threshold: 5)
                                             .filter_content(BASIC_HTML)
      text = contents.join(' ').downcase

      _(text).must_include 'high-quality paragraph'
      _(text).wont_include 'sidebar content'
      _(text).wont_include 'share buttons'
    end

    it 'respects min_word_threshold' do
      filter = Ask::WebFetch::ContentFilter.new(min_word_threshold: 10)
      text = combined(filter, MIXED_CONTENT_HTML)

      _(text).wont_include 'short summary'
      _(text).must_include 'long high-quality paragraph'
      _(text).wont_include 'short comment'
    end

    it 'prunes link-heavy sections' do
      filter = Ask::WebFetch::ContentFilter.new(threshold_type: :dynamic)
      contents = filter.filter_content(LINK_HEAVY_HTML)
      text = contents.join(' ').downcase

      _(text).must_include 'good content paragraph'
      _(contents.count { |c| c.include?('href') }).must_be :<, 2
    end

    it 'retains important tags' do
      filter = Ask::WebFetch::ContentFilter.new(threshold_type: :dynamic)
      contents = filter.filter_content(MIXED_CONTENT_HTML)

      _(contents.any? { |c| c.downcase.include?('article') }).must_equal true
    end

    it 'removes structural boilerplate before scoring' do
      filter = Ask::WebFetch::ContentFilter.new
      text = combined(filter, GITHUB_COMMENT_HTML)

      _(text).must_include 'feature request'
      _(text).wont_include 'site-nav'
      _(text).wont_include 'copyright 2026'
    end

    it 'handles empty input' do
      filter = Ask::WebFetch::ContentFilter.new

      _(filter.filter_content('')).must_equal []
      _(filter.filter_content(nil)).must_equal []
    end

    it 'handles malformed HTML without raising' do
      contents = Ask::WebFetch::ContentFilter.new.filter_content('<div>Unclosed div<p>Nested<span>content</div>')

      _(contents).must_be_kind_of Array
    end

    it 'removes comments' do
      html = "<html><body><!-- hidden --><div><p>#{'Real words here. ' * 10}</p></div></body></html>"

      _(Ask::WebFetch::ContentFilter.new.fit_html(html)).wont_include 'hidden'
    end

    it 'is consistent across runs' do
      filter = Ask::WebFetch::ContentFilter.new

      _(filter.filter_content(BASIC_HTML)).must_equal filter.filter_content(BASIC_HTML)
    end

    it 'keeps more content at a lenient threshold and less at a strict one' do
      # The link-farm block scores ~0.55: it survives a lenient bar and dies
      # under a strict one, while the real paragraph clears both.
      lenient = Ask::WebFetch::ContentFilter.new(threshold: 0.3)
      strict = Ask::WebFetch::ContentFilter.new(threshold: 0.7)

      _(combined(lenient, LINK_HEAVY_HTML)).must_include 'link 1'
      _(combined(strict, LINK_HEAVY_HTML)).wont_include 'link 1'
      _(combined(strict, LINK_HEAVY_HTML)).must_include 'good content paragraph'
    end

    it 'processes the fixtures quickly' do
      filter = Ask::WebFetch::ContentFilter.new
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      filter.filter_content(GITHUB_COMMENT_HTML)
      duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start

      _(duration).must_be :<, 0.5
    end
  end

  describe 'preserve whitelist' do
    it 'keeps whitelisted classes' do
      filter = Ask::WebFetch::ContentFilter.new(preserve_classes: ['author'])
      text = combined(filter, GITHUB_COMMENT_HTML)

      _(text).must_include 'alice'
      _(text).must_include 'bob'
    end

    it 'keeps byline when whitelisted' do
      filter = Ask::WebFetch::ContentFilter.new(preserve_classes: ['byline'])

      _(combined(filter, ATTRIBUTION_HTML)).must_include 'jane smith'
    end

    it 'keeps multiple whitelisted classes' do
      filter = Ask::WebFetch::ContentFilter.new(preserve_classes: %w[author comment-header byline])
      text = combined(filter, GITHUB_COMMENT_HTML)

      _(text).must_include 'alice'
      _(text).must_include 'bob'
    end

    it 'ignores whitelisted classes that are absent' do
      filter = Ask::WebFetch::ContentFilter.new(preserve_classes: ['nonexistent-class'])

      _(filter.filter_content(GITHUB_COMMENT_HTML).length).must_be :>, 0
    end

    it 'treats empty preserve lists as no whitelist' do
      filter = Ask::WebFetch::ContentFilter.new(preserve_classes: [], preserve_tags: [])

      _(filter.filter_content(BASIC_HTML).length).must_be :>, 0
    end

    it 'keeps whitelisted tags' do
      filter = Ask::WebFetch::ContentFilter.new(preserve_tags: ['cite'])

      _(combined(filter, SIMPLE_HTML)).must_include 'example research paper'
    end

    it 'keeps time tags when whitelisted' do
      filter = Ask::WebFetch::ContentFilter.new(preserve_tags: ['time'])

      _(combined(filter, GITHUB_COMMENT_HTML)).must_include 'apr 6, 2026'
    end

    it 'combines class and tag whitelists' do
      filter = Ask::WebFetch::ContentFilter.new(preserve_classes: ['author'], preserve_tags: ['time'])
      text = combined(filter, GITHUB_COMMENT_HTML)

      _(text).must_include 'alice'
      _(text).must_include 'apr 6, 2026'
    end

    it 'does not let the whitelist rescue excluded structural tags' do
      filter = Ask::WebFetch::ContentFilter.new(preserve_tags: ['nav'])
      text = combined(filter, GITHUB_COMMENT_HTML)

      _(text).wont_include 'site-nav'
    end
  end

  describe 'content-worthy tags (deviation from crawl4ai)' do
    it 'keeps a table of text cells' do
      html = <<~HTML
        <html><body>
        <table>
          <tr><th>Name</th><th>Amount</th></tr>
          <tr><td>Alice Smith</td><td>$1,000</td></tr>
          <tr><td>Bob Jones</td><td>$2,500</td></tr>
        </table>
        </body></html>
      HTML

      text = combined(Ask::WebFetch::ContentFilter.new, html)

      _(text).must_include 'alice smith'
      _(text).must_include '$2,500'
    end

    it 'keeps preformatted code blocks' do
      html = "<html><body><pre><code>def hello\n  puts 'hi'\nend</code></pre></body></html>"

      _(combined(Ask::WebFetch::ContentFilter.new, html)).must_include 'def hello'
    end

    it 'drops inline SVG chart text (deviation from crawl4ai)' do
      html = "<html><body><article>" \
             "<p>#{'Real words here. ' * 20}</p>" \
             '<svg><text>01M2M3M</text><text>10Apr15Apr</text><text>025K50K</text></svg>' \
             '</article></body></html>'
      text = combined(Ask::WebFetch::ContentFilter.new, html)

      _(text).must_include 'real words here'
      _(text).wont_include '01m2m3m'
      _(text).wont_include '10apr15apr'
      _(text).wont_include '025k50k'
    end
  end

  describe 'fit_html' do
    it 'wraps surviving blocks in divs' do
      html = "<html><body><nav><a href='/'>x</a></nav><div><p>#{'Keep me. ' * 20}</p></div></body></html>"
      fit = Ask::WebFetch::ContentFilter.new.fit_html(html)

      _(fit).must_match(%r{\A<div>.*</div>\z})
      _(fit).wont_include '<nav'
      _(fit).must_include 'Keep me.'
    end

    it 'returns empty string when nothing survives' do
      _(Ask::WebFetch::ContentFilter.new.fit_html('<html><body><nav>menu</nav></body></html>')).must_equal ''
    end
  end
end
