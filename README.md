# ask-web-fetch

[![Gem Version](https://badge.fury.io/rb/ask-web-fetch.svg)](https://badge.fury.io/rb/ask-web-fetch)

A web fetch tool for the ask-rb ecosystem. It provides
`Ask::Tools::WebFetch`, which fetches a URL and returns its content as clean
markdown for LLM consumption. It has no Rails dependencies, no external
service, and no API key required — pure Ruby (`Net::HTTP` + Nokogiri +
reverse_markdown).

## How it works

1. `Net::HTTP` GET with a browser-like User-Agent (redirects followed, up to 5)
2. Nokogiri parses the HTML and picks the main content
   (`<article>` → `<main>` → `<body>`)
3. Navigation, scripts, and other chrome are stripped
4. reverse_markdown converts the content to markdown (tables become markdown
   tables, links become `[text](url)`)
5. Output is truncated to `max_chars` (default 20000)

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

If the page has no readable content, returns
`"No readable content found at <url>."`

## Configuration

No configuration required. The only knob is the optional `max_chars`
parameter.

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
