## [0.3.1] — 2026-08-07

### Fixed

- Crawl4AI backend read timeout raised 30s → 90s: headless-browser rendering
  (plus first-request pool warmup) is far slower than plain-HTML fetches,
  and the crawl itself gets `crawler_config.timeout` of 60s — the HTTP read
  must allow that plus headroom. Without this, real crawls hit
  `Net::ReadTimeout` and fell through to Local.

## [0.3.0] — 2026-08-07

### Added

- `Ask::WebFetch::Backends::Crawl4Ai`: self-hosted Crawl4AI backend
  (headless-Chromium renderer that handles JavaScript pages and returns
  clean markdown). Talks to the Crawl4AI server's `POST /crawl` endpoint,
  configured via `CRAWL4AI_URL` (default `http://localhost:11235`) with
  optional `CRAWL4AI_TOKEN` for JWT-protected servers.
- Config-aware chain: the default backend chain is now
  `Crawl4Ai, Local, Jina` when `CRAWL4AI_URL` is set — Crawl4AI leads when
  present, falls through to Local when it's down or unreachable, Jina stays
  the last resort. Consumers without Crawl4AI configured see the previous
  `Local, Jina` behavior unchanged.

## [0.2.0] — 2026-08-04

### Added

- Pluggable backend architecture: `Ask::WebFetch::Backend` contract plus a
  fallback chain in `Ask::Tools::WebFetch.backends` (default
  `Local, Jina`). New backends slot in as one subclass + one array entry.
- `Ask::WebFetch::Backends::Jina`: Jina Reader free tier
  (`https://r.jina.ai/<url>`), with optional `JINA_API_KEY` for higher rate
  limits. Handles pages the local fetcher can't (JS-rendered, some
  anti-bot).
- Automatic fallback: the tool tries backends in order and returns the
  first success. Local failures detected via non-2xx, network errors,
  non-HTML responses, anti-bot challenge pages, and empty/thin extraction
  (JS shells). Jina failures detected via rate limits (429), access errors
  (401/403), and challenge pages.
- Programmatic backend override for tests and future backends:
  `Ask::Tools::WebFetch.backends = [MyBackend]`.

### Changed

- `Ask::Tools::WebFetch` delegates fetching to backends instead of doing
  all work inline; behavior for normally-readable pages is unchanged.

## [0.1.0] — 2026-08-04

### Added

- Initial release: `Ask::Tools::WebFetch`, a tool that fetches a URL and
  converts its content to clean markdown for LLM consumption.
- Pure Ruby pipeline (Net::HTTP + Nokogiri + reverse_markdown) with no
  external service or API key required.
- Redirect following, non-HTML response detection, main-content extraction,
  navigation-chrome stripping, and `max_chars` truncation.
