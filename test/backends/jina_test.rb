# frozen_string_literal: true

require_relative '../test_helper'

describe Ask::WebFetch::Backends::Jina do
  before do
    @backend = Ask::WebFetch::Backends::Jina.new
    WebMock.disable_net_connect!
  end

  after do
    ENV.delete('JINA_API_KEY')
    WebMock.reset!
  end

  it 'requests the Jina reader URL with the target URL appended' do
    stub_request(:get, 'https://r.jina.ai/https://example.com')
      .to_return(status: 200, body: 'content ' * 30)
    @backend.fetch('https://example.com')

    assert_requested :get, 'https://r.jina.ai/https://example.com'
  end

  it 'sends an Authorization header when JINA_API_KEY is set' do
    ENV['JINA_API_KEY'] = 'test-key'
    stub_request(:get, /r\.jina\.ai/).to_return(status: 200, body: 'content ' * 30)
    @backend.fetch('https://example.com')
    assert_requested(:get, /r\.jina\.ai/) { |req| req.headers['Authorization'] == 'Bearer test-key' }
  end

  it 'returns content for a 200 response' do
    body = 'Some markdown content that is long enough to pass the usable threshold. ' * 3
    stub_request(:get, /r\.jina\.ai/).to_return(status: 200, body: body)
    page = @backend.fetch('https://example.com')

    _(page[:content]).must_equal body.strip
    assert_nil page[:title]
  end

  it 'extracts outlinks from the returned markdown' do
    body = "[Docs](/docs) and [External](https://other.com/x) and [Mail](mailto:x@example.com).\n" \
           'Some more content that is long enough to pass the usable threshold here. ' * 2
    stub_request(:get, /r\.jina\.ai/).to_return(status: 200, body: body)
    page = @backend.fetch('https://example.com/guide')

    _(page[:outlinks]).must_include 'https://example.com/docs'
    _(page[:outlinks]).must_include 'https://other.com/x'
    _(page[:outlinks]).wont_include 'mailto:x@example.com'
  end

  it 'strips decorative symbol noise from the returned markdown' do
    noise = '+ = · ( ~ @ · # % · & \* ? · / : ; · \< \> · [] · { · } | · ^ $ · ! · ' * 6
    body = "Some real content that is long enough to pass the threshold.\n\n#{noise}\n"
    stub_request(:get, /r\.jina\.ai/).to_return(status: 200, body: body)
    page = @backend.fetch('https://example.com')

    _(page[:content]).wont_include '+ = ·'
    _(page[:content]).must_include 'Some real content'
  end

  it 'raises EmptyContentError when the page was nothing but noise' do
    noise = '+ = · ( ~ @ · # % · & \* ? · / : ; · \< \> · [] · { · } | · ^ $ · ! · ' * 6
    stub_request(:get, /r\.jina\.ai/).to_return(status: 200, body: "#{noise}\n")

    _(-> { @backend.fetch('https://example.com') }).must_raise Ask::WebFetch::EmptyContentError
  end

  it 'raises ParkedDomainError when the page is a registrar parking page' do
    parked = "example.com is parked free, courtesy of GoDaddy.com\n\n#{'Ad links for the for-sale domain. ' * 10}"
    stub_request(:get, /r\.jina\.ai/).to_return(status: 200, body: parked)

    _(-> { @backend.fetch('https://example.com') }).must_raise Ask::WebFetch::ParkedDomainError
  end

  it 'raises ServerError on rate limit (429)' do
    stub_request(:get, /r\.jina\.ai/).to_return(status: 429, body: 'rate limited')

    _(-> { @backend.fetch('https://example.com') }).must_raise Ask::WebFetch::ServerError
  end

  it 'raises FetchError on access errors (401/403)' do
    stub_request(:get, /r\.jina\.ai/).to_return(status: 403, body: 'forbidden')

    _(-> { @backend.fetch('https://example.com') }).must_raise Ask::WebFetch::FetchError
  end

  it 'raises ServerError on server errors' do
    stub_request(:get, /r\.jina\.ai/).to_return(status: 503, body: 'unavailable')

    _(-> { @backend.fetch('https://example.com') }).must_raise Ask::WebFetch::ServerError
  end

  it 'raises FetchError on challenge pages' do
    stub_request(:get, /r\.jina\.ai/).to_return(status: 200, body: '<title>Just a moment...</title>')

    _(-> { @backend.fetch('https://example.com') }).must_raise Ask::WebFetch::FetchError
  end

  it 'raises EmptyContentError on empty responses' do
    stub_request(:get, /r\.jina\.ai/).to_return(status: 200, body: '   ')

    _(-> { @backend.fetch('https://example.com') }).must_raise Ask::WebFetch::EmptyContentError
  end

  it 'wraps timeouts in TimeoutError' do
    stub_request(:get, /r\.jina\.ai/).to_timeout

    _(-> { @backend.fetch('https://example.com') }).must_raise Ask::WebFetch::TimeoutError
  end

  it 'raises ServerError on rate limits and 5xx' do
    stub_request(:get, /r\.jina\.ai/).to_return(status: 429, body: 'rate limited')

    _(-> { @backend.fetch('https://example.com') }).must_raise Ask::WebFetch::ServerError

    stub_request(:get, /r\.jina\.ai/).to_return(status: 503, body: 'unavailable')
    _(-> { @backend.fetch('https://example.com') }).must_raise Ask::WebFetch::ServerError
  end
end
