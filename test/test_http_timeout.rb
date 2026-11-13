# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../lib/k9o'

# The read timeout a request is sent with: 120 s, as in the Python SDK, so a long call
# (Rampart `classify` on a long input runs up to about 20 s) is not cut off.
class HttpTimeoutTest < Minitest::Test
  FakeResponse = Struct.new(:code, :body)

  class FakeHttp
    attr_reader :timeouts
    attr_accessor :use_ssl, :read_timeout

    def initialize
      @timeouts = []
    end

    def request(_req)
      @timeouts << read_timeout
      FakeResponse.new('200', '{"data":{"crypts":[]},"meta":{}}')
    end
  end

  def test_requests_use_a_120_second_read_timeout
    fake = FakeHttp.new
    c = K9o.create_client(base_url: 'https://acme.api.k9o.io', project_slug: 'portal', http_client: fake)
    c.crypto.crypts_list
    # The first request may be the region probe (30 s, region.rb); the call itself is the last one.
    assert_equal 120, fake.timeouts.last
    assert_equal 120, K9o::HttpTransport::DEFAULT_READ_TIMEOUT
  end
end
