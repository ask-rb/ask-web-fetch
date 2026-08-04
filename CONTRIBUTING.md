# Contributing to ask-web-fetch

## Development Setup

```bash
git clone <repo-url> && cd ask-rb/ask-web-fetch
bundle install
```

### Local Dependencies

Sibling gems (ask-core, ask-tools, etc.) are loaded from their local `lib/` directories
in the monorepo during development. The `test_helper.rb` in each gem handles this
via `$LOAD_PATH` manipulation.

## Running Tests

```bash
# Run all tests
bundle exec rake test

# Run a single test file
bundle exec ruby -Ilib -Itest test/foo_test.rb

# Run with verbose output
bundle exec rake test TESTOPTS="--verbose"
```

## Code Style

- Follow the existing code style in the gem you're modifying
- Use `# frozen_string_literal: true` in all Ruby files
- Run `rubocop -a` if the gem has RuboCop configured

## Pull Request Guidelines

1. Keep PRs focused on a single concern
2. Include tests for new functionality
3. Update CHANGELOG.md with your changes
4. Ensure all existing tests pass
5. Open an issue first for new features or significant changes

## Testing Philosophy

- Each gem is small and focused on a single concern
- Tests should respect gem boundaries — don't test dependencies
- Don't duplicate coverage already provided by upstream gems
- Test the public API, not internal implementation details
- Edge cases matter: nil inputs, empty strings, timeouts, concurrent access

## Release

See RELEASE.md for the release process.

## Gem Boundary

This gem is focused on web fetch.

Tests must respect this boundary — test the gem's own code, not its
dependencies' behavior. Mock external services, don't call them.
