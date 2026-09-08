# frozen_string_literal: true

require_relative 'test_helper'

describe Ask::WebFetch do
  describe 'backends' do
    before do
      WebMock.disable_net_connect!
      Ask::WebFetch.backends = nil
      Ask::WebFetch::Backends::Browser.path = ''
      # Local's HTTP is the seam (see StubHttp in test_helper); Jina and
      # Crawl4AI still run over Net::HTTP, so they keep WebMock stubs.
      @original_local_http = Ask::WebFetch::Backends::Local.http
      @local_http = StubHttp.new { raise 'unexpected local request' }
      Ask::WebFetch::Backends::Local.http = @local_http
    end

    after do
      Ask::WebFetch.backends = nil
      Ask::WebFetch::Backends::Crawl4Ai.url = nil
      Ask::WebFetch::Backends::Browser.path = nil
      Ask::WebFetch::Backends::Local.http = @original_local_http
      WebMock.reset!
    end

    def stub_local(&handler)
      @local_http.handler = handler
    end

    it 'defaults to Local then Jina when Crawl4AI and Browser are not configured' do
      chain = Ask::WebFetch.backends

      _(chain).must_equal [Ask::WebFetch::Backends::Local, Ask::WebFetch::Backends::Jina]
    end

    it 'leads with Crawl4AI when it is configured' do
      Ask::WebFetch::Backends::Crawl4Ai.url = 'http://crawl4ai.test'
      chain = Ask::WebFetch.backends

      _(chain.first).must_equal Ask::WebFetch::Backends::Crawl4Ai
      _(chain).must_include Ask::WebFetch::Backends::Local
    end

    it 'appends Browser last when Chrome is available' do
      Ask::WebFetch::Backends::Browser.path = '/usr/bin/chromium'
      chain = Ask::WebFetch.backends

      _(chain.last).must_equal Ask::WebFetch::Backends::Browser
    end

    it 'prefers crawl4ai when it is configured and succeeds' do
      Ask::WebFetch::Backends::Crawl4Ai.url = 'http://crawl4ai.test'
      crawl_body = {
        success: true,
        results: [
          {
            url: 'https://example.com',
            success: true,
            markdown: { fit_markdown: 'Crawl4AI rendered markdown. ' * 10, raw_markdown: '' },
            metadata: { title: 'Rendered Page' }
          }
        ]
      }.to_json
      stub_request(:post, 'http://crawl4ai.test/crawl').to_return(status: 200, body: crawl_body)

      markdown = Ask::WebFetch.fetch('https://example.com')

      _(markdown).must_include '# Rendered Page'
      _(markdown).must_include 'Crawl4AI rendered markdown.'
      assert_not_requested :get, 'https://example.com'
    end

    it 'falls through to local when crawl4ai is configured but down' do
      Ask::WebFetch::Backends::Crawl4Ai.url = 'http://crawl4ai.test'
      stub_request(:post, 'http://crawl4ai.test/crawl').to_return(status: 503, body: 'down')
      body = '<html><head><title>Local Page</title></head><body><article>' \
             "<p>#{'Plenty of real content for the local backend. ' * 10}</p></article></body></html>"
      stub_local { |_, _| http_response(200, body) }

      markdown = Ask::WebFetch.fetch('https://example.com')

      _(markdown).must_include '# Local Page'
    end

    it 'uses local when it succeeds and never calls jina' do
      body = '<html><head><title>Local Page</title></head><body><article>' \
             "<p>#{'Plenty of real content for the local backend. ' * 10}</p></article></body></html>"
      stub_local { |_, _| http_response(200, body) }
      markdown = Ask::WebFetch.fetch('https://example.com')

      _(markdown).must_include '# Local Page'
      assert_not_requested :get, /r\.jina\.ai/
    end

    it 'falls back to jina when local finds no content (JS page)' do
      stub_local { |_, _| http_response(200, '<html><body><div id="app"><script>render()</script></div></body></html>') }
      stub_request(:get, 'https://r.jina.ai/https://example.com')
        .to_return(status: 200, body: 'Jina rendered this page with JavaScript content. ' * 5)
      markdown = Ask::WebFetch.fetch('https://example.com')

      _(markdown).must_include 'Jina rendered this page'
    end

    it 'falls back to jina when local gets an HTTP error' do
      stub_local { |_, _| http_response(403, 'forbidden') }
      stub_request(:get, 'https://r.jina.ai/https://example.com')
        .to_return(status: 200, body: 'Jina content here. ' * 10)
      markdown = Ask::WebFetch.fetch('https://example.com')

      _(markdown).must_include 'Jina content here'
    end

    it 'falls back to jina for non-HTML content' do
      stub_local { |_, _| http_response(200, '%PDF-1.4', content_type: 'application/pdf') }
      stub_request(:get, 'https://r.jina.ai/https://example.com')
        .to_return(status: 200, body: 'Jina parsed the PDF into markdown. ' * 10)
      markdown = Ask::WebFetch.fetch('https://example.com')

      _(markdown).must_include 'Jina parsed the PDF'
    end

    it 'raises with every backend failure in the message' do
      stub_local { |_, _| http_response(500, 'boom') }
      stub_request(:get, 'https://r.jina.ai/https://example.com').to_return(status: 429, body: 'rate limited')
      error = assert_raises(Ask::WebFetch::Error) { Ask::WebFetch.fetch('https://example.com') }

      _(error.message).must_match(/Local: got 500/)
      _(error.message).must_match(/Jina: \[429\]/)
    end

    it 'supports a custom backend injected via backends=' do
      custom = Class.new(Ask::WebFetch::Backend) do
        def fetch(_url)
          { title: 'Custom', content: 'Custom backend content. ' * 10 }
        end
      end
      Ask::WebFetch.backends = [custom]
      markdown = Ask::WebFetch.fetch('https://example.com')

      _(markdown).must_include '# Custom'
      _(markdown).must_include 'Custom backend content.'
    end

    it 'prepends the title and source to the markdown' do
      body = '<html><head><title>Fancy Page</title></head><body><article>' \
             "<p>#{'Body text that is plenty long. ' * 10}</p></article></body></html>"
      stub_local { |_, _| http_response(200, body) }

      markdown = Ask::WebFetch.fetch('https://example.com')

      _(markdown).must_match(/\A# Fancy Page\n\nSource: https:\/\/example\.com\n\n/)
    end

    it 'truncates long output with a marker' do
      body = "<html><body><article><p>#{'a' * 100}</p></article></body></html>"
      stub_local { |_, _| http_response(200, body) }

      markdown = Ask::WebFetch.fetch('https://example.com', max_chars: 50)

      _(markdown.length).must_be :<=, 50 + '…(truncated)'.length + 2
      _(markdown).must_include '…(truncated)'
    end
  end

  describe 'connection and HTTP errors (all backends fail)' do
    before do
      WebMock.disable_net_connect!
      Ask::WebFetch::Backends::Browser.path = ''
      stub_request(:get, /r\.jina\.ai/).to_return(status: 500, body: 'jina down')
      @original_local_http = Ask::WebFetch::Backends::Local.http
      @local_http = StubHttp.new { raise 'unexpected local request' }
      Ask::WebFetch::Backends::Local.http = @local_http
    end

    after do
      Ask::WebFetch::Backends::Browser.path = nil
      Ask::WebFetch::Backends::Local.http = @original_local_http
      WebMock.reset!
    end

    def stub_local(&handler)
      @local_http.handler = handler
    end

    it 'handles connection refused' do
      stub_local { raise Errno::ECONNREFUSED }

      _(-> { Ask::WebFetch.fetch('https://example.com') }).must_raise Ask::WebFetch::Error
    end

    it 'handles timeout' do
      stub_local { raise Ask::WebFetch::TimeoutError, 'connect timed out' }

      _(-> { Ask::WebFetch.fetch('https://example.com') }).must_raise Ask::WebFetch::Error
    end

    it 'handles HTTP error status' do
      stub_local { |_, _| http_response(500, 'error') }

      _(-> { Ask::WebFetch.fetch('https://example.com') }).must_raise Ask::WebFetch::Error
    end

    it 'handles 404' do
      stub_local { |_, _| http_response(404, 'nope') }

      _(-> { Ask::WebFetch.fetch('https://example.com') }).must_raise Ask::WebFetch::Error
    end

    it 'handles redirect loops' do
      stub_local { |_, _| http_response(302, '', location: 'https://example.com') }

      _(-> { Ask::WebFetch.fetch('https://example.com') }).must_raise Ask::WebFetch::Error
    end
  end

  describe 'deterministic failure collapse' do
    before do
      WebMock.disable_net_connect!
      Ask::WebFetch.backends = nil
      Ask::WebFetch::Backends::Browser.path = ''
      @original_local_http = Ask::WebFetch::Backends::Local.http
      @local_http = StubHttp.new { raise 'unexpected local request' }
      Ask::WebFetch::Backends::Local.http = @local_http
    end

    after do
      Ask::WebFetch.backends = nil
      Ask::WebFetch::Backends::Crawl4Ai.url = nil
      Ask::WebFetch::Backends::Browser.path = nil
      Ask::WebFetch::Backends::Local.http = @original_local_http
      WebMock.reset!
    end

    def stub_local(&handler)
      @local_http.handler = handler
    end

    def stub_jina(status:, body: '')
      stub_request(:get, /r\.jina\.ai/).to_return(status: status, body: body)
    end

    # A registrar parking page (GoDaddy marker) — Local rejects it with
    # ParkedDomainError (0.5.7+), the deterministic terminal verdict.
    def stub_parked_local
      stub_local do |_, _|
        http_response(200, '<html><body>example.com is parked free, courtesy of GoDaddy.com</body></html>')
      end
    end

    it 'a parked domain keeps its class through the aggregate' do
      stub_parked_local
      stub_jina(status: 200)

      error = assert_raises(Ask::WebFetch::ParkedDomainError) { Ask::WebFetch.fetch('https://example.com') }

      _(error.message).must_match(/parked domain/)
    end

    it 'a parked verdict beats a dead 4xx' do
      stub_parked_local
      stub_jina(status: 404, body: 'nope')

      _(-> { Ask::WebFetch.fetch('https://example.com') })
        .must_raise Ask::WebFetch::ParkedDomainError
    end

    it 'an empty verdict beats a dead 4xx (the page existed, it had no content)' do
      stub_local { |_, _| http_response(404, 'nope') }
      stub_jina(status: 200)

      _(-> { Ask::WebFetch.fetch('https://example.com') })
        .must_raise Ask::WebFetch::EmptyContentError
    end

    it 'every backend deterministic collapses to FetchError' do
      stub_local { |_, _| http_response(404, 'nope') }
      stub_jina(status: 404, body: 'nope')

      _(-> { Ask::WebFetch.fetch('https://example.com') })
        .must_raise Ask::WebFetch::FetchError
    end

    it 'any transient failure keeps the retryable base Error' do
      stub_local { raise Ask::WebFetch::TimeoutError, 'connect timed out' }
      stub_jina(status: 404, body: 'nope')

      error = assert_raises(Ask::WebFetch::Error) { Ask::WebFetch.fetch('https://example.com') }

      _(error.message).wont_match(/FetchError|EmptyContentError|ParkedDomainError/)
    end

    it 'reports every backend in the aggregate message' do
      stub_local { |_, _| http_response(404, 'nope') }
      stub_jina(status: 404, body: 'nope')

      error = assert_raises(Ask::WebFetch::Error) { Ask::WebFetch.fetch('https://example.com') }

      # When all backends report the same HTTP status, the message is concise
      _(error.message).must_include('[404]')
      _(error.message).must_include('https://example.com')
    end

    it 'lists each backend when they disagree on the error' do
      stub_local { |_, _| http_response(500, 'boom') }
      stub_jina(status: 404, body: 'nope')

      error = assert_raises(Ask::WebFetch::Error) { Ask::WebFetch.fetch('https://example.com') }

      _(error.message).must_match(/Local: got 500/)
      _(error.message).must_match(/Jina: \[404\]/)
    end
  end
end
