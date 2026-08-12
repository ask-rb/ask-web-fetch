# frozen_string_literal: true

require_relative '../test_helper'

# The shared page guard contract: EVERY backend runs guard_page! after
# extraction, before returning. The verdicts (parked -> ParkedDomainError,
# empty -> EmptyContentError) live here once, so a new backend cannot
# accidentally treat a parked domain as content.
describe Ask::WebFetch::Backend do
  let(:backend) { Ask::WebFetch::Backend.new }
  let(:usable) { 'Real page content that clears the minimum length bar. ' * 5 }

  it 'rejects a parked domain from the raw HTML (Local/Browser seam)' do
    body = '<html><head><script>window.LANDER_SYSTEM="PW";</script></head><body>ad</body></html>'

    _(-> { backend.guard_page!('https://parked.test', usable, raw_body: body) })
      .must_raise Ask::WebFetch::ParkedDomainError
  end

  it 'rejects a parked domain from the rendered text (Jina/Crawl4AI seam)' do
    content = "example.com is parked free, courtesy of GoDaddy.com\n\n#{usable}"

    _(-> { backend.guard_page!('https://parked.test', content) })
      .must_raise Ask::WebFetch::ParkedDomainError
  end

  it 'rejects the ad before the content minimum (puncta.ai shape)' do
    # A parking page can render ABOVE the minimum (puncta.ai: 395c of
    # Namecheap auction ads) — the parked verdict must win anyway, so the
    # marker check runs before the content minimum.
    content = "example.com is parked free, courtesy of GoDaddy.com\n\n#{usable}"

    _(-> { backend.guard_page!('https://parked.test', content) })
      .must_raise Ask::WebFetch::ParkedDomainError
  end

  it 'raises EmptyContentError for content below the minimum' do
    _(-> { backend.guard_page!('https://example.test', 'tiny') })
      .must_raise Ask::WebFetch::EmptyContentError
  end

  it 'passes usable content through' do
    result = backend.guard_page!('https://example.test', usable)

    _(result).must_be_nil
  end

  it 'uses the same message everywhere' do
    error = assert_raises(Ask::WebFetch::ParkedDomainError) do
      backend.guard_page!('https://parked.test', 'example.com is parked free, courtesy of GoDaddy.com')
    end

    _(error.message).must_equal 'parked domain at https://parked.test — registrar parking page, not site content'
  end
end
