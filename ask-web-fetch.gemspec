# frozen_string_literal: true

require_relative 'lib/ask/web_fetch/version'

Gem::Specification.new do |spec|
  spec.name = 'ask-web-fetch'
  spec.version = Ask::WebFetch::VERSION
  spec.authors = ['Kaka Ruto']
  spec.email = ['kaka@myrrlabs.com']

  spec.summary = 'Web fetch library for the ask-rb ecosystem'
  spec.description = 'Fetches a URL and converts its content to clean markdown for LLM ' \
                     'consumption. A pluggable backend chain: pure Ruby httpx + ' \
                     'Nokogiri + reverse_markdown by default, a Jina Reader fallback ' \
                     'for JS-rendered or blocked pages, and a real-Chrome fallback ' \
                     '(Ferrum) that renders JavaScript and lets auto-solving ' \
                     'Cloudflare challenges complete. The capability layer only — ' \
                     'tool framing (MCP servers, agent tools) is provided by the ' \
                     'consumers.'
  spec.homepage = 'https://github.com/ask-rb/ask-web-fetch'
  spec.license = 'MIT'

  spec.required_ruby_version = '>= 3.2'

  spec.metadata['homepage_uri'] = spec.homepage
  spec.metadata['source_code_uri'] = spec.homepage
  spec.metadata['changelog_uri'] = "#{spec.homepage}/blob/master/CHANGELOG.md"
  spec.metadata['rubygems_mfa_required'] = 'true'

  spec.files = Dir['lib/**/*', 'LICENSE', 'README.md']
  spec.require_paths = ['lib']

  spec.add_dependency 'ferrum', '>= 0.14'
  spec.add_dependency 'httpx', '>= 1.0'
  spec.add_dependency 'nokogiri', '>= 1.15'
  spec.add_dependency 'reverse_markdown', '>= 2.0'

  spec.add_development_dependency 'minitest', '~> 5.25'
  spec.add_development_dependency 'rake', '~> 13.0'
  spec.add_development_dependency 'webmock', '~> 3.26'
  # The native agent tool (Ask::Tools::WebFetch) is an optional runtime
  # integration — in the gem's own suite it is always present, so the
  # tool tests run; consumers decide at install time.
  spec.add_development_dependency 'ask-tools', '>= 0.1'
end
