## [0.4.1] — 2026-08-08

### Fixed

- `ContentFilter` now excludes `<svg>` elements outright. Chart SVG text was
  leaking into the markdown as concatenated axis labels ("01M2M3M",
  "10Apr15Apr", "025K50K") on chart-heavy pages like the patronview bot
  article. crawl4ai's excluded-tags list omits `svg`; the pipeline's
  region-based scrub already dropped it, and the filter now matches.

## [0.4.0] — 2026-08-08

### Added

- `Ask::WebFetch::ContentFilter`: density-based content pruning ported from
  crawl4ai's `PruningContentFilter` (Apache-2.0). Scores every element on
  text density, link density, semantic tag weight, class/id chrome penalty,
  and text length, then removes elements below an adaptive threshold — the
  "fit" content survives, chrome and link-farms go. Includes
  `preserve_classes`/`preserve_tags` whitelists. Deliberate deviations from
  crawl4ai (documented in code): weights for `main`/table/`pre`/`code` that
  crawl4ai's tag table omits, a class/id penalty that actually subtracts,
  and correct `URI.join` semantics for relative URLs.
- `Ask::WebFetch::Markdown`: the shared HTML→markdown pipeline (extracted
  from Local), with crawl4ai's link-to-citation conversion ported — inline
  links become numbered `⟨N⟩` citations plus a deduplicated `## References`
  section, optionally (`citations: true`).
- `Ask::WebFetch::Backends::Browser`: real-Chrome backend via Ferrum.
  Renders JavaScript (SPAs, client-side pages) and lets Cloudflare-style
  managed challenges that auto-solve complete themselves. Two modes:
  *Launched* — a fresh headless Chrome (default when a binary is found;
  configure with `ASK_WEB_FETCH_CHROME_PATH`, persistent profile with
  `ASK_WEB_FETCH_PROFILE`). *Attached* — drives an already-running Chrome
  over CDP (`ASK_WEB_FETCH_CDP_URL`, e.g. `http://127.0.0.1:9222`), a
  trusted context with a mature profile and earned cookies, so sites whose
  invisible challenges soft-block fresh automation browsers load normally.
  Appended to the backend chain when either is configured.
- New runtime dependency: `ferrum`.

### Changed

- `Local` now converts through `Ask::WebFetch::Markdown` with the default
  adaptive `ContentFilter`, so the returned content is pruned by text
  density rather than by keyword matching.
- Backend chain becomes `Local, Jina, Browser` when a Chrome binary or CDP
  endpoint is present (Browser last — it is the slowest).

### Fixed

- Meta description extraction (`meta name=description`, then
  `og:description`) for Local and Crawl4AI backends, alongside title and
  content.
- Page content is measured with inter-tag whitespace stripped, matching
  BeautifulSoup's `get_text(strip=True)` that crawl4ai uses — bare end
  stripping inflated the density metrics and kept link-farms alive.

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
