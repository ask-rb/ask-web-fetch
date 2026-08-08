# frozen_string_literal: true

require_relative 'test_helper'

describe Ask::WebFetch::Markdown do
  def generate(html, **kwargs)
    Ask::WebFetch::Markdown.generate(html, **kwargs)
  end

  describe 'generate' do
    it 'returns title, description, and markdown content' do
      html = '<html><head><title>Title</title>' \
             '<meta name="description" content="A page about things."></head>' \
             '<body><p>Hello world.</p></body></html>'

      page = generate(html)

      _(page[:title]).must_equal 'Title'
      _(page[:description]).must_equal 'A page about things.'
      _(page[:content]).must_include 'Hello world.'
    end

    it 'falls back to og:description' do
      html = '<html><head><meta property="og:description" content="Open graph."></head>' \
             '<body><p>Body text here.</p></body></html>'

      _(generate(html)[:description]).must_equal 'Open graph.'
    end

    it 'returns a nil title for a page without one' do
      page = generate('<html><body><p>Just some text.</p></body></html>')

      assert_nil page[:title]
    end

    it 'returns empty content for an empty document' do
      _(generate('')[:content]).must_equal ''
    end

    it 'converts links to markdown' do
      html = '<html><body><main>' \
             '<p>See <a href="https://example.com">example</a>.</p></main></body></html>'

      _(generate(html)[:content]).must_include '[example](https://example.com)'
    end

    it 'converts tables to markdown tables' do
      html = '<html><body><table><tr><td>Alpha</td><td>Beta</td></tr>' \
             '<tr><td>Gamma</td><td>Delta</td></tr></table></body></html>'

      _(generate(html)[:content]).must_match(%r{\|.*Alpha.*Beta.*\|})
    end

    it 'cleans stray blank lines' do
      html = "<html><body><p>One.</p>\n\n\n\n<p>Two.</p></body></html>"

      _(generate(html)[:content]).wont_match(/\n{3,}/)
    end
  end

  describe 'content region' do
    it 'prefers article over main and body' do
      doc = Nokogiri::HTML('<html><body><main><p>main</p></main>' \
                           '<article><p>article</p></article></body></html>')

      _(Ask::WebFetch::Markdown.cleaned_html(doc)).must_include 'article'
      _(Ask::WebFetch::Markdown.cleaned_html(doc)).wont_include '<main>'
    end

    it 'falls back to main, then body' do
      doc = Nokogiri::HTML('<html><body><main><p>hi</p></main></body></html>')
      _(Ask::WebFetch::Markdown.cleaned_html(doc)).must_include '<main>'

      doc2 = Nokogiri::HTML('<html><body><div><p>hi</p></div></body></html>')
      _(Ask::WebFetch::Markdown.cleaned_html(doc2)).must_include '<div>'
    end

    it 'scrubs scripts, nav, and nav-chrome elements' do
      html = <<~HTML
        <html><body>
          <main>
            <script>alert(1)</script>
            <nav><a href="/x">menu</a></nav>
            <div class="sidebar"><a href="/s">side</a></div>
            <p>Keep me.</p>
          </main>
        </body></html>
      HTML

      content = generate(html)[:content]

      _(content).wont_include 'alert'
      _(content).wont_include 'sidebar'
      _(content).wont_include 'menu'
      _(content).must_include 'Keep me.'
    end
  end

  describe 'filtering' do
    it 'prunes chrome when given a filter' do
      html = '<html><body><nav><a href="/">Home</a></nav>' \
             '<article><p>Real content here, enough words to clear the ' \
             'pruning bar comfortably without much trouble.</p></article>' \
             '<footer>Copyright</footer></body></html>'
      filter = Ask::WebFetch::ContentFilter.new

      content = generate(html, filter: filter)[:content]

      _(content).must_include 'Real content here'
      _(content).wont_include 'Home'
      _(content).wont_include 'Copyright'
    end

    it 'falls back to the content region when pruning empties the page' do
      # A filter that removes everything must not turn a real page into an
      # empty string — the article region is used instead.
      brutal = Ask::WebFetch::ContentFilter.new(threshold: 10)
      html = '<html><body><article><p>Content that even a brutal filter ' \
             'should not erase because we fall back.</p></article></body></html>'

      _(generate(html, filter: brutal)[:content]).must_include 'fall back'
    end
  end

  describe 'convert_links_to_citations' do
    # Ported from crawl4ai's links_citations fixture expectations.
    LINKS_MD = <<~MD
      # Document with Links
      First link to [Example 1](http://example.com/1)
      Second link to [Test 2](http://example.com/2 "Example 2")
      Image link: ![test image](test.jpg)
      Repeated link to [Example 1 again](http://example.com/1)
    MD

    it 'replaces links with numbered citations' do
      converted, = Ask::WebFetch::Markdown.convert_links_to_citations(LINKS_MD, 'http://example.com')

      _(converted).must_include 'Example 1⟨1⟩'
      _(converted).must_include 'Test 2⟨2⟩'
      _(converted).must_include '![test image⟨3⟩]'
    end

    it 'deduplicates repeated links to one citation number' do
      converted, = Ask::WebFetch::Markdown.convert_links_to_citations(LINKS_MD, 'http://example.com')

      _(converted).must_include 'Example 1 again⟨1⟩'
      _(converted.scan('⟨1⟩').length).must_equal 2
    end

    it 'builds a References section with titles and anchor text' do
      _, references = Ask::WebFetch::Markdown.convert_links_to_citations(LINKS_MD, 'http://example.com')

      _(references).must_include '## References'
      _(references).must_include '⟨1⟩ http://example.com/1: Example 1'
      _(references).must_include '⟨2⟩ http://example.com/2: Example 2 - Test 2'
    end

    it 'resolves root-absolute URLs against the site root' do
      converted, references = Ask::WebFetch::Markdown.convert_links_to_citations(
        'See [stats](/stats)', 'https://patronview.com/news/2026'
      )

      _(converted).must_include 'See stats⟨1⟩'
      _(references).must_include '⟨1⟩ https://patronview.com/stats'
    end

    it 'resolves relative URLs against the base directory' do
      _, references = Ask::WebFetch::Markdown.convert_links_to_citations(
        'See [stats](stats)', 'https://patronview.com/news/2026'
      )

      _(references).must_include '⟨1⟩ https://patronview.com/news/stats'
    end

    it 'leaves absolute, mailto, and protocol-relative URLs alone' do
      md = '[a](https://x.com) [b](mailto:x@y.com) [c](//cdn.example.com/x)'
      converted, references = Ask::WebFetch::Markdown.convert_links_to_citations(md, 'http://base.com')

      _(references).must_include 'https://x.com'
      _(references).must_include 'mailto:x@y.com'
      _(references).must_include '//cdn.example.com/x'
      assert converted
    end

    it 'returns the markdown untouched when it has no links' do
      converted, references = Ask::WebFetch::Markdown.convert_links_to_citations('Plain text, no links.')

      _(converted).must_equal 'Plain text, no links.'
      _(references).must_equal ''
    end
  end

  describe 'generate with citations' do
    it 'appends the References section' do
      html = '<html><body><p>See <a href="https://example.com">example</a>.</p></body></html>'

      content = generate(html, base_url: 'https://example.com', citations: true)[:content]

      _(content).must_include 'example⟨1⟩'
      _(content).must_include '## References'
      _(content).must_include '⟨1⟩ https://example.com'
    end

    it 'keeps inline links by default' do
      html = '<html><body><p>See <a href="https://example.com">example</a>.</p></body></html>'

      _(generate(html, base_url: 'https://example.com')[:content]).must_include '[example](https://example.com)'
    end
  end
end
