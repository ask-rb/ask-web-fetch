# frozen_string_literal: true

require_relative 'test_helper'

describe Ask::Tools::WebFetch do
  before do
    @tool = Ask::Tools::WebFetch.new
  end

  it 'has the correct name' do
    _(@tool.name).must_equal 'web_fetch'
  end

  it 'has a description' do
    _(@tool.description).wont_be_nil
    _(@tool.description).wont_be :empty?
  end

  it 'has a url parameter' do
    schema = @tool.params_schema

    _(schema).wont_be_nil
    _(schema['required']).must_include 'url'
    _(schema.dig('properties', 'url', 'type')).must_equal 'string'
  end

  it 'has an optional max_chars parameter' do
    schema = @tool.params_schema

    _(schema.dig('properties', 'max_chars', 'type')).must_equal 'integer'
    _(schema['required']).wont_include 'max_chars'
  end

  it 'registers itself in the tool registry' do
    tool = Ask::Tools['web_fetch']

    _(tool).wont_be_nil
    _(tool).must_be_kind_of Ask::Tools::WebFetch
  end

  it 'defaults to Local then Jina when Crawl4AI and Browser are not configured' do
    Ask::Tools::WebFetch.backends = nil
    Ask::WebFetch::Backends::Crawl4Ai.url = nil
    Ask::WebFetch::Backends::Browser.path = ''

    _(Ask::WebFetch::Backends::Crawl4Ai.configured?).must_equal false
    _(Ask::WebFetch::Backends::Browser.configured?).must_equal false
    _(@tool.class.backends).must_equal [
      Ask::WebFetch::Backends::Local,
      Ask::WebFetch::Backends::Jina
    ]
  ensure
    Ask::WebFetch::Backends::Browser.path = nil
  end

  it 'leads with Crawl4AI when it is configured' do
    Ask::Tools::WebFetch.backends = nil
    Ask::WebFetch::Backends::Crawl4Ai.url = 'http://crawl4ai.test'
    Ask::WebFetch::Backends::Browser.path = ''

    _(@tool.class.backends).must_equal [
      Ask::WebFetch::Backends::Crawl4Ai,
      Ask::WebFetch::Backends::Local,
      Ask::WebFetch::Backends::Jina
    ]
  ensure
    Ask::WebFetch::Backends::Crawl4Ai.url = nil
    Ask::WebFetch::Backends::Browser.path = nil
    Ask::Tools::WebFetch.backends = nil
  end

  it 'appends Browser last when Chrome is available' do
    Ask::Tools::WebFetch.backends = nil
    Ask::WebFetch::Backends::Crawl4Ai.url = nil
    Ask::WebFetch::Backends::Browser.path = '/fake/chrome'

    _(@tool.class.backends).must_equal [
      Ask::WebFetch::Backends::Local,
      Ask::WebFetch::Backends::Jina,
      Ask::WebFetch::Backends::Browser
    ]
  ensure
    Ask::WebFetch::Backends::Browser.path = nil
    Ask::WebFetch::Backends::Crawl4Ai.url = nil
    Ask::Tools::WebFetch.backends = nil
  end

  describe 'format' do
    it 'prepends title and source' do
      page = { title: 'My Page', content: 'Body text.' }
      md = @tool.send(:format, page, 'https://example.com/page')

      _(md).must_match(/\A# My Page/)
      _(md).must_include 'Source: https://example.com/page'
    end

    it 'omits the title when absent' do
      md = @tool.send(:format, { title: nil, content: 'Body text.' }, 'https://example.com')

      _(md).must_match(%r{\ASource: https://example\.com})
    end
  end

  describe 'truncation' do
    it 'truncates long output with a marker' do
      md = 'x' * 5000
      result = @tool.send(:truncate, md, 100)

      _(result.length).must_be :<=, 130
      _(result).must_include '…(truncated)'
    end

    it 'leaves short output untouched' do
      md = 'short'

      _(@tool.send(:truncate, md, 100)).must_equal 'short'
    end
  end

  describe 'backend chain' do
    before do
      WebMock.disable_net_connect!
      Ask::Tools::WebFetch.backends = nil
      Ask::WebFetch::Backends::Browser.path = ''
      # Local's HTTP is the seam (see StubHttp in test_helper); Jina and
      # Crawl4AI still run over Net::HTTP, so they keep WebMock stubs.
      @original_local_http = Ask::WebFetch::Backends::Local.http
      @local_http = StubHttp.new { raise 'unexpected local request' }
      Ask::WebFetch::Backends::Local.http = @local_http
    end

    after do
      Ask::Tools::WebFetch.backends = nil
      Ask::WebFetch::Backends::Crawl4Ai.url = nil
      Ask::WebFetch::Backends::Browser.path = nil
      Ask::WebFetch::Backends::Local.http = @original_local_http
      WebMock.reset!
    end

    def stub_local(&handler)
      @local_http.handler = handler
    end

    it 'prefers crawl4ai when it is configured and succeeds' do
      Ask::Tools::WebFetch.backends = nil
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

      result = @tool.call('url' => 'https://example.com')

      _(result.ok?).must_equal true
      _(result.output).must_include '# Rendered Page'
      _(result.output).must_include 'Crawl4AI rendered markdown.'
      assert_not_requested :get, 'https://example.com'
    end

    it 'falls through to local when crawl4ai is configured but down' do
      Ask::WebFetch::Backends::Crawl4Ai.url = 'http://crawl4ai.test'
      stub_request(:post, 'http://crawl4ai.test/crawl').to_return(status: 503, body: 'down')
      body = '<html><head><title>Local Page</title></head><body><article>' \
             "<p>#{'Plenty of real content for the local backend. ' * 10}</p></article></body></html>"
      stub_local { |_, _| http_response(200, body) }

      result = @tool.call('url' => 'https://example.com')

      _(result.ok?).must_equal true
      _(result.output).must_include '# Local Page'
    end

    it 'uses local when it succeeds and never calls jina' do
      body = '<html><head><title>Local Page</title></head><body><article>' \
             "<p>#{'Plenty of real content for the local backend. ' * 10}</p></article></body></html>"
      stub_local { |_, _| http_response(200, body) }
      result = @tool.call('url' => 'https://example.com')

      _(result.ok?).must_equal true
      _(result.output).must_include '# Local Page'
      assert_not_requested :get, /r\.jina\.ai/
    end

    it 'falls back to jina when local finds no content (JS page)' do
      stub_local { |_, _| http_response(200, '<html><body><div id="app"><script>render()</script></div></body></html>') }
      stub_request(:get, 'https://r.jina.ai/https://example.com')
        .to_return(status: 200, body: 'Jina rendered this page with JavaScript content. ' * 5)
      result = @tool.call('url' => 'https://example.com')

      _(result.ok?).must_equal true
      _(result.output).must_include 'Jina rendered this page'
    end

    it 'falls back to jina when local gets an HTTP error' do
      stub_local { |_, _| http_response(403, 'forbidden') }
      stub_request(:get, 'https://r.jina.ai/https://example.com')
        .to_return(status: 200, body: 'Jina content here. ' * 10)
      result = @tool.call('url' => 'https://example.com')

      _(result.ok?).must_equal true
      _(result.output).must_include 'Jina content here'
    end

    it 'falls back to jina for non-HTML content' do
      stub_local { |_, _| http_response(200, '%PDF-1.4', content_type: 'application/pdf') }
      stub_request(:get, 'https://r.jina.ai/https://example.com')
        .to_return(status: 200, body: 'Jina parsed the PDF into markdown. ' * 10)
      result = @tool.call('url' => 'https://example.com')

      _(result.ok?).must_equal true
      _(result.output).must_include 'Jina parsed the PDF'
    end

    it 'fails when both backends fail and reports both errors' do
      stub_local { |_, _| http_response(500, 'boom') }
      stub_request(:get, 'https://r.jina.ai/https://example.com').to_return(status: 429, body: 'rate limited')
      result = @tool.call('url' => 'https://example.com')

      _(result.ok?).must_equal false
      _(result.error_message).must_match(/Local: got 500/)
      _(result.error_message).must_match(/Jina: rate limited/)
    end

    it 'supports a custom backend injected via backends=' do
      custom = Class.new(Ask::WebFetch::Backend) do
        def fetch(_url)
          { title: 'Custom', content: 'Custom backend content. ' * 10 }
        end
      end
      Ask::Tools::WebFetch.backends = [custom]
      result = @tool.call('url' => 'https://example.com')

      _(result.ok?).must_equal true
      _(result.output).must_include '# Custom'
      _(result.output).must_include 'Custom backend content.'
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
      result = @tool.call('url' => 'https://example.com')

      _(result).must_be_kind_of Ask::Result
      _(result.ok?).must_equal false
    end

    it 'handles timeout' do
      stub_local { raise Ask::WebFetch::TimeoutError, 'connect timed out' }
      result = @tool.call('url' => 'https://example.com')

      _(result).must_be_kind_of Ask::Result
      _(result.ok?).must_equal false
    end

    it 'handles HTTP error status' do
      stub_local { |_, _| http_response(500, 'error') }
      result = @tool.call('url' => 'https://example.com')

      _(result.ok?).must_equal false
    end

    it 'handles 404' do
      stub_local { |_, _| http_response(404, 'nope') }
      result = @tool.call('url' => 'https://example.com')

      _(result.ok?).must_equal false
    end

    it 'handles redirect loops' do
      stub_local { |_, _| http_response(302, '', location: 'https://example.com') }
      result = @tool.call('url' => 'https://example.com')

      _(result.ok?).must_equal false
    end
  end
end
