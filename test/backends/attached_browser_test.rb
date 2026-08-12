# frozen_string_literal: true

require_relative '../test_helper'

# The AttachedBrowser drives a running Chrome over raw CDP. These tests run
# it against a fake CDP client (injected via client:) that records commands
# and answers with canned responses — no real browser is touched.
describe Ask::WebFetch::Backends::AttachedBrowser do
  FakeCDPClient = Class.new do
    attr_reader :commands, :session_commands

    def initialize(title: 'Bot post', html: '<html><body>content</body></html>', url: 'https://example.com', status: 200)
      @title = title
      @html = html
      @url = url
      @status = status
      @commands = []
      @session_commands = []
      @title_calls = 0
    end

    def command(method, **params)
      @commands << [method, params]
      case method
      when 'Target.createTarget'
        { 'targetId' => 't1' }
      when 'Target.attachToTarget'
        { 'sessionId' => 's1' }
      when 'Target.closeTarget'
        {}
      else
        @session_commands << [method, params]
        session_command(method, params)
      end
    end

    def session(_id)
      self
    end

    private

    def session_command(method, params)
      case method
      when 'Page.navigate'
        error = params[:url].start_with?('https://broken') ? 'net::ERR_NAME_NOT_RESOLVED' : nil
        error ? { 'errorText' => error } : {}
      when 'Runtime.evaluate'
        value = case params[:expression]
                when /document\.title/ then title_value
                when /readyState/ then 'complete'
                when /outerHTML/ then @html
                when /location\.href/ then @url
                when /responseStatus/ then @status
                else nil
                end
        # Matches what Ferrum::Client#command returns: CDP's outer result is
        # already unwrapped, so the RemoteObject sits at ["result"].
        { 'result' => { 'type' => 'string', 'value' => value } }
      else
        {}
      end
    end

    def title_value
      @title_calls += 1
      @title.respond_to?(:call) ? @title.call(@title_calls) : @title
    end
  end

  def article_html
    '<html><head><title>Bot post</title></head><body>' \
      "<article><p>#{'Real article content that should survive pruning. ' * 10}</p></article>" \
      '<footer>Copyright</footer></body></html>'
  end

  describe Ask::WebFetch::Backends::AttachedBrowser::Page do
    it 'creates and attaches a fresh target' do
      client = FakeCDPClient.new
      page = Ask::WebFetch::Backends::AttachedBrowser.new('ws://fake', timeout: 10, client: client).create_page

      _(client.commands).must_include ['Target.createTarget', { url: 'about:blank' }]
      _(client.commands).must_include ['Target.attachToTarget', { targetId: 't1', flatten: true }]
      _(page.title).must_equal 'Bot post'
    end

    it 'navigates the page to the url' do
      client = FakeCDPClient.new
      page = Ask::WebFetch::Backends::AttachedBrowser.new('ws://fake', timeout: 10, client: client).create_page

      page.go_to('https://example.com/article')

      _(client.session_commands).must_include ['Page.navigate', { url: 'https://example.com/article' }]
    end

    it 'raises StatusError when navigation fails' do
      client = FakeCDPClient.new
      page = Ask::WebFetch::Backends::AttachedBrowser.new('ws://fake', timeout: 10, client: client).create_page

      _(-> { page.go_to('https://broken.example.com') }).must_raise Ferrum::StatusError
    end

    it 'reads title, url, and body through Runtime.evaluate' do
      client = FakeCDPClient.new(title: 'T', url: 'https://example.com/x', html: article_html)
      page = Ask::WebFetch::Backends::AttachedBrowser.new('ws://fake', timeout: 10, client: client).create_page

      _(page.title).must_equal 'T'
      _(page.url).must_equal 'https://example.com/x'
      _(page.body).must_include 'Real article content'
    end

    it 'reports the main-document HTTP status from the navigation timing API' do
      client = FakeCDPClient.new(status: 200)
      page = Ask::WebFetch::Backends::AttachedBrowser.new('ws://fake', timeout: 10, client: client).create_page

      _(page.network.status).must_equal 200
    end

    it 'closes its own target on close' do
      client = FakeCDPClient.new
      page = Ask::WebFetch::Backends::AttachedBrowser.new('ws://fake', timeout: 10, client: client).create_page

      page.close

      _(client.commands).must_include ['Target.closeTarget', { targetId: 't1' }]
    end

    it 'restores the captured frontmost app when the tab closes' do
      client = FakeCDPClient.new
      browser = Ask::WebFetch::Backends::AttachedBrowser.new('ws://fake', timeout: 10, client: client)
      # Inject a runner that records the osascript activation.
      captured = nil
      Ask::WebFetch::Backends::FocusRestorer.runner = ->(cmd) { captured = cmd }
      browser.instance_variable_set(:@frontmost_app, 'Safari')
      page = browser.create_page
      page.close
      _(captured).must_match(/Safari/)
    ensure
      Ask::WebFetch::Backends::FocusRestorer.runner = nil
    end

    it 'never restores to Chrome itself — no focus ping-pong' do
      called = false
      Ask::WebFetch::Backends::FocusRestorer.runner = ->(*) { called = true }
      Ask::WebFetch::Backends::FocusRestorer.restore_frontmost('Google Chrome')
      _(called).must_equal false
    ensure
      Ask::WebFetch::Backends::FocusRestorer.runner = nil
    end
  end

  describe 'through the Browser backend' do
    before do
      Ask::WebFetch::Backends::Browser.path = '/fake/chrome'
      Ask::WebFetch::Backends::Browser.poll_interval = 0.01
    end

    after do
      Ask::WebFetch::Backends::Browser.browser = nil
      Ask::WebFetch::Backends::Browser.path = nil
      Ask::WebFetch::Backends::Browser.content_filter = nil
      Ask::WebFetch::Backends::Browser.poll_interval = nil
    end

    it 'fetches a page from the attached browser and converts it to markdown' do
      client = FakeCDPClient.new(title: 'Bot post', status: 200, html: article_html)
      Ask::WebFetch::Backends::Browser.browser =
        Ask::WebFetch::Backends::AttachedBrowser.new('ws://fake', timeout: 10, client: client)

      result = Ask::WebFetch::Backends::Browser.new.fetch('https://example.com')

      _(result[:title]).must_equal 'Bot post'
      _(result[:content]).must_include 'Real article content'
      _(result[:content]).wont_include 'Copyright'
    end

    it 'waits for a challenge to clear before reading content' do
      client = FakeCDPClient.new(
        title: ->(calls) { calls <= 2 ? 'Just a moment...' : 'Bot post' },
        status: 200,
        html: article_html
      )
      Ask::WebFetch::Backends::Browser.browser =
        Ask::WebFetch::Backends::AttachedBrowser.new('ws://fake', timeout: 10, client: client)

      result = Ask::WebFetch::Backends::Browser.new.fetch('https://example.com')

      _(result[:content]).must_include 'Real article content'
    end

    it 'warms the domain root and retries when the deep URL is challenged' do
      # First visit to the deep URL serves a challenge shell; the warm
      # pass navigates to the domain root (where the challenge auto-solves)
      # and earns the clearance; the retried deep URL then serves content.
      # Title clears once the root has been visited (navigate #2).
      navigations = []
      client = FakeCDPClient.new(
        title: ->(calls) { calls <= 3 ? 'Just a moment...' : 'Bot post' },
        status: 200,
        html: '<html><body>cf-chl-solving</body></html>'
      )
      # Serve real content after the warm pass has visited the root.
      real_html = '<html><head><title>Bot post</title></head><body><p>Real article content with enough length to clear the minimum content threshold for a usable page.</p></body></html>'
      client.define_singleton_method(:session_command) do |method, params|
        if method == 'Page.navigate'
          navigations << params[:url]
          @html = real_html if navigations.include?('https://example.com')
        end
        super(method, params)
      end
      Ask::WebFetch::Backends::Browser.warmed_domains.clear
      Ask::WebFetch::Backends::Browser.browser =
        Ask::WebFetch::Backends::AttachedBrowser.new('ws://fake', timeout: 10, client: client)

      result = Ask::WebFetch::Backends::Browser.new.fetch('https://example.com/deep')

      _(navigations).must_include 'https://example.com' # root warm pass happened
      _(navigations).must_include 'https://example.com/deep' # URL retried after warm
      _(result[:content]).must_include 'Real article content'
    end

    it 'raises FetchError on an HTTP error status' do
      client = FakeCDPClient.new(status: 404, html: '<html><body><p>not found</p></body></html>')
      Ask::WebFetch::Backends::Browser.browser =
        Ask::WebFetch::Backends::AttachedBrowser.new('ws://fake', timeout: 10, client: client)

      err = _(-> { Ask::WebFetch::Backends::Browser.new.fetch('https://example.com') })
            .must_raise Ask::WebFetch::FetchError
      _(err.message).must_include 'got 404'
    end

    it 'fails through on a parked-domain page rendered by the browser' do
      # The JS redirect lands on GoDaddy's parking-lander — the browser
      # renders it, and the shared parked-domain detector must reject it.
      client = FakeCDPClient.new(
        status: 200,
        html: '<html><head><title>ayur.ai</title></head><body><script>window._trfd=window._trfd||[],window._trfd.push({ap:"parking"})</script><div id="root"></div></body></html>'
      )
      Ask::WebFetch::Backends::Browser.browser =
        Ask::WebFetch::Backends::AttachedBrowser.new('ws://fake', timeout: 10, client: client)

      err = _(-> { Ask::WebFetch::Backends::Browser.new.fetch('https://ayur.ai') })
            .must_raise Ask::WebFetch::ParkedDomainError
      _(err.message).must_include 'parked domain'
    end
  end
end
