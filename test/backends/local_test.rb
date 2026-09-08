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

    it 'fails through when a JS-app shell renders only part of the page' do
      # The reddit case: server HTML is a client-rendered app shell with
      # SOME content (above the 40-char minimum, below the shell
      # threshold) — a truncated page that would pass as success. It must
      # signal the chain to prefer a rendering backend instead.
      stub_http do |_, _|
        http_response(200, '<html><body><div id="root"><p>First wave of posts only, before the client-side render fills in the rest of the feed with lazy-loaded content.</p></div>' \
                      '<script src="/app.js"></script></body></html>')
      end

      err = _(-> { @backend.fetch('https://example.com') }).must_raise Ask::WebFetch::EmptyContentError
      _(err.message).must_include 'JS-app shell'
    end

    it 'fails through on a large HTML page with almost no server-rendered text' do
      # The airbnb case: no framework marker, but 100KB of server HTML
      # yielding a few lines of visible text — a shell by size ratio.
      shell = '<html><body>' + ('<div class="tracking"><script>window.data=[];</script></div>' * 400) +
              '<p>Search results with a couple of visible lines that pass the minimum content check.</p>' \
              '<div id="results"></div></body></html>'
      _(shell.bytesize).must_be :>, Ask::WebFetch::Backends::Local::SHELL_HTML_BYTES
      stub_http { |_, _| http_response(200, shell) }

      err = _(-> { @backend.fetch('https://example.com') }).must_raise Ask::WebFetch::EmptyContentError
      _(err.message).must_include 'JS-app shell'
    end

    it 'fails through on a GoDaddy parked-domain page' do
      # A parked domain is an ad for buying the domain, not site content —
      # a content company must never store it as the site.
      stub_http do |_, _|
        http_response(200, '<html><head><title>ayur.ai</title></head><body>' \
                      '<p>ayur.ai is parked free, courtesy of GoDaddy.com.</p>' \
                      '<a href="https://www.godaddy.com">Get This Domain</a></body></html>')
      end

      err = _(-> { @backend.fetch('https://ayur.ai') }).must_raise Ask::WebFetch::ParkedDomainError
      _(err.message).must_include 'parked domain'
    end

    it 'accepts a real page that mentions domains' do
      # Generic mentions of domains/parking on a real page must not trip
      # the registrar-specific detector.
      stub_http { |_, _| http_response(200, '<html><body><p>We help you find the right domain for your business and manage your DNS settings.</p></body></html>') }

      page = @backend.fetch('https://example.com')

      _(page[:content]).must_include 'find the right domain'
    end

    it 'accepts a JS-app page that is fully server-rendered' do
      # A Next.js-style page whose server HTML carries the real content
      # (above the shell threshold) is complete — no rendering backend
      # needed, Local's output is the page.
      long = '<html><body><div id="__next">' + ('<p>Full article paragraph with substantial real content that the server rendered ahead of time.</p>' * 120) + '</div></body></html>'
      stub_http { |_, _| http_response(200, long) }

      page = @backend.fetch('https://example.com')

      _(page[:content]).must_include 'Full article paragraph'
    end

    it 'accepts a short page that is not a JS app' do
      stub_http { |_, _| http_response(200, '<html><body><p>A short but complete status page with enough detail to be usable content for a reader.</p></body></html>') }

      page = @backend.fetch('https://example.com')

      _(page[:content]).must_include 'short but complete'
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

    describe 'agent-native content negotiation' do
      it 'returns server-provided markdown when Accept: text/markdown is honored' do
        stub_http do |url, headers|
          if headers['accept']&.include?('text/markdown')
            http_response(200, "# Direct markdown\n\nServer speaks markdown natively.",
                          content_type: 'text/markdown; charset=utf-8')
          else
            http_response(200, '<html><head><title>should not be used</title></head><body><p>fallback</p></body></html>')
          end
        end

        page = @backend.fetch('https://example.com')

        _(page[:content]).must_include 'Direct markdown'
        _(page[:content]).must_include 'Server speaks markdown natively'
      end

      it 'falls through to HTML scrape when server returns text/html for Accept: text/markdown' do
        stub_http do |url, headers|
          if headers['accept']&.include?('text/markdown')
            http_response(200, '<html><head><title>ignored</title></head><body>nope</body></html>',
                          content_type: 'text/html; charset=utf-8')
          else
            http_response(200, '<html><head><title>Real Title</title></head><body>' \
                          "<p>#{'Real article content above the minimum threshold. ' * 5}</p></body></html>")
          end
        end

        page = @backend.fetch('https://example.com')

        _(page[:title]).must_equal 'Real Title'
        _(page[:content]).must_include 'Real article content'
      end

      it 'follows a Mintlify-style 307 redirect to .md twin' do
        stub_http do |url, headers|
          if headers['accept']&.include?('text/markdown')
            if url == 'https://example.com/guide'
              http_response(307, '', location: 'https://example.com/guide.md',
                            content_type: 'text/plain')
            elsif url == 'https://example.com/guide.md'
              http_response(200, "# Guide\n\nThis is the full markdown content of the guide page, provided by the server as clean markdown for agent consumption.",
                            content_type: 'text/markdown; charset=utf-8')
            else
              http_response(200, '', content_type: 'text/html')
            end
          else
            http_response(200, '<html><head><title>HTML fallback</title></head><body>' \
                          "<p>#{'Real content for the HTML fallback path. ' * 5}</p></body></html>")
          end
        end

        page = @backend.fetch('https://example.com/guide')

        _(page[:content]).must_include 'Guide'
        _(page[:content]).must_include 'full markdown content of the guide page'
        _(page[:redirected]).must_equal(status: 307, url: 'https://example.com/guide.md')
      end

      it 'does not treat text/plain as agent-native markdown' do
        stub_http do |url, headers|
          if headers['accept']&.include?('text/markdown')
            http_response(200, 'some plain text', content_type: 'text/plain; charset=utf-8')
          else
            http_response(200, '<html><head><title>HTML</title></head><body>' \
                          "<p>#{'Real article content above the minimum threshold. ' * 5}</p></body></html>")
          end
        end

        page = @backend.fetch('https://example.com')

        _(page[:title]).must_equal 'HTML'
        _(page[:content]).must_include 'Real article content'
      end

      it 'does not treat application/pdf as agent-native' do
        stub_http do |url, headers|
          if headers['accept']&.include?('text/markdown')
            http_response(200, '%PDF-1.4 binary garbage', content_type: 'application/pdf')
          else
            http_response(200, '<html><head><title>PDF Page</title></head><body>' \
                          "<p>#{'Real article content above the minimum threshold. ' * 5}</p></body></html>")
          end
        end

        page = @backend.fetch('https://example.com')

        _(page[:title]).must_equal 'PDF Page'
        _(page[:content]).must_include 'Real article content'
      end
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

    it 'raises NotFoundError for a dead URL (404)' do
      stub_http { |_, _| http_response(404, 'nope') }

      err = _(-> { @backend.fetch('https://example.com/missing') }).must_raise Ask::WebFetch::NotFoundError
      _(err.message).must_include '[404]'
    end

    it 'raises ServerError for a 429 or 5xx' do
      stub_http { |_, _| http_response(503, 'busy') }

      _(-> { @backend.fetch('https://example.com') }).must_raise Ask::WebFetch::ServerError

      stub_http { |_, _| http_response(429, 'slow down') }
      _(-> { @backend.fetch('https://example.com') }).must_raise Ask::WebFetch::ServerError
    end
  end
end
