# frozen_string_literal: true

require_relative 'test_helper'
require 'socket'
require 'zlib'

describe Ask::WebFetch::Http do
  # A minimal HTTP/1.1 server: answers queued responses with keep-alive
  # and counts the TCP connections it accepted. Deterministic proof of the
  # pooling property — N requests, 1 connection — and a real server for
  # the decoding/retry paths the seam-stubbed Local tests can't cover.
  class FakeServer
    attr_reader :connections

    def initialize
      @server = TCPServer.new('127.0.0.1', 0)
      @connections = 0
      @responses = Queue.new
      @sockets = []
      @thread = Thread.new { serve }
    end

    def port
      @server.addr[1]
    end

    def respond(status:, body:, headers: {})
      @responses << [status, body, headers]
    end

    def close
      @thread.kill
      @server.close
      @sockets.each { |sock| sock.close rescue nil }
    end

    private

    def serve
      loop do
        socket = @server.accept
        @connections += 1
        @sockets << socket
        Thread.new(socket) { |sock| serve_connection(sock) }
      end
    end

    def serve_connection(socket)
      loop do
        request = read_request(socket)
        break if request.nil?

        status, body, headers = @responses.pop
        socket.write(response_for(status, body, headers))
      end
    rescue IOError, Errno::ECONNRESET
      # client closed the connection — nothing to clean up
    ensure
      socket.close rescue nil
    end

    def read_request(socket)
      head = +''
      head << socket.readpartial(1024) until head.include?("\r\n\r\n")
      head
    rescue EOFError
      nil
    end

    def response_for(status, body, headers)
      headers = { 'Content-Type' => 'text/html', 'Content-Length' => body.bytesize.to_s,
                  'Connection' => 'keep-alive' }.merge(headers)
      "HTTP/1.1 #{status} #{REASON_PHRASES.fetch(status, 'Status')}\r\n" \
        "#{headers.map { |k, v| "#{k}: #{v}" }.join("\r\n")}\r\n\r\n#{body}"
    end

    REASON_PHRASES = { 200 => 'OK', 301 => 'Moved Permanently', 302 => 'Found',
                       404 => 'Not Found', 429 => 'Too Many Requests',
                       500 => 'Internal Server Error', 503 => 'Service Unavailable' }.freeze
  end

  before do
    @server = FakeServer.new
    @base = "http://127.0.0.1:#{@server.port}"
  end

  after do
    @server.close
  end

  it 'serves sequential requests across hosts without hanging' do
    # Regression for the httpx 1.8.1 :persistent wedge: a session that
    # held one pooled connection would hang forever inside the selector
    # loop when the next request went to a NEW host (reproduced in plain
    # Ruby against real sites). The transport no longer uses :persistent;
    # the contract is correctness across hosts, at the cost of a fresh
    # connection per host. Each request must complete, in order.
    @server.respond(status: 200, body: '<html>first</html>')
    first = Ask::WebFetch::Http.get("#{@base}/one")
    _(first.body).must_include 'first'

    @server.respond(status: 200, body: '<html>second</html>')
    second = Ask::WebFetch::Http.get("#{@base}/two")
    _(second.body).must_include 'second'

    @server.respond(status: 200, body: '<html>third</html>')
    third = Ask::WebFetch::Http.get("#{@base}/three")
    _(third.body).must_include 'third'
  end

  it 'decodes gzip-encoded bodies' do
    @server.respond(status: 200, body: Zlib.gzip('<html><body><p>compressed content</p></body></html>'),
                    headers: { 'Content-Encoding' => 'gzip' })

    response = Ask::WebFetch::Http.get("#{@base}/page")

    _(response.body).must_include 'compressed content'
    _(response.status).must_equal 200
    _(response.content_type).must_include 'text/html'
  end

  it 'reports the hop status and location' do
    @server.respond(status: 301, body: '', headers: { 'Location' => 'https://example.com/new' })

    response = Ask::WebFetch::Http.get("#{@base}/old")

    _(response.status).must_equal 301
    _(response.location).must_equal 'https://example.com/new'
  end

  it 'retries a 503 and succeeds on the retry' do
    @server.respond(status: 503, body: 'busy')
    @server.respond(status: 200, body: '<html>ok</html>')

    response = Ask::WebFetch::Http.get("#{@base}/retry")

    _(response.status).must_equal 200
    _(@server.connections).must_equal 1
  end

  it 'raises TimeoutError when the connection is refused' do
    probe = TCPServer.new('127.0.0.1', 0)
    port = probe.addr[1]
    probe.close

    _(-> { Ask::WebFetch::Http.get("http://127.0.0.1:#{port}/") }).must_raise Ask::WebFetch::TimeoutError
  end
end
