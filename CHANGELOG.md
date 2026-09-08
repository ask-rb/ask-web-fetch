## [0.7.5] — 2026-09-09

### Added

- **Structured error classes with HTTP status.** `FetchError` and
  `ServerError` now carry an `#status` attribute (the HTTP status code
  when the server returned one). `NotFoundError` is a new subclass of
  `FetchError` for 404 responses — distinct from generic fetch failures
  so callers can handle "page doesn't exist" separately.
- **404 pages with content are served.** Custom error pages that carry
  usable content (navigation, search suggestions, related links) are now
  returned instead of raising immediately. Only genuinely empty 404 pages
  raise `NotFoundError`.
- **Cleaner collapse messages.** When all backends report the same HTTP
  status, the error message shows `[status] url` instead of listing
  every backend's echo of the same problem.
- **Agent-native content negotiation.** The Local backend probes with
  `Accept: text/markdown` before scraping HTML, and tries the `.md`
  URL twin (Mintlify/Docusaurus pattern) as a second probe. Sites that
  speak markdown natively get clean content without DOM conversion.
- **Turnstile false-positive fix.** `cf-chl-widget` (Turnstile form
  widget) is no longer misclassified as the Cloudflare managed challenge
  interstitial. `challenge-platform` and `_cf_chl_opt` are now detected
  for better interstitial coverage.
- **Dead browser recovery.** `Browser.reset_browser` clears the shared
  browser instance on `Ferrum::DeadBrowserError`, and `fetch` retries
  once instead of failing.

### Changed

- `CHALLENGE_RE` expanded to include `challenge-platform` and
  `_cf_chl_opt` for better Cloudflare interstitial detection.
- `SHELL_DEFER_THRESHOLD` added for JS-app shell detection (previously
  used `SHELL_CONTENT_THRESHOLD` which was too aggressive).

## [0.7.1] — 2026-08-12

### Added

- **The native agent tool is back — as an optional integration.**
  `Ask::Tools::WebFetch` returns: a thin `Ask::Tool` adapter over the
  library (chain config and the fetch itself delegate to
  `Ask::WebFetch`), registered in the `Ask::Tools` registry for agent
  frameworks that resolve tools by name (ask-agent's `tool: :web_fetch`,
  ask-app-server, llm-proxy). It loads and registers **only when
  ask-tools is present** (a LoadError-guarded require in the library's
  entry file), so the library still works standalone and backend-only
  consumers — crawlers, pipelines — pay nothing for it. Agent frameworks
  all ship ask-tools, so their users get the tool with no extra step.
  ask-tools is a development dependency of the gem, never a runtime one.

## [0.7.0] — 2026-08-12

### Changed

- **A library, not a tool.** `Ask::Tools::WebFetch` is gone and so is the
  `ask-tools` dependency (and with it `ask-core` + `ask-schema`). The
  capability lives at the module level:
  `Ask::WebFetch.fetch(url, max_chars:)` returns the LLM-ready markdown
  string, `Ask::WebFetch.fetch_page(url)` the raw page hash, and
  `Ask::WebFetch.collapse(failures, url)` the classed failure aggregate.
  The backend chain is configured with `Ask::WebFetch.backends` /
  `backends=`. Tool framing — name, parameter schema, result wrapping —
  is a consumer concern: ask-web-fetch-mcp owns the `ask_web_fetch` tool,
  and agents wrap the library the way they wrap any capability.

### Removed

- `Ask::Tools::WebFetch` (moved to ask-web-fetch-mcp as the `ask_web_fetch`
  tool), the `ask-tools` dependency, and the registry registration.

## [0.6.2] — 2026-08-12

### Changed

- **One shared page guard, every backend.** The parked-domain and
  empty-content verdicts (`ParkedDomainError` / `EmptyContentError`) were
  raised inline in all four backends at slightly different points with
  duplicated messages. They now live once, as
  `Backend#guard_page!(url, content, raw_body: nil)`, and every backend
  calls it at the same point in its flow — after extraction, before
  returning. Each backend passes the strings it has: `raw_body` where it
  saw raw HTML (Local, Browser — the HTML-only markers `ap:"parking"`,
  `parking-lander`, `LANDER_SYSTEM="PW"` live in scripts and assets that
  never survive conversion) and `content` everywhere (the prose markers
  survive conversion, so markdown-only backends reject the ad too).
  What is raised is unchanged everywhere, and the verdicts now read
  identically in the collapse detail (Jina's empty message became the
  same "no readable content at <url>" as the rest). A new backend cannot
  accidentally treat a parked domain as content: the contract is one
  method. 6 new contract tests, 208 green.

