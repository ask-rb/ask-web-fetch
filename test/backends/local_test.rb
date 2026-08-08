# frozen_string_literal: true

require_relative '../test_helper'

describe Ask::WebFetch::Backends::Local do
  before do
    @backend = Ask::WebFetch::Backends::Local.new
  end

  after do
    Ask::WebFetch::Backends::Local.content_filter = nil
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
      html = '<html><body><table><tr><td>Alpha</td><td>Beta</td></tr>' \
             '<tr><td>Gamma</td><td>Delta</td></tr></table></body></html>'
      page = @backend.send(:to_markdown, html, 'https://example.com')

      _(page[:content]).must_match(%r{\|.*Alpha.*Beta.*\|})
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

    it 'prunes nav, footer, and link-farm sidebar chrome by default' do
      html = <<~HTML
        <html><body>
          <nav><a href="/">Home</a></nav>
          <article><p>Real article content that should survive the default
          pruning filter without any trouble at all.</p></article>
          <div class="sidebar">
            <a href="/p1">Popular post one</a>
            <a href="/p2">Popular post two</a>
            <a href="/p3">Popular post three</a>
          </div>
          <footer>Copyright</footer>
        </body></html>
      HTML
      page = @backend.send(:to_markdown, html, 'https://example.com')

      _(page[:content]).must_include 'Real article content'
      _(page[:content]).wont_include 'Popular post'
      _(page[:content]).wont_include 'Copyright'
      _(page[:content]).wont_include '[Home](https://example.com/)'
    end

    it 'converts the whole region when pruning is disabled' do
      Ask::WebFetch::Backends::Local.content_filter = nil
      html = '<html><body><article><p>Content.</p></article></body></html>'
      page = @backend.send(:to_markdown, html, 'https://example.com')

      _(page[:content]).must_include 'Content.'
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

    it 'exposes the redirect chain it followed' do
      stub_request(:get, 'https://example.com/old')
        .to_return(status: 301, headers: {'Location' => 'https://example.com/new'}, body: '')
      stub_request(:get, 'https://example.com/new')
        .to_return(status: 200, headers: {'Content-Type' => 'text/html'}, body: '<html><body><main>Moved, with enough content here to clear the minimum usable threshold. This sentence is repeated to make the page comfortably longer than the threshold.</main></body></html>')

      page = @backend.fetch('https://example.com/old')

      _(page[:redirected]).must_equal(status: 301, url: 'https://example.com/new')
    end

    it 'returns no redirect info when the URL answered directly' do
      stub_request(:get, 'https://example.com')
        .to_return(status: 200, headers: {'Content-Type' => 'text/html'}, body: '<html><body><main>Content here, with enough words to clear the minimum usable threshold comfortably. This sentence makes the page safely longer than the threshold.</main></body></html>')

      page = @backend.fetch('https://example.com')

      assert_nil page[:redirected]
    end

    it 'raises ServerError for HTTP 5xx errors' do
      stub_request(:get, 'https://example.com').to_return(status: 500, body: 'boom')

      _(-> { @backend.fetch('https://example.com') }).must_raise Ask::WebFetch::ServerError
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

    it 'wraps network errors in TimeoutError' do
      stub_request(:get, 'https://example.com').to_raise(Errno::ECONNREFUSED.new)

      _(-> { @backend.fetch('https://example.com') }).must_raise Ask::WebFetch::TimeoutError
    end

    it 'wraps timeouts in TimeoutError' do
      stub_request(:get, 'https://example.com').to_timeout

      _(-> { @backend.fetch('https://example.com') }).must_raise Ask::WebFetch::TimeoutError
    end

    it 'raises FetchError for a dead URL (404)' do
      stub_request(:get, 'https://example.com/missing').to_return(status: 404, body: 'nope')

      err = _(-> { @backend.fetch('https://example.com/missing') }).must_raise Ask::WebFetch::FetchError
      _(err.message).must_include 'got 404 from'
    end

    it 'raises ServerError for a 429 or 5xx' do
      stub_request(:get, 'https://example.com').to_return(status: 503, body: 'busy')

      _(-> { @backend.fetch('https://example.com') }).must_raise Ask::WebFetch::ServerError

      stub_request(:get, 'https://example.com').to_return(status: 429, body: 'slow down')
      _(-> { @backend.fetch('https://example.com') }).must_raise Ask::WebFetch::ServerError
    end
  end
end
