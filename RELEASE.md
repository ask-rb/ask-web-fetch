# Release Process — ask-web-fetch

## Prerequisites

- All tests pass: `bundle exec rake test`
- CHANGELOG.md is updated with the release entries
- You have push access to rubygems.org

## Release Steps

1. Update the version in `lib/ask/web_fetch/version.rb`
2. Update CHANGELOG.md with the new version and date
3. Run tests: `bundle exec rake test`
4. Build: `bundle exec rake build`
5. Publish: `bundle exec rake release`

## Quick Reference

```bash
# Release
cd ask-web-fetch
bundle exec rake release
```

## VCR Cassette Policy (if applicable)

For gems that use VCR cassettes in tests:

- Always check cassettes for leaked API keys before committing
- Cassettes older than 30 days should be re-recorded before release
- To re-record: delete cassette files and run tests with API keys configured
