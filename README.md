# ask-web-fetch

[![Gem Version](https://badge.fury.io/rb/ask-web-fetch.svg)](https://badge.fury.io/rb/ask-web-fetch)

A web fetch tool for the ask-rb ecosystem. It provides
`Ask::Tools::WebFetch`, which fetches a URL and returns its content as clean
markdown for LLM consumption. It has no Rails dependencies and no API key
required.

## How it works

`Ask::Tools::WebFetch` runs a chain of pluggable backends and returns the
first success:

1. **Local** (default) — pure Ruby `Net::HTTP` + Nokogiri + reverse_markdown:
   browser-like User-Agent, redirects followed, main content extracted
   (`<article>` → `<main>` → `<body>`), navigation/scripts stripped, tables
   become markdown tables, links become `[text](url)`.
2. **Jina** — Jina Reader free tier (`https://r.jina.ai/<url>`). It runs
   headless Chromium, so it renders JS pages the Local backend can't. Free
   without a key (~20 req/min per IP); set `JINA_API_KEY` for higher limits.

The tool falls back automatically: if Local fails (blocked, timeout,
non-HTML, anti-bot challenge, or a JS page with no server-side content), it
tries Jina. If Jina fails too (rate limit, access error, challenge page),
the call returns a failure result listing each backend's error.

### Adding a backend

Backends subclass `Ask::WebFetch::Backend` and implement one method:

```ruby
class Crawl4ai < Ask::WebFetch::Backend
  def fetch(url)
    # return { title: "Page Title", content: "markdown..." }
    # or raise Ask::WebFetch::FetchError / EmptyContentError
  end
end

Ask::Tools::WebFetch.backends = [Crawl4ai, Ask::WebFetch::Backends::Local]
```

`#fetch` must return `{ title: String|nil, content: String }` and raise
`Ask::WebFetch::FetchError` (hard failure) or `EmptyContentError` (page
fetched but nothing usable). The chain then handles ordering and fallback
for you. For tests, `Ask::Tools::WebFetch.backends = [...]` can be swapped
and restored.

## Installation

```ruby
gem "ask-web-fetch"
```

## Quick Start

```ruby
require "ask/web_fetch"

tool = Ask::Tools::WebFetch.new
result = tool.execute(url: "https://www.ruby-lang.org/en/")
puts result
```

Results include the page title, source URL, and clean markdown:

```
# Ruby Programming Language

Source: https://www.ruby-lang.org/en/

Ruby is a dynamic, open-source programming language with a focus on
simplicity and productivity...
```

You can cap the output size:

```ruby
result = tool.execute(url: "https://example.com", max_chars: 5000)
```

If every backend fails (e.g. the page is behind an anti-bot challenge and
Jina is also rate-limited), the call returns a failure result with each
backend's error.

## Configuration

No configuration required for the default chain. Optional knobs:

- `JINA_API_KEY` — enables the Jina fallback with higher rate limits
- `max_chars` parameter — caps output length (default 20000)

## Known limitations

- Pages rendered entirely client-side (JavaScript SPAs) may yield little or
  no content — no JS engine is executed.
- Some sites block non-browser requests regardless of User-Agent.

## Full documentation

The full ask-rb documentation lives at https://ask-rb.github.io/ask-docs.
[Core: Web Fetch](https://ask-rb.github.io/ask-docs/core/web-fetch) covers
ask-web-fetch in depth. API reference: https://ask-rb.github.io/ask-docs/reference/api.

## Development

```
bundle install
bundle exec rake test
```

## License

MIT
