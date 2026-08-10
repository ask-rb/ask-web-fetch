# frozen_string_literal: true

require_relative 'lib/ask/web_fetch/version'

Gem::Specification.new do |spec|
  spec.name = 'ask-web-fetch'
  spec.version = Ask::WebFetch::VERSION
  spec.authors = ['Kaka Ruto']
  spec.email = ['kaka@myrrlabs.com']

  spec.summary = 'Web fetch tool for the ask-rb ecosystem'
  spec.description = 'Provides Ask::Tools::WebFetch, a tool that fetches a URL ' \
                     'and converts its content to clean markdown for LLM ' \
                     'consumption. Defaults to a pure Ruby backend (httpx + ' \
                     'Nokogiri + reverse_markdown) with a Jina Reader fallback ' \
                     'for JS-rendered or blocked pages, and a real-Chrome ' \
                     'fallback (Ferrum) that renders JavaScript and lets ' \
                     'auto-solving Cloudflare challenges complete. Works with ' \
                     'any ask-rb chat or agent.'
  spec.homepage = 'https://github.com/ask-rb/ask-web-fetch'
  spec.license = 'MIT'

  spec.required_ruby_version = '>= 3.2'

  spec.metadata['homepage_uri'] = spec.homepage
  spec.metadata['source_code_uri'] = spec.homepage
  spec.metadata['changelog_uri'] = "#{spec.homepage}/blob/master/CHANGELOG.md"
  spec.metadata['rubygems_mfa_required'] = 'true'

  spec.files = Dir['lib/**/*', 'LICENSE', 'README.md']
  spec.require_paths = ['lib']

  spec.add_dependency 'ask-tools', '>= 0.1'
  spec.add_dependency 'ferrum', '>= 0.14'
  spec.add_dependency 'httpx', '>= 1.0'
  spec.add_dependency 'nokogiri', '>= 1.15'
  spec.add_dependency 'reverse_markdown', '>= 2.0'

  spec.add_development_dependency 'minitest', '~> 5.25'
  spec.add_development_dependency 'rake', '~> 13.0'
  spec.add_development_dependency 'webmock', '~> 3.26'
end
