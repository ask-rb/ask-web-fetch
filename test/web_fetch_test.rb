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

  it 'defaults to Local then Jina when Crawl4AI is not configured' do
    Ask::Tools::WebFetch.backends = nil
    Ask::WebFetch::Backends::Crawl4Ai.url = nil

    _(Ask::WebFetch::Backends::Crawl4Ai.configured?).must_equal false
    _(@tool.class.backends).must_equal [
      Ask::WebFetch::Backends::Local,
      Ask::WebFetch::Backends::Jina
    ]
  end

  it 'leads with Crawl4AI when it is configured' do
    Ask::Tools::WebFetch.backends = nil
    Ask::WebFetch::Backends::Crawl4Ai.url = 'http://crawl4ai.test'

    _(@tool.class.backends).must_equal [
      Ask::WebFetch::Backends::Crawl4Ai,
      Ask::WebFetch::Backends::Local,
      Ask::WebFetch::Backends::Jina
    ]
  ensure
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
    end

    after do
      Ask::Tools::WebFetch.backends = nil
      Ask::WebFetch::Backends::Crawl4Ai.url = nil
      WebMock.reset!
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
      stub_request(:get, 'https://example.com')
        .to_return(status: 200, headers: { 'Content-Type' => 'text/html' }, body: body)

      result = @tool.call('url' => 'https://example.com')

      _(result.ok?).must_equal true
      _(result.output).must_include '# Local Page'
    end

    it 'uses local when it succeeds and never calls jina' do
      body = '<html><head><title>Local Page</title></head><body><article>' \
             "<p>#{'Plenty of real content for the local backend. ' * 10}</p></article></body></html>"
      stub_request(:get, 'https://example.com')
        .to_return(status: 200, headers: { 'Content-Type' => 'text/html' }, body: body)
      result = @tool.call('url' => 'https://example.com')

      _(result.ok?).must_equal true
      _(result.output).must_include '# Local Page'
      assert_not_requested :get, /r\.jina\.ai/
    end

    it 'falls back to jina when local finds no content (JS page)' do
      stub_request(:get, 'https://example.com')
        .to_return(status: 200, headers: { 'Content-Type' => 'text/html' },
                   body: '<html><body><div id="app"><script>render()</script></div></body></html>')
      stub_request(:get, 'https://r.jina.ai/https://example.com')
        .to_return(status: 200, body: 'Jina rendered this page with JavaScript content. ' * 5)
      result = @tool.call('url' => 'https://example.com')

      _(result.ok?).must_equal true
      _(result.output).must_include 'Jina rendered this page'
    end

    it 'falls back to jina when local gets an HTTP error' do
      stub_request(:get, 'https://example.com').to_return(status: 403, body: 'forbidden')
      stub_request(:get, 'https://r.jina.ai/https://example.com')
        .to_return(status: 200, body: 'Jina content here. ' * 10)
      result = @tool.call('url' => 'https://example.com')

      _(result.ok?).must_equal true
      _(result.output).must_include 'Jina content here'
    end

    it 'falls back to jina for non-HTML content' do
      stub_request(:get, 'https://example.com')
        .to_return(status: 200, headers: { 'Content-Type' => 'application/pdf' }, body: '%PDF-1.4')
      stub_request(:get, 'https://r.jina.ai/https://example.com')
        .to_return(status: 200, body: 'Jina parsed the PDF into markdown. ' * 10)
      result = @tool.call('url' => 'https://example.com')

      _(result.ok?).must_equal true
      _(result.output).must_include 'Jina parsed the PDF'
    end

    it 'fails when both backends fail and reports both errors' do
      stub_request(:get, 'https://example.com').to_return(status: 500, body: 'boom')
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

  describe 'fetch with VCR' do
    before do
      VCR.insert_cassette('web_fetch_example_com')
    end

    after do
      VCR.eject_cassette
    end

    it 'returns Ask::Result' do
      result = @tool.call('url' => 'https://example.com')

      _(result).must_be_kind_of Ask::Result
      _(result.ok?).must_equal true
    end

    it 'returns markdown output with title and source' do
      result = @tool.call('url' => 'https://example.com')

      _(result.output).must_be_kind_of String
      _(result.output).must_match(/\A# Example Domain/)
      _(result.output).must_include 'Source: https://example.com'
    end

    it 'allows multiple calls via playback repeats' do
      r1 = @tool.call('url' => 'https://example.com')
      r2 = @tool.call('url' => 'https://example.com')

      _(r1.output).must_equal r2.output
    end
  end

  describe 'connection and HTTP errors (all backends fail)' do
    before do
      WebMock.disable_net_connect!
      stub_request(:get, /r\.jina\.ai/).to_return(status: 500, body: 'jina down')
    end

    after do
      WebMock.reset!
    end

    it 'handles connection refused' do
      stub_request(:get, /example\.com/).to_raise(Errno::ECONNREFUSED.new)
      result = @tool.call('url' => 'https://example.com')

      _(result).must_be_kind_of Ask::Result
      _(result.ok?).must_equal false
    end

    it 'handles timeout' do
      stub_request(:get, /example\.com/).to_timeout
      result = @tool.call('url' => 'https://example.com')

      _(result).must_be_kind_of Ask::Result
      _(result.ok?).must_equal false
    end

    it 'handles HTTP error status' do
      stub_request(:get, /example\.com/).to_return(status: 500, body: 'error')
      result = @tool.call('url' => 'https://example.com')

      _(result.ok?).must_equal false
    end

    it 'handles 404' do
      stub_request(:get, /example\.com/).to_return(status: 404, body: 'nope')
      result = @tool.call('url' => 'https://example.com')

      _(result.ok?).must_equal false
    end

    it 'handles redirect loops' do
      stub_request(:get, 'https://example.com')
        .to_return(status: 302, headers: { 'Location' => 'https://example.com' })
      result = @tool.call('url' => 'https://example.com')

      _(result.ok?).must_equal false
    end
  end
end