## [0.6.1] — 2026-08-12

### Fixed

- **Parked domains are rejected on EVERY backend, not just Local and
  Browser.** Jina and Crawl4AI render a registrar parking page fine — the
  GoDaddy/Namecheap ad came back as "content" when either led the chain
  (Crawl4AI leads the default chain when configured). Both now run the
  shared parked-domain detector (0.5.7) on the rendered markdown before
  returning it, raising `ParkedDomainError` like the converting backends.

## [0.6.0] — 2026-08-12

### Added

- **The tool's aggregate now collapses to the best error class**
  (`Ask::Tools::WebFetch.collapse(failures, url)`). Before, when every
  backend failed, the tool always raised the base `Error` — a parked
  domain, an empty page, or a dead 4xx all looked alike, and callers
  could not tell a terminal verdict from a transient one. Now the class
  carries the explanation, most definitive first: **ParkedDomainError**
  beats **EmptyContentError** beats a deterministic **FetchError**
  (every backend failed dead — 4xx/challenge), and any transient
  failure in the mix (timeout, 5xx, empty render) keeps the retryable
  base **Error**. The aggregate message still lists every backend and
  what it said.

## [0.5.9] — 2026-08-12

### Added

- **ParkedDomainError** — a distinct error class for registrar parking
  pages (GoDaddy/Namecheap ads), so the pipeline can classify a parked
  domain instead of treating it as generic empty content. Deterministic
  and terminal: retrying never turns a parking ad into content.

## [0.5.8] — 2026-08-12

### Added

- **Focus restore for the attached dev browser.** Creating a CDP tab
  steals focus to the Chrome window; on close, the previously frontmost
  app (captured before the tab was created, once per browser instance)
  is re-activated via osascript — macOS only, and never to Chrome
  itself (no ping-pong when the user is already looking at the debug
  browser). No-op everywhere else (prod is headless Linux).

## [0.5.7] — 2026-08-11

### Added

