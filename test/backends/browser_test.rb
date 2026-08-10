# frozen_string_literal: true

require_relative '../test_helper'

# The Browser backend drives a real Chrome via Ferrum, which no CI wants to
# spawn for unit tests. These tests exercise the backend's logic — challenge
# waiting, status/error mapping, page lifecycle — against a fake browser
# injected through Browser.browser=, the same seam the backend uses for its
# shared real browser.
describe Ask::WebFetch::Backends::Browser do
  FakeNetwork = Class.new do
    def initialize(status)
      @status = status
    end

    def status
      @status
    end

    def wait_for_idle(*)
      nil
    end
  end

  FakePage = Class.new do
    attr_accessor :closed, :title_calls

    def initialize(html:, title: 'Real Title', status: 200)
      @html = html
      @title_proc = title.respond_to?(:call) ? title : ->(*) { title }
      @status = status
      @title_calls = 0
      @closed = false
    end

    def go_to(_url)
      nil
    end

    def url
      'https://example.com'
    end

    def title
      @title_calls += 1
      @title_proc.call(@title_calls)
    end

    def body
      @html
    end

    def network
      FakeNetwork.new(@status)
    end

    def close
      @closed = true
    end
  end

  FakeBrowser = Class.new do
    def initialize(pages)
      @pages = pages
    end

    def create_page
      @pages.shift
    end
  end

  def article_html
    '<html><head><title>Bot post</title></head><body>' \
      '<nav><a href="/">Home</a></nav>' \
      "<article><p>#{'Real article content that should survive pruning. ' * 10}</p></article>" \
      '<footer>Copyright</footer></body></html>'
  end

  def build_backend(page)
    Ask::WebFetch::Backends::Browser.browser = FakeBrowser.new([page])
    Ask::WebFetch::Backends::Browser.new
  end

  before do
    Ask::WebFetch::Backends::Browser.path = '/fake/chrome'
    Ask::WebFetch::Backends::Browser.poll_interval = 0.01
    Ask::WebFetch::Backends::Browser.challenge_timeout = 5
  end

  after do
    Ask::WebFetch::Backends::Browser.browser = nil
    Ask::WebFetch::Backends::Browser.path = nil
    Ask::WebFetch::Backends::Browser.content_filter = nil
    Ask::WebFetch::Backends::Browser.poll_interval = nil
    Ask::WebFetch::Backends::Browser.challenge_timeout = nil
  end

  describe 'configuration' do
    it 'is configured when a browser path is set' do
      _(Ask::WebFetch::Backends::Browser.configured?).must_equal true
    end

    it 'is not configured without a browser path' do
      Ask::WebFetch::Backends::Browser.path = ''

      _(Ask::WebFetch::Backends::Browser.configured?).must_equal false
    end

    it 'is configured when only a CDP endpoint is set' do
      Ask::WebFetch::Backends::Browser.path = ''
      Ask::WebFetch::Backends::Browser.cdp_url = 'http://127.0.0.1:9222'

      _(Ask::WebFetch::Backends::Browser.configured?).must_equal true
    ensure
      Ask::WebFetch::Backends::Browser.cdp_url = nil
    end

    it 'honors ASK_WEB_FETCH_CHROME_PATH' do
      Ask::WebFetch::Backends::Browser.path = nil
      old = ENV['ASK_WEB_FETCH_CHROME_PATH']
      ENV['ASK_WEB_FETCH_CHROME_PATH'] = '/custom/chrome'

      _(Ask::WebFetch::Backends::Browser.path).must_equal '/custom/chrome'
    ensure
      ENV['ASK_WEB_FETCH_CHROME_PATH'] = old
    end
  end

  describe 'ws_url_for' do
    before do
      WebMock.disable_net_connect!
    end

    after do
      WebMock.reset!
    end

    it 'passes a ws:// endpoint through unchanged' do
      _(Ask::WebFetch::Backends::Browser.ws_url_for('ws://127.0.0.1:9222/devtools/browser/x'))
        .must_equal 'ws://127.0.0.1:9222/devtools/browser/x'
    end

    it 'discovers the browser WebSocket URL from an HTTP endpoint' do
      stub_request(:get, 'http://127.0.0.1:9222/json/version')
        .to_return(status: 200, body: '{"webSocketDebuggerUrl": "ws://127.0.0.1:9222/devtools/browser/abc"}')

      _(Ask::WebFetch::Backends::Browser.ws_url_for('http://127.0.0.1:9222'))
        .must_equal 'ws://127.0.0.1:9222/devtools/browser/abc'
    end

    it 'accepts a full /json/version URL' do
      stub_request(:get, 'http://127.0.0.1:9222/json/version')
        .to_return(status: 200, body: '{"webSocketDebuggerUrl": "ws://x"}')

      _(Ask::WebFetch::Backends::Browser.ws_url_for('http://127.0.0.1:9222/json/version')).must_equal 'ws://x'
    end

    it 'raises FetchError when the endpoint is unreachable' do
      stub_request(:get, 'http://127.0.0.1:9222/json/version').to_raise(Errno::ECONNREFUSED.new)

      err = _(-> { Ask::WebFetch::Backends::Browser.ws_url_for('http://127.0.0.1:9222') })
            .must_raise Ask::WebFetch::FetchError
      _(err.message).must_include 'cannot reach CDP endpoint'
    end

    it 'raises FetchError on a malformed version response' do
      stub_request(:get, 'http://127.0.0.1:9222/json/version').to_return(status: 200, body: 'not json')

      err = _(-> { Ask::WebFetch::Backends::Browser.ws_url_for('http://127.0.0.1:9222') })
            .must_raise Ask::WebFetch::FetchError
      _(err.message).must_include 'bad CDP version response'
    end
  end

  describe 'fetch' do
    it 'returns title and content from the rendered page' do
      page = FakePage.new(html: article_html)
      result = build_backend(page).fetch('https://example.com')

      _(result[:title]).must_equal 'Bot post'
      _(result[:content]).must_include 'Real article content'
      _(result[:content]).wont_include 'Copyright'
    end

    it 'extracts outlinks from the raw rendered HTML — nav included' do
      page = FakePage.new(html: article_html)
      result = build_backend(page).fetch('https://example.com')

      _(result[:outlinks]).must_include 'https://example.com/'
    end

    it 'closes the page after the fetch' do
      page = FakePage.new(html: article_html)
      build_backend(page).fetch('https://example.com')

      _(page.closed).must_equal true
    end

    it 'waits for a Cloudflare challenge to auto-solve' do
      page = FakePage.new(
        html: article_html,
        title: ->(calls) { calls <= 2 ? 'Just a moment...' : 'Bot post' }
      )
      result = build_backend(page).fetch('https://example.com')

      _(page.title_calls).must_be :>, 2
      _(result[:content]).must_include 'Real article content'
    end

    it 'raises FetchError when a challenge never solves' do
      page = FakePage.new(html: article_html, title: 'Just a moment...')
      backend = build_backend(page)
      backend.class.challenge_timeout = 0.2

      err = _(-> { backend.fetch('https://example.com') }).must_raise Ask::WebFetch::FetchError
      _(err.message).must_include 'challenge did not auto-solve'
    end

    it 'raises FetchError when the body still carries the challenge marker' do
      page = FakePage.new(html: '<html><head><title>X</title></head><body>cf-chl widget</body></html>')
      backend = build_backend(page)
      backend.class.challenge_timeout = 0.1

      _(-> { backend.fetch('https://example.com') }).must_raise Ask::WebFetch::FetchError
    end

    it 'raises FetchError for an HTTP error status' do
      page = FakePage.new(html: '<html><body><p>not found</p></body></html>', status: 404)

      err = _(-> { build_backend(page).fetch('https://example.com') }).must_raise Ask::WebFetch::FetchError
      _(err.message).must_include 'got 404'
    end

    it 'raises EmptyContentError for a page with no readable content' do
      page = FakePage.new(html: '<html><body><script>render()</script></body></html>')

      _(-> { build_backend(page).fetch('https://example.com') }).must_raise Ask::WebFetch::EmptyContentError
    end

    it 'raises FetchError when no browser is configured' do
      Ask::WebFetch::Backends::Browser.path = ''

      _(-> { Ask::WebFetch::Backends::Browser.new.fetch('https://example.com') })
        .must_raise Ask::WebFetch::FetchError
    end
  end

  describe 'error mapping' do
    it 'wraps Ferrum::TimeoutError in TimeoutError' do
      page = Class.new do
        def go_to(_url)
          raise Ferrum::TimeoutError, 'navigating'
        end

        def close
          nil
        end
      end.new
      backend = build_backend(page)

      _(-> { backend.fetch('https://example.com') }).must_raise Ask::WebFetch::TimeoutError
    end

    it 'wraps Ferrum::StatusError in FetchError' do
      page = Class.new do
        def go_to(_url)
          raise Ferrum::StatusError, 'net::ERR_NAME_NOT_RESOLVED'
        end

        def close
          nil
        end
      end.new
      backend = build_backend(page)

      err = _(-> { backend.fetch('https://example.com') }).must_raise Ask::WebFetch::FetchError
      _(err.message).must_include 'could not load'
    end
  end
end
