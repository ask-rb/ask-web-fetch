# frozen_string_literal: true

require_relative 'test_helper'

# The native agent tool — Ask::Tool framing of the library. Runs only
# when ask-tools is present (it is, in the gem's dev bundle); the tool
# itself is an optional integration for agent-framework consumers.
if defined?(Ask::Tools)
  describe Ask::Tools::WebFetch do
    before do
      @tool = Ask::Tools::WebFetch.new
    end

    it 'registers itself in the tool registry' do
      tool = Ask::Tools['web_fetch']

      _(tool).wont_be_nil
      _(tool).must_be_kind_of Ask::Tools::WebFetch
    end

    it 'has the tool framing: name, description, url + max_chars params' do
      _(@tool.name).must_equal 'web_fetch'
      _(@tool.description).wont_be :empty?
      schema = @tool.params_schema

      _(schema['required']).must_include 'url'
      _(schema.dig('properties', 'url', 'type')).must_equal 'string'
      _(schema.dig('properties', 'max_chars', 'type')).must_equal 'integer'
      _(schema['required']).wont_include 'max_chars'
    end

    it 'delegates the chain configuration to the library' do
      Ask::Tools::WebFetch.backends = [Ask::WebFetch::Backends::Local]
      _(Ask::Tools::WebFetch.backends).must_equal [Ask::WebFetch::Backends::Local]
      _(Ask::WebFetch.backends).must_equal [Ask::WebFetch::Backends::Local]
    ensure
      Ask::WebFetch.backends = nil
      Ask::Tools::WebFetch.backends = nil
    end

    describe 'execute' do
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
        Ask::WebFetch::Backends::Browser.path = nil
        Ask::WebFetch::Backends::Local.http = @original_local_http
        WebMock.reset!
      end

      def stub_local(&handler)
        @local_http.handler = handler
      end

      it 'returns the fetched markdown as an Ask::Result' do
        body = '<html><head><title>Tool Page</title></head><body><article>' \
               "<p>#{'Content fetched through the native tool. ' * 10}</p></article></body></html>"
        stub_local { |_, _| http_response(200, body) }

        result = @tool.call('url' => 'https://example.com')

        _(result).must_be_kind_of Ask::Result
        _(result.ok?).must_equal true
        _(result.output).must_include '# Tool Page'
        _(result.output).must_include 'Source: https://example.com'
      end

      it 'surfaces a terminal verdict as a failed result' do
        stub_local do |_, _|
          http_response(200, '<html><body>example.com is parked free, courtesy of GoDaddy.com</body></html>')
        end
        stub_request(:get, 'https://r.jina.ai/https://example.com').to_return(status: 404, body: 'nope')

        result = @tool.call('url' => 'https://example.com')

        _(result.ok?).must_equal false
        _(result.error_message).must_match(/ParkedDomainError/)
      end
    end
  end
end
