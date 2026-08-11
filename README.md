# ask-web-fetch

[![Gem Version](https://badge.fury.io/rb/ask-web-fetch.svg)](https://badge.fury.io/rb/ask-web-fetch)

A web fetch tool for the ask-rb ecosystem. It provides
`Ask::Tools::WebFetch`, which fetches a URL and returns its content as clean
markdown for LLM consumption. It has no Rails dependencies and no API key
required.

## How it works

`Ask::Tools::WebFetch` runs a chain of pluggable backends and returns the
first success:

1. **Crawl4AI** (when configured) — self-hosted headless-Chromium renderer
   (`POST /crawl` on `CRAWL4AI_URL`, default `http://localhost:11235`).
   Renders JavaScript and returns clean fit-markdown, so it handles the
   SPA pages the Local backend can't. Set `CRAWL4AI_URL` and it leads the
   chain; when the service is down or unreachable it fails fast and falls
   through.
2. **Local** (default) — pure Ruby `Net::HTTP` + Nokogiri + reverse_markdown:
   browser-like User-Agent, redirects followed, main content extracted
   (`<article>` → `<main>` → `<body>`), navigation/scripts stripped, tables
   become markdown tables, links become `[text](url)`.
3. **Jina** — Jina Reader free tier (`https://r.jina.ai/<url>`). It runs
   headless Chromium, so it renders JS pages the Local backend can't. Free
   without a key (~20 req/min per IP); set `JINA_API_KEY` for higher limits.

Every backend's markdown runs through a shared cleanup (`Markdown.clean`):
decorative symbol noise — the long, letter-free, repetitive character
streams some pages render as animated backgrounds or section dividers — is
stripped, and whitespace is normalized. The filter is conservative: code
blocks, tables, headings, blockquotes, inline code, and short ASCII-art
fragments always survive. Tunable via `Ask::WebFetch::NoiseFilter.filter(
markdown, min_length:, max_entropy:)`.

The tool falls back automatically: if Crawl4AI is absent or fails, Local is
tried (blocked, timeout, non-HTML, anti-bot challenge, or a JS page with no
server-side content), then Jina. If every backend fails (rate limit, access
error, challenge page), the call returns a failure result listing each
backend's error.

### Self-hosted Crawl4AI

[Crawl4AI](https://docs.crawl4ai.com) runs as its own Docker service — the
same self-hosted pattern as ask-web-search's SearXNG:

```sh
docker run -d --name crawl4ai -p 11235:11235 unclecode/crawl4ai:latest
```

```ruby
# lib/ask/web_fetch/backends/crawl4ai.rb is used automatically when:
ENV["CRAWL4AI_URL"]  = "http://localhost:11235"  # default when unset
ENV["CRAWL4AI_TOKEN"] = "..."                    # JWT-protected servers (0.9+)
```

When `CRAWL4AI_URL` is set the default chain is
`Crawl4Ai, Local, Jina`; otherwise it stays `Local, Jina`, so consumers
without a Crawl4AI service see no behavior change.

### Adding a backend

Backends subclass `Ask::WebFetch::Backend` and implement one method:

```ruby
class MyBackend < Ask::WebFetch::Backend
  def fetch(url)
    # return { title: "Page Title", content: "markdown..." }
    # or raise Ask::WebFetch::FetchError / EmptyContentError
  end
end

Ask::Tools::WebFetch.backends = [MyBackend, Ask::WebFetch::Backends::Local]
```

`#fetch` must return `{ title: String|nil, content: String }` and raise
`Ask::WebFetch::FetchError` (hard failure) or `EmptyContentError` (page
fetched but nothing usable). Run the returned markdown through
`Ask::WebFetch::Markdown.clean` (backends that convert HTML get this from
`Markdown.generate`; backends fed pre-converted markdown must call it
explicitly) so the shared noise removal and whitespace normalization apply
everywhere. The chain then handles ordering and fallback for you. For
tests, `Ask::Tools::WebFetch.backends = [...]` can be swapped and
restored.

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

- `CRAWL4AI_URL` — enables the self-hosted Crawl4AI backend and leads the
  chain (default `http://localhost:11235` when set via the class accessor)
- `CRAWL4AI_TOKEN` — Bearer token for JWT-protected Crawl4AI servers (0.9+)
- `JINA_API_KEY` — enables the Jina fallback with higher rate limits
- `max_chars` parameter — caps output length (default 20000)

## Known limitations

- Pages rendered entirely client-side (JavaScript SPAs) may yield little or
  no content unless Crawl4AI is configured — set `CRAWL4AI_URL` to handle
  them with a self-hosted renderer.
- Some sites block non-browser requests regardless of User-Agent.
- Symbol streams that a converter merges *into* a content line (rather
  than leaving them as their own lines) are out of scope for the
  markdown-level NoiseFilter — that would need a DOM-level pass.

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
