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
