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

    it 'extracts declared license signals from the page' do
      html = <<~HTML
        <html><head>
          <link rel="license" href="https://creativecommons.org/licenses/by/4.0/">
          <meta name="dc.rights" content="Copyright 2025 Acme">
        </head><body><main><p>Some content.</p></main></body></html>
      HTML
      page = @backend.send(:to_markdown, html, 'https://example.com')

      _(page[:licenses]).must_include 'https://creativecommons.org/licenses/by/4.0/'
      _(page[:licenses]).must_include 'Copyright 2025 Acme'
    end

    it 'returns an empty license list when the page declares nothing' do
      html = '<html><body><p>Just some text.</p></body></html>'
      page = @backend.send(:to_markdown, html, 'https://example.com')

      _(page[:licenses]).must_equal []
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

    it 'strips decorative symbol noise from the converted page' do
      stream = '+ = · ( ~ @ · # % · & * ? · / : ; · [ ] · { · } | · ^ $ · ! · ' * 8
      html = '<html><body><main><p>Real content here, with words.</p>' \
             "<div class=\"bg-deco\">#{stream}</div></main></body></html>"
      page = @backend.send(:to_markdown, html, 'https://example.com')

      _(page[:content]).must_include 'Real content here'
      _(page[:content]).wont_include '+ = ·'
    end
  end

  describe 'fetch' do
    before do
      @original_http = Ask::WebFetch::Backends::Local.http
      # One-hop HTTP stub: the backend sees the same seam production wires
      # to the pooled httpx transport (Ask::WebFetch::Http), but the test
      # supplies each hop's answer. Redirects are still the backend's job,
      # so the stub branches on URL like a real server would.
      @http = StubHttp.new { raise 'no response stubbed' }
      Ask::WebFetch::Backends::Local.http = @http
    end

    after do
      Ask::WebFetch::Backends::Local.http = @original_http
    end

    def stub_http(&handler)
      @http.handler = handler
    end

    it 'raises EmptyContentError for a JS shell with no server-side content' do
      stub_http { |_, _| http_response(200, '<html><body><div id="app"><script>render()</script></div></body></html>') }

      _(-> { @backend.fetch('https://example.com') }).must_raise Ask::WebFetch::EmptyContentError
    end

    it 'raises EmptyContentError for content below the minimum length' do
      stub_http { |_, _| http_response(200, '<html><body><p>tiny</p></body></html>') }

      _(-> { @backend.fetch('https://example.com') }).must_raise Ask::WebFetch::EmptyContentError
    end

    it 'raises FetchError for a Cloudflare challenge page' do
      stub_http do |_, _|
        http_response(200, '<html><head><title>Just a moment...</title></head>' \
                      '<body><p>Checking your browser</p></body></html>')
      end

      _(-> { @backend.fetch('https://example.com') }).must_raise Ask::WebFetch::FetchError
    end

    it 'does not mistake embedded captcha config for a challenge page' do
      stub_http do |_, _|
        http_response(200, '<html><head><title>Wiki</title>' \
                      '<script>window.mwConfig = {"wgConfirmEditCaptchaNeededForGenericEdit":"hcaptcha"}</script>' \
                      '</head><body><article>' \
                      "<p>#{'Real article content above the minimum threshold. ' * 5}</p>" \
                      '</article></body></html>')
      end
      page = @backend.fetch('https://example.com')

      _(page[:title]).must_equal 'Wiki'
    end

    it 'raises FetchError for non-HTML content' do
      stub_http { |_, _| http_response(200, '%PDF-1.4', content_type: 'application/pdf') }

      _(-> { @backend.fetch('https://example.com') }).must_raise Ask::WebFetch::FetchError
    end

    it 'exposes the redirect chain it followed' do
      stub_http do |url, _|
        case url
        when 'https://example.com/old' then http_response(301, '', location: 'https://example.com/new')
        when 'https://example.com/new'
          http_response(200, 'Moved, with enough content here to clear the minimum usable threshold. ' \
                        'This sentence is repeated to make the page comfortably longer than the threshold.')
        end
      end

      page = @backend.fetch('https://example.com/old')

      _(page[:redirected]).must_equal(status: 301, url: 'https://example.com/new')
    end

    it 'returns no redirect info when the URL answered directly' do
      stub_http do |_, _|
        http_response(200, 'Content here, with enough words to clear the minimum usable threshold ' \
                      'comfortably. This sentence makes the page safely longer than the threshold.')
      end

      page = @backend.fetch('https://example.com')

      assert_nil page[:redirected]
    end

    it 'raises ServerError for HTTP 5xx errors' do
      stub_http { |_, _| http_response(500, 'boom') }

      _(-> { @backend.fetch('https://example.com') }).must_raise Ask::WebFetch::ServerError
    end

    it 'raises FetchError for redirect loops' do
      stub_http { |_, _| http_response(302, '', location: 'https://example.com') }

      _(-> { @backend.fetch('https://example.com') }).must_raise Ask::WebFetch::FetchError
    end

    it 'follows redirects' do
      stub_http do |url, _|
        case url
        when 'https://example.com/start' then http_response(302, '', location: 'https://example.com/final')
        when 'https://example.com/final'
          http_response(200, '<html><head><title>Final</title></head><body>' \
                        '<p>Hello world here. This page has enough content to pass the minimum ' \
                        'threshold for usable text in the backend fetcher.</p></body></html>')
        end
      end

      page = @backend.fetch('https://example.com/start')

      _(page[:title]).must_equal 'Final'
    end

    it 'wraps network errors in TimeoutError' do
      stub_http { raise Errno::ECONNREFUSED }

      _(-> { @backend.fetch('https://example.com') }).must_raise Ask::WebFetch::TimeoutError
    end

    it 'wraps transport timeouts in TimeoutError' do
      stub_http { raise Ask::WebFetch::TimeoutError, 'connect timed out' }

      _(-> { @backend.fetch('https://example.com') }).must_raise Ask::WebFetch::TimeoutError
    end

    it 'raises FetchError for a dead URL (404)' do
      stub_http { |_, _| http_response(404, 'nope') }

      err = _(-> { @backend.fetch('https://example.com/missing') }).must_raise Ask::WebFetch::FetchError
      _(err.message).must_include 'got 404 from'
    end

    it 'raises ServerError for a 429 or 5xx' do
      stub_http { |_, _| http_response(503, 'busy') }

      _(-> { @backend.fetch('https://example.com') }).must_raise Ask::WebFetch::ServerError

      stub_http { |_, _| http_response(429, 'slow down') }
      _(-> { @backend.fetch('https://example.com') }).must_raise Ask::WebFetch::ServerError
    end
  end
end
