# frozen_string_literal: true

require_relative '../test_helper'

describe Ask::WebFetch::Backends::Crawl4Ai do
  before do
    @backend = Ask::WebFetch::Backends::Crawl4Ai.new
    Ask::WebFetch::Backends::Crawl4Ai.url = 'http://crawl4ai.test'
    WebMock.disable_net_connect!
  end

  after do
    Ask::WebFetch::Backends::Crawl4Ai.url = nil
    Ask::WebFetch::Backends::Crawl4Ai.token = nil
    ENV.delete('CRAWL4AI_URL')
    ENV.delete('CRAWL4AI_TOKEN')
    WebMock.reset!
  end

  def long_content
    'Some markdown content that is long enough to pass the usable threshold. ' * 3
  end

  def crawl_body(markdown: long_content, title: 'Example Page', description: 'The page described by its own metadata.', success: true, error_message: nil)
    result = {
      url: 'https://example.com',
      success: success,
      markdown: { fit_markdown: markdown, raw_markdown: markdown },
      metadata: { title: title, description: description }
    }
    result[:error_message] = error_message if error_message
    { success: true, results: [result] }.to_json
  end

  it 'raises FetchError when not configured' do
    Ask::WebFetch::Backends::Crawl4Ai.url = nil

    _(-> { @backend.fetch('https://example.com') }).must_raise Ask::WebFetch::FetchError
  end

  it 'POSTs the URL to the /crawl endpoint' do
    stub_request(:post, 'http://crawl4ai.test/crawl')
      .with(body: { urls: ['https://example.com'], crawler_config: { cache_mode: 'bypass', timeout: 60 } }.to_json)
      .to_return(status: 200, body: crawl_body)

    @backend.fetch('https://example.com')

    assert_requested :post, 'http://crawl4ai.test/crawl'
  end

  it 'sends an Authorization header when a token is configured' do
    Ask::WebFetch::Backends::Crawl4Ai.token = 'secret'
    stub_request(:post, /crawl4ai\.test/).to_return(status: 200, body: crawl_body)

    @backend.fetch('https://example.com')

    assert_requested(:post, /crawl4ai\.test/) { |req| req.headers['Authorization'] == 'Bearer secret' }
  end

  it 'returns the fit markdown, title, and meta description for a successful crawl' do
    stub_request(:post, /crawl4ai\.test/).to_return(status: 200, body: crawl_body)
    page = @backend.fetch('https://example.com')

    _(page[:title]).must_equal 'Example Page'
    _(page[:description]).must_equal 'The page described by its own metadata.'
    _(page[:content]).must_equal long_content.strip
  end

  it 'extracts outlinks from the raw markdown (nav survives the fit filter)' do
    markdown = "[Home](/)\n[Guide](/guide)\n[External](https://other.com/x)\n#{long_content}"
    stub_request(:post, /crawl4ai\.test/).to_return(status: 200, body: crawl_body(markdown: markdown))
    page = @backend.fetch('https://example.com')

    _(page[:outlinks]).must_include 'https://example.com/'
    _(page[:outlinks]).must_include 'https://example.com/guide'
    _(page[:outlinks]).must_include 'https://other.com/x'
  end

  it 'strips decorative symbol noise from the returned markdown' do
    noise = '+ = · ( ~ @ · # % · & \* ? · / : ; · \< \> · [] · { · } | · ^ $ · ! · ' * 6
    markdown = "Some real content that is long enough to pass the threshold.\n\n#{noise}\n"
    stub_request(:post, /crawl4ai\.test/).to_return(status: 200, body: crawl_body(markdown: markdown))
    page = @backend.fetch('https://example.com')

    _(page[:content]).wont_include '+ = ·'
    _(page[:content]).must_include 'Some real content'
  end

  it 'raises EmptyContentError when the page was nothing but noise' do
    noise = '+ = · ( ~ @ · # % · & \* ? · / : ; · \< \> · [] · { · } | · ^ $ · ! · ' * 6
    stub_request(:post, /crawl4ai\.test/).to_return(status: 200, body: crawl_body(markdown: "#{noise}\n"))

    _(-> { @backend.fetch('https://example.com') }).must_raise Ask::WebFetch::EmptyContentError
  end

  it 'falls back to og_description when description is missing' do
    body = {
      success: true,
      results: [
        {
          url: 'https://example.com',
          success: true,
          markdown: { fit_markdown: long_content, raw_markdown: long_content },
          metadata: { title: 'Example Page', og_description: 'OG fallback description.' }
        }
      ]
    }.to_json
    stub_request(:post, /crawl4ai\.test/).to_return(status: 200, body: body)
    page = @backend.fetch('https://example.com')

    _(page[:description]).must_equal 'OG fallback description.'
  end

  it 'falls back to raw markdown when fit markdown is empty' do
    body = {
      success: true,
      results: [
        {
          url: 'https://example.com',
          success: true,
          markdown: { fit_markdown: '', raw_markdown: 'Raw fallback content. ' * 10 },
          metadata: { title: nil }
        }
      ]
    }.to_json
    stub_request(:post, /crawl4ai\.test/).to_return(status: 200, body: body)

    page = @backend.fetch('https://example.com')

    _(page[:content]).must_include 'Raw fallback content.'
  end

  it 'raises FetchError when the crawl result reports failure' do
    stub_request(:post, /crawl4ai\.test/)
      .to_return(status: 200, body: crawl_body(success: false, error_message: 'navigation failed'))

    _(-> { @backend.fetch('https://example.com') }).must_raise Ask::WebFetch::FetchError
  end

  it 'raises FetchError on auth errors (401/403)' do
    stub_request(:post, /crawl4ai\.test/).to_return(status: 401, body: 'unauthorized')

    _(-> { @backend.fetch('https://example.com') }).must_raise Ask::WebFetch::FetchError
  end

  it 'raises ServerError when the service itself answers 5xx' do
    stub_request(:post, /crawl4ai\.test/).to_return(status: 503, body: 'unavailable')

    _(-> { @backend.fetch('https://example.com') }).must_raise Ask::WebFetch::ServerError
  end

  it 'raises EmptyContentError when nothing usable came back' do
    stub_request(:post, /crawl4ai\.test/).to_return(status: 200, body: crawl_body(markdown: '   '))

    _(-> { @backend.fetch('https://example.com') }).must_raise Ask::WebFetch::EmptyContentError
  end

  it 'raises FetchError on a malformed JSON response' do
    stub_request(:post, /crawl4ai\.test/).to_return(status: 200, body: 'not json at all')

    _(-> { @backend.fetch('https://example.com') }).must_raise Ask::WebFetch::FetchError
  end

  it 'wraps connection errors in TimeoutError' do
    stub_request(:post, /crawl4ai\.test/).to_raise(Errno::ECONNREFUSED.new)

    _(-> { @backend.fetch('https://example.com') }).must_raise Ask::WebFetch::TimeoutError
  end

  it 'wraps timeouts in TimeoutError' do
    stub_request(:post, /crawl4ai\.test/).to_timeout

    _(-> { @backend.fetch('https://example.com') }).must_raise Ask::WebFetch::TimeoutError
  end

  it 'raises FetchError when the rendered page is a 4xx error page' do
    result = JSON.parse(crawl_body)['results'].first.merge('status_code' => 404)
    stub_request(:post, /crawl4ai\.test/).to_return(status: 200, body: {success: true, results: [result]}.to_json)

    err = _(-> { @backend.fetch('https://example.com') }).must_raise Ask::WebFetch::FetchError
    _(err.message).must_include 'Crawl4AI got 404 at https://example.com'
  end

  it 'raises ServerError when the rendered page is a 429' do
    result = JSON.parse(crawl_body)['results'].first.merge('status_code' => 429)
    stub_request(:post, /crawl4ai\.test/).to_return(status: 200, body: {success: true, results: [result]}.to_json)

    _(-> { @backend.fetch('https://example.com') }).must_raise Ask::WebFetch::ServerError
  end

  it 'raises ServerError when the rendered page is a 5xx' do
    result = JSON.parse(crawl_body)['results'].first.merge('status_code' => 503)
    stub_request(:post, /crawl4ai\.test/).to_return(status: 200, body: {success: true, results: [result]}.to_json)

    _(-> { @backend.fetch('https://example.com') }).must_raise Ask::WebFetch::ServerError
  end

  it 'exposes the redirect chain the crawl followed' do
    result = JSON.parse(crawl_body)['results'].first
    result['redirected_status_code'] = 301
    result['redirected_url'] = 'https://example.com/canonical'
    stub_request(:post, /crawl4ai\.test/).to_return(status: 200, body: {success: true, results: [result]}.to_json)

    page = @backend.fetch('https://example.com/old')

    _(page[:redirected]).must_equal(status: 301, url: 'https://example.com/canonical')
  end

  it 'returns no redirect info when the page answered directly' do
    stub_request(:post, /crawl4ai\.test/).to_return(status: 200, body: crawl_body)

    page = @backend.fetch('https://example.com')

    assert_nil page[:redirected]
  end

  it 'raises FetchError on challenge pages' do
    stub_request(:post, /crawl4ai\.test/)
      .to_return(status: 200, body: crawl_body(markdown: '<title>Just a moment...</title>'))

    _(-> { @backend.fetch('https://example.com') }).must_raise Ask::WebFetch::FetchError
  end
end
