## [0.1.0] — 2026-08-04

### Added

- Initial release: `Ask::Tools::WebFetch`, a tool that fetches a URL and
  converts its content to clean markdown for LLM consumption.
- Pure Ruby pipeline (Net::HTTP + Nokogiri + reverse_markdown) with no
  external service or API key required.
- Redirect following, non-HTML response detection, main-content extraction,
  navigation-chrome stripping, and `max_chars` truncation.