- **Parked-domain detection.** A parked (for-sale) domain serves a
  registrar ad, not site content — storing it as the site would
  silently under-deliver (observed live on the CC list: GoDaddy's
  parking-lander with ap:"parking" served after a JS redirect, and
  Namecheap's nc_market parking app). Both Local and Browser now
  reject parked pages with "parked domain" via a shared detector on
  the backend base; Browser catches the parked lander that only a JS
  redirect reaches.

## [0.5.6] — 2026-08-11

### Added

- **JS-shell completeness signal in the Local backend.** A client-
  rendered app whose server HTML renders little (airbnb: 613KB -> 143
  chars of markdown) was previously stored as a successful fetch — a
  truncated page silently under-delivering. Local now fails through
  with "JS-app shell" when it detects (a) known framework markers
  (React/Vue/Next/Nuxt footprints) or (b) a large HTML page with almost
  no server-rendered text, and extraction is below the shell threshold.
  The chain then prefers a rendering backend (Browser), and a partial
  page is never stored as the real thing. Server-rendered pages
  (nytimes, theverge) are unaffected.

## [0.5.5] — 2026-08-11

### Added

- **Warm-and-retry for challenge pages.** When the Browser backend hits
  a challenge page, it now visits the DOMAIN ROOT first (where a
  managed challenge auto-solves for a trusted browser), earning the
  domain's clearance cookie in the persistent profile, then retries the
  URL once. Subsequent fetches for that domain find the cookie and
  never warm again. Bounded: one warm per domain per process, one
  retry per fetch — a DataDome-class wall still fails fast, never
  wedging the queue.

## [0.5.4] — 2026-08-11

### Changed

- **Crawl4AI backend asks for stealth.** The service defaults to stealth
  OFF, so protected pages (Cloudflare/DataDome) were classified as
  blocked before the render finished. The crawl request now sends
  `enable_stealth: true` so the service attempts challenge pages.
  (simulate_user/magic are BrowserConfig fields and rejected on
  untrusted requests — stealth is the permitted lever.)

## [0.5.3] — 2026-08-11

### Fixed

- **Attached-browser idle wait was a no-op.** The Browser backend in
  CDP-attached mode never waited for the network to go quiet — lazy
  SPAs (reddit, npm) render their content in waves, and the fetch read
  only the first wave (1.9k of 12k chars). Real network-idle detection
  now tracks CDP Network events (requestWillBeSent / loadingFinished)
  on the page session, subscribed before navigation, and waits for
  quiet up to the idle timeout.

## [0.5.2] — 2026-08-11

### Fixed

- **No more hangs on multi-host crawls.** The Local backend transport
  used the httpx :persistent plugin, which in httpx 1.8.1 wedges forever
  inside the selector loop when a session that already holds a pooled
  connection opens one to a NEW host — the operation timeout never
  fires, and the fetch hangs indefinitely (reproduced in plain Ruby:
  example.com then nytimes.com on one session). Dropped `:persistent`
  for an explicit `:retries` plugin: a fresh connection per host, one
  TLS handshake per page, and never a hang. Regression-tested.

## [0.5.1] — 2026-08-11

### Added

- `Ask::WebFetch::NoiseFilter`: strips decorative symbol noise from
  converted markdown — the long, letter-free, repetitive character
  streams pages render as animated backgrounds, marquees and section
  dividers (e.g. Hugging Face's storage page ships a
  `+ = · ( ~ @ # % & * ? / : ; < > [ ] { } | ^ $ !` stream as its page
  background). Runs on markdown, so every backend benefits — the
  DOM-level ContentFilter never sees pre-converted markdown from Jina and
  Crawl4AI.

  Conservative by design: a line is dropped only when it is at least 32
  characters, contains no letters or digits, is repetitive (distinct
  chars/length below 0.3), and is not markdown structure — fenced or
  indented code, table rows and separators, headings, blockquotes, inline
  code, raw HTML and math all survive, as do short ASCII-art fragments
  and single-character dividers. Thresholds are tunable via
  `NoiseFilter.filter(markdown, min_length:, max_entropy:)`.

### Changed

- The `Jina` and `Crawl4AI` backends now run their returned markdown
  through the same `Markdown.clean` as the converting backends (Local,
  Browser), so noise removal and whitespace normalization are uniform
  across the whole chain; a page whose only content was noise now falls
  through as empty instead of passing. New backends must do the same —
  noted in the `Backend` base class contract.

## [0.5.0] — 2026-08-10

### Added

- `Ask::WebFetch::Http`: pooled keep-alive HTTP transport on httpx — one
  persistent session per thread (no fresh TCP+TLS handshake per request),
  HTTP/2 when the server negotiates it, retries with backoff on transient
  failures (network errors and 429/5xx), explicit connect/read/operation
  timeouts, and automatic gzip/deflate decoding. Every transport failure
  (timeout, refused, reset, DNS, TLS) surfaces as `TimeoutError` — TLS
  errors previously escaped as raw `OpenSSL` exceptions.
- Raw outlinks in every backend's page result: `outlinks` — the page's
  full `<a href>` set (nav and footer included), resolved and
  scheme-filtered. Shared `outlink_urls` (HTML backends) and
  `markdown_outlinks` (Jina, Crawl4AI) helpers on the base `Backend` keep
  every backend in sync, so a crawler's discovery layer reads the whole
  link set even when the stored content is pruned.
- Declared license signals in the Local backend's page result: `licenses`
  — `<link rel="license">`, license meta tags, and `[itemprop=license]`
  markers, as an empty array when the page declares none.

### Changed

- The `Local` backend fetches through the pooled `Ask::WebFetch::Http`
  transport instead of a fresh Net::HTTP connection per request.
  Redirect semantics, the error vocabulary, and the page contract are
  unchanged; an injectable seam (`Local.http =`) makes the transport
  swappable in tests and by future engines.
- New runtime dependency: `httpx`.

### Removed

- VCR cassette playback tests: VCR has no httpx hook, so they were
  silently hitting the live network. The seam-stubbed backend tests plus
  the new real-server `Http` tests (pooling, gzip decoding, retries,
  error mapping) cover the same contract. VCR dev-dependency dropped.

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
