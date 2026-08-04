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

  describe 'extraction' do
    it 'prefers article over main and body' do
      doc = Nokogiri::HTML(<<~HTML)
        <html><body>
          <main><p>main content</p></main>
          <article><p>article content</p></article>
        </body></html>
      HTML
      candidate = @tool.send(:extract_main, doc)

      _(candidate.name).must_equal 'article'
    end

    it 'falls back to main, then body' do
      doc = Nokogiri::HTML('<html><body><main><p>hi</p></main></body></html>')

      _(@tool.send(:extract_main, doc).name).must_equal 'main'

      doc2 = Nokogiri::HTML('<html><body><div><p>hi</p></div></body></html>')

      _(@tool.send(:extract_main, doc2).name).must_equal 'body'
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
      candidate = @tool.send(:extract_main, doc)
      @tool.send(:scrub, candidate)
      html = candidate.to_html

      _(html).wont_include 'alert'
      _(html).wont_include 'sidebar'
      _(html).wont_include '<nav>'
      _(html).must_include 'Keep me.'
    end
  end

  describe 'conversion' do
    it 'converts links to markdown' do
      html = '<main><h1>Title</h1><p>See <a href="https://example.com">example</a>.</p></main>'
      md = @tool.send(:to_markdown, html, 'https://example.com')

      _(md).must_include '[example](https://example.com)'
      _(md).must_include '# Title'
    end

    it 'prepends page title and source' do
      html = '<html><head><title>My Page</title></head><body><p>Body text.</p></body></html>'
      md = @tool.send(:to_markdown, html, 'https://example.com/page')

      _(md).must_match(/\A# My Page/)
      _(md).must_include 'Source: https://example.com/page'
    end

    it 'returns a no-content message for empty pages' do
      md = @tool.send(:to_markdown, '', 'https://example.com')

      _(md).must_equal 'No readable content found at https://example.com.'
    end

    it 'converts tables to markdown tables' do
      html = '<table><tr><td><a href="https://a.com">A</a></td></tr></table>'
      md = @tool.send(:to_markdown, html, 'https://example.com')

      _(md).must_match(%r{\|.*\[A\]\(https://a\.com\)})
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

  describe 'connection and HTTP errors' do
    before do
      WebMock.disable_net_connect!
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

    it 'follows redirects' do
      stub_request(:get, 'https://example.com/start')
        .to_return(status: 302, headers: { 'Location' => 'https://example.com/final' })
      stub_request(:get, 'https://example.com/final')
        .to_return(status: 200, headers: { 'Content-Type' => 'text/html' },
                   body: '<html><head><title>Final</title></head><body><p>Hello.</p></body></html>')
      result = @tool.call('url' => 'https://example.com/start')

      _(result.ok?).must_equal true
      _(result.output).must_include '# Final'
    end

    it 'rejects non-HTML content' do
      stub_request(:get, /example\.com/)
        .to_return(status: 200, headers: { 'Content-Type' => 'application/pdf' }, body: '%PDF')
      result = @tool.call('url' => 'https://example.com')

      _(result.ok?).must_equal false
    end
  end
end
