# frozen_string_literal: true

require_relative '../test_helper'

describe Ask::WebFetch::Backends::Local do
  before do
    @backend = Ask::WebFetch::Backends::Local.new
  end

  describe 'conversion' do
    it 'converts links to markdown' do
      html = '<html><head><title>Title</title></head><body><main>' \
             '<p>See <a href="https://example.com">example</a>.</p></main></body></html>'
      page = @backend.send(:to_markdown, html, 'https://example.com')

      _(page[:content]).must_include '[example](https://example.com)'
      _(page[:title]).must_equal 'Title'
    end

    it 'converts tables to markdown tables' do
      html = '<html><body><table><tr><td><a href="https://a.com">A</a></td></tr></table></body></html>'
      page = @backend.send(:to_markdown, html, 'https://example.com')

      _(page[:content]).must_match(%r{\|.*\[A\]\(https://a\.com\)})
    end

    it 'returns an empty title when the page has no title' do
      html = '<html><body><p>Just some text.</p></body></html>'
      page = @backend.send(:to_markdown, html, 'https://example.com')

      assert_nil page[:title]
      _(page[:content]).must_include 'Just some text.'
    end

    it 'returns empty content for an empty document' do
      page = @backend.send(:to_markdown, '', 'https://example.com')

      _(page[:content]).must_equal ''
    end
  end

  describe 'extraction' do
    it 'prefers article over main and body' do
      doc = Nokogiri::HTML(<<~HTML)
        <html><body>
          <main><p>main content</p></main>
          <article><p>article content</p></article>
        </body></html>
      HTML
      candidate = @backend.send(:extract_main, doc)

      _(candidate.name).must_equal 'article'
    end

    it 'falls back to main, then body' do
      doc = Nokogiri::HTML('<html><body><main><p>hi</p></main></body></html>')

      _(@backend.send(:extract_main, doc).name).must_equal 'main'

      doc2 = Nokogiri::HTML('<html><body><div><p>hi</p></div></body></html>')

      _(@backend.send(:extract_main, doc2).name).must_equal 'body'
    end

    it 'scrubs scripts, nav, and nav-chrome elements' do
      doc = Nokogiri::HTML(<<~HTML)
        <html><body>
          <main>
            <script>alert(1)</script>
            <nav><a href="/x">menu</a></nav>
            <div class="sidebar"><a href="/s">side</a></div>
            <p>Keep me.</p>
          </main>
        </body></html>
      HTML
      candidate = @backend.send(:extract_main, doc)
      @backend.send(:scrub, candidate)
      html = candidate.to_html

      _(html).wont_include 'alert'
      _(html).wont_include 'sidebar'
      _(html).wont_include '<nav>'
      _(html).must_include 'Keep me.'
    end
  end

  describe 'fetch' do
    before do
      WebMock.disable_net_connect!
    end

    after do
      WebMock.reset!
    end

    it 'raises EmptyContentError for a JS shell with no server-side content' do
      stub_request(:get, 'https://example.com')
        .to_return(status: 200, headers: { 'Content-Type' => 'text/html' },
                   body: '<html><body><div id="app"><script>render()</script></div></body></html>')

      _(-> { @backend.fetch('https://example.com') }).must_raise Ask::WebFetch::EmptyContentError
    end

    it 'raises EmptyContentError for content below the minimum length' do
      stub_request(:get, 'https://example.com')
        .to_return(status: 200, headers: { 'Content-Type' => 'text/html' },
                   body: '<html><body><p>tiny</p></body></html>')

      _(-> { @backend.fetch('https://example.com') }).must_raise Ask::WebFetch::EmptyContentError
    end

    it 'raises FetchError for a Cloudflare challenge page' do
      stub_request(:get, 'https://example.com')
        .to_return(status: 200, headers: { 'Content-Type' => 'text/html' },
                   body: '<html><head><title>Just a moment...</title></head>' \
                         '<body><p>Checking your browser</p></body></html>')

      _(-> { @backend.fetch('https://example.com') }).must_raise Ask::WebFetch::FetchError
    end

    it 'does not mistake embedded captcha config for a challenge page' do
      stub_request(:get, 'https://example.com')
        .to_return(status: 200, headers: { 'Content-Type' => 'text/html' },
                   body: '<html><head><title>Wiki</title>' \
                         '<script>window.mwConfig = {"wgConfirmEditCaptchaNeededForGenericEdit":"hcaptcha"}</script>' \
                         '</head><body><article>' \
                         "<p>#{'Real article content above the minimum threshold. ' * 5}</p>" \
                         '</article></body></html>')
      page = @backend.fetch('https://example.com')

      _(page[:title]).must_equal 'Wiki'
    end

    it 'raises FetchError for non-HTML content' do
      stub_request(:get, 'https://example.com')
        .to_return(status: 200, headers: { 'Content-Type' => 'application/pdf' }, body: '%PDF-1.4')

      _(-> { @backend.fetch('https://example.com') }).must_raise Ask::WebFetch::FetchError
    end

    it 'raises FetchError for HTTP errors' do
      stub_request(:get, 'https://example.com').to_return(status: 500, body: 'boom')

      _(-> { @backend.fetch('https://example.com') }).must_raise Ask::WebFetch::FetchError
    end

    it 'raises FetchError for redirect loops' do
      stub_request(:get, 'https://example.com')
        .to_return(status: 302, headers: { 'Location' => 'https://example.com' })

      _(-> { @backend.fetch('https://example.com') }).must_raise Ask::WebFetch::FetchError
    end

    it 'follows redirects' do
      stub_request(:get, 'https://example.com/start')
        .to_return(status: 302, headers: { 'Location' => 'https://example.com/final' })
      stub_request(:get, 'https://example.com/final')
        .to_return(status: 200, headers: { 'Content-Type' => 'text/html' },
                   body: '<html><head><title>Final</title></head><body>' \
                         '<p>Hello world here. This page has enough content to pass the minimum ' \
                         'threshold for usable text in the backend fetcher.</p></body></html>')
      page = @backend.fetch('https://example.com/start')

      _(page[:title]).must_equal 'Final'
    end

    it 'wraps network errors in FetchError' do
      stub_request(:get, 'https://example.com').to_raise(Errno::ECONNREFUSED.new)

      _(-> { @backend.fetch('https://example.com') }).must_raise Ask::WebFetch::FetchError
    end
  end
end
