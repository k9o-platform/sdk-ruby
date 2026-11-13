# frozen_string_literal: true

require 'minitest/autorun'
require 'minitest/mock'
require 'json'
require_relative '../lib/k9o'

# The locate door: sign-in asks the project which region holds the address, and sends the password only to an origin
# that passes the rule in K9o::Locate. Same cases as packages/gate/test/locate.test.ts.
class LocateTest < Minitest::Test
  BASE = 'https://acme.api-de01.k9o.io'

  # --- the pure rule ------------------------------------------------------------------------------------------------

  def choose(base, answer)
    K9o::Locate.choose_origin(base, answer)
  end

  def test_uses_a_sibling_region_of_the_same_org_family_and_apex
    assert_equal 'https://acme.api-us01.k9o.io',
                 choose(BASE, { 'region' => 'us01', 'origin' => 'https://acme.api-us01.k9o.io' })
  end

  def test_uses_the_bases_own_region
    assert_equal BASE, choose(BASE, { 'region' => 'de01', 'origin' => BASE })
  end

  def test_uses_an_origin_with_a_trailing_slash
    assert_equal 'https://acme.api-us01.k9o.io',
                 choose(BASE, { 'region' => 'us01', 'origin' => 'https://acme.api-us01.k9o.io/' })
  end

  REFUSED = {
    'null origin (single host, self-hosted)' => { 'region' => 'de01', 'origin' => nil },
    'a missing answer' => nil,
    'http' => { 'region' => 'us01', 'origin' => 'http://acme.api-us01.k9o.io' },
    'userinfo' => { 'region' => 'us01', 'origin' => 'https://u:p@acme.api-us01.k9o.io' },
    'a port' => { 'region' => 'us01', 'origin' => 'https://acme.api-us01.k9o.io:8443' },
    'a path' => { 'region' => 'us01', 'origin' => 'https://acme.api-us01.k9o.io/x' },
    'a query' => { 'region' => 'us01', 'origin' => 'https://acme.api-us01.k9o.io/?a=1' },
    'another org' => { 'region' => 'us01', 'origin' => 'https://evil.api-us01.k9o.io' },
    'another apex' => { 'region' => 'us01', 'origin' => 'https://acme.api-us01.evil.io' },
    'another family' => { 'region' => 'us01', 'origin' => 'https://acme.api-staging-us01.k9o.io' },
    'a code that differs from region' => { 'region' => 'us01', 'origin' => 'https://acme.api-fr01.k9o.io' },
    'a region that is not a code' => { 'region' => 'usa', 'origin' => 'https://acme.api-usa.k9o.io' },
    'a host with no region' => { 'region' => 'us01', 'origin' => 'https://acme.api.k9o.io' },
    'a region as a subdomain' => { 'region' => 'us01', 'origin' => 'https://us01.acme.api-de01.k9o.io' },
    'a look-alike apex' => { 'region' => 'us01', 'origin' => 'https://acme.api-us01.k9o.io.evil.io' },
    'a fragment' => { 'region' => 'us01', 'origin' => 'https://acme.api-us01.k9o.io/#x' },
    'a non-string origin' => { 'region' => 'us01', 'origin' => 5 },
    'an unparseable origin' => { 'region' => 'us01', 'origin' => 'https://acme api-us01.k9o.io' }
  }.freeze

  REFUSED.each do |name, answer|
    define_method("test_falls_back_to_the_base_for_#{name.gsub(/\W+/, '_')}") do
      assert_equal BASE, choose(BASE, answer)
    end
  end

  def test_allows_http_only_when_the_base_is_http_on_loopback_and_then_only_the_same_host
    assert_equal 'http://localhost:8080',
                 choose('http://localhost:8080', { 'region' => 'de01', 'origin' => 'http://localhost:8080' })
    assert_equal 'http://localhost:8080',
                 choose('http://localhost:8080', { 'region' => 'de01', 'origin' => 'http://evil.localhost:8080' })
    assert_equal 'https://localhost',
                 choose('https://localhost', { 'region' => 'de01', 'origin' => 'http://localhost' })
  end

  def test_uses_the_base_when_the_base_is_not_a_gateway_host_shape
    assert_equal 'https://gw.internal.example',
                 choose('https://gw.internal.example', { 'region' => 'us01', 'origin' => 'https://gw-us01.internal.example' })
  end

  # --- the flow -----------------------------------------------------------------------------------------------------

  Resp = Struct.new(:code, :body, :headers) do
    def [](key)
      headers[key.to_s.downcase]
    end
  end
  Seen = Struct.new(:method, :url, :body, :headers)

  # Answers by URL; records every request with the host it was built for.
  class Harness
    attr_reader :seen

    def initialize(answer)
      @answer = answer
      @seen = []
    end

    def http_for(host, port)
      Conn.new(self, host, port)
    end

    def record(host, port, req)
      url = "https://#{host}#{port == 443 ? '' : ":#{port}"}#{req.path}"
      @seen << Seen.new(req.method, url, req.body ? JSON.parse(req.body) : nil, req.each_header.to_h)
      @answer.call(url)
    end

    def urls
      @seen.map(&:url)
    end
  end

  class Conn
    attr_accessor :use_ssl, :read_timeout

    def initialize(harness, host, port)
      @harness = harness
      @host = host
      @port = port
    end

    def request(req)
      @harness.record(@host, @port, req)
    end
  end

  SESSION = { 'accessToken' => 'a', 'refreshToken' => 'r-1', 'expiresAt' => 'x', 'refreshExpiresAt' => 'x' }.freeze
  AUTH_RESULT = { 'user' => { 'id' => 'eu_1' }, 'session' => SESSION }.freeze

  def json(status, body)
    Resp.new(status.to_s, JSON.dump(body), {})
  end

  def with_harness(answer)
    h = Harness.new(answer)
    Net::HTTP.stub(:new, ->(host, port = 80, *) { h.http_for(host, port) }) do
      client = K9o.create_client(base_url: BASE, project_slug: 'portal', api_key: 'secret-key',
                                 default_headers: { 'x-extra' => '1', 'cookie' => 'a=b' })
      yield h, client
    end
  end

  def door(region, origin)
    json(200, { 'data' => { 'region' => region, 'origin' => origin }, 'meta' => {} })
  end

  def test_sends_only_the_email_to_the_door_then_the_password_to_the_located_origin
    with_harness(->(u) { u.end_with?('/gate/locate') ? door('us01', 'https://acme.api-us01.k9o.io') : json(200, { 'data' => AUTH_RESULT, 'meta' => {} }) }) do |h, c|
      c.gate.sign_in(email: 'a@b.co', password: 'pw')
      assert_equal ["#{BASE}/@portal/gate/locate", 'https://acme.api-us01.k9o.io/@portal/gate/signin'], h.urls
      assert_equal({ 'email' => 'a@b.co' }, h.seen[0].body)
      keys = h.seen[0].headers.keys.map(&:downcase)
      refute_includes keys, 'authorization'
      refute_includes keys, 'cookie'
      assert_equal({ 'email' => 'a@b.co', 'password' => 'pw' }, h.seen[1].body)
    end
  end

  def test_never_sends_the_password_to_an_origin_that_fails_the_rule
    with_harness(->(u) { u.end_with?('/gate/locate') ? door('us01', 'https://evil.example') : json(200, { 'data' => AUTH_RESULT, 'meta' => {} }) }) do |h, c|
      c.gate.sign_in(email: 'a@b.co', password: 'pw')
      assert_equal "#{BASE}/@portal/gate/signin", h.urls[1]
      refute(h.urls.any? { |u| u.include?('evil.example') })
    end
  end

  def test_uses_the_base_when_the_door_answers_origin_null
    with_harness(->(u) { u.end_with?('/gate/locate') ? door('de01', nil) : json(200, { 'data' => AUTH_RESULT, 'meta' => {} }) }) do |h, c|
      c.gate.sign_in(email: 'a@b.co', password: 'pw')
      assert_equal "#{BASE}/@portal/gate/signin", h.urls[1]
    end
  end

  def test_uses_the_base_when_the_door_answers_a_malformed_body
    with_harness(->(u) { u.end_with?('/gate/locate') ? Resp.new('200', 'not json', {}) : json(200, { 'data' => AUTH_RESULT, 'meta' => {} }) }) do |h, c|
      c.gate.sign_in(email: 'a@b.co', password: 'pw')
      assert_equal "#{BASE}/@portal/gate/signin", h.urls[1]
    end
  end

  def test_sends_nothing_to_sign_in_when_the_door_is_down_or_rate_limited_and_raises_the_doors_error
    [[503, 'K9O_GATE_REGION_UNAVAILABLE'], [429, 'K9O_RATE_LIMITED']].each do |status, code|
      with_harness(->(_) { json(status, { 'code' => code, 'message' => 'x', 'context' => {}, 'recommendation' => nil }) }) do |h, c|
        e = assert_raises(K9o::KError) { c.gate.sign_in(email: 'a@b.co', password: 'pw') }
        assert_equal code, e.code
        assert_equal 1, h.seen.length
      end
    end
  end

  def err(status, code)
    json(status, { 'code' => code, 'message' => 'x', 'context' => {}, 'recommendation' => nil })
  end

  def test_uses_the_base_when_the_door_answers_404
    with_harness(->(u) { u.end_with?('/gate/locate') ? err(404, 'K9O_NOT_FOUND') : json(200, { 'data' => AUTH_RESULT, 'meta' => {} }) }) do |h, c|
      out = c.gate.sign_in(email: 'a@b.co', password: 'pw')
      assert_equal ["#{BASE}/@portal/gate/locate", "#{BASE}/@portal/gate/signin"], h.urls
      assert_equal 'r-1', out.data['session']['refreshToken']
    end
  end

  def test_still_raises_when_the_door_answers_429_or_503_and_sends_no_credential
    [429, 503].each do |status|
      with_harness(->(_) { err(status, status == 429 ? 'K9O_RATE_LIMITED' : 'K9O_GATE_REGION_UNAVAILABLE') }) do |h, c|
        e = assert_raises(K9o::KError) { c.gate.sign_in(email: 'a@b.co', password: 'pw') }
        assert_equal status, e.status
        assert_equal ["#{BASE}/@portal/gate/locate"], h.urls
      end
    end
  end

  def test_does_not_absorb_a_404_from_the_sign_in_request_itself
    with_harness(->(u) { u.end_with?('/gate/locate') ? err(404, 'K9O_NOT_FOUND') : err(404, 'K9O_GATE_USER_NOT_FOUND') }) do |h, c|
      e = assert_raises(K9o::KError) { c.gate.sign_in(email: 'a@b.co', password: 'pw') }
      assert_equal 'K9O_GATE_USER_NOT_FOUND', e.code
      assert_equal 404, e.status
      assert_equal ["#{BASE}/@portal/gate/locate", "#{BASE}/@portal/gate/signin"], h.urls
    end
  end

  def test_does_not_cache_the_located_origin_the_next_sign_in_asks_again
    n = 0
    h_answer = lambda do |u|
      if u.end_with?('/gate/locate')
        n += 1
        door(n == 1 ? 'us01' : 'fr01', n == 1 ? 'https://acme.api-us01.k9o.io' : 'https://acme.api-fr01.k9o.io')
      else
        json(200, { 'data' => AUTH_RESULT, 'meta' => {} })
      end
    end
    with_harness(h_answer) do |h, c|
      c.gate.sign_in(email: 'a@b.co', password: 'pw')
      c.gate.sign_in(email: 'a@b.co', password: 'pw')
      assert_equal 2, h.urls.count { |u| u.end_with?('/gate/locate') }
      assert_equal ['https://acme.api-us01.k9o.io/@portal/gate/signin', 'https://acme.api-fr01.k9o.io/@portal/gate/signin'],
                   h.urls.select { |u| u.end_with?('/signin') }
    end
  end

  def test_sends_refresh_and_sign_out_to_the_origin_that_issued_the_session
    answer = lambda do |u|
      if u.end_with?('/gate/locate') then door('us01', 'https://acme.api-us01.k9o.io')
      else json(200, { 'data' => u.end_with?('/signin') ? AUTH_RESULT : { 'revoked' => true }, 'meta' => {} })
      end
    end
    with_harness(answer) do |h, c|
      c.gate.sign_in(email: 'a@b.co', password: 'pw')
      c.gate.refresh_token(refresh_token: 'r-1')
      c.gate.sign_out(refresh_token: 'r-1')
      assert_includes h.urls, 'https://acme.api-us01.k9o.io/@portal/gate/refresh'
      assert_includes h.urls, 'https://acme.api-us01.k9o.io/@portal/gate/signout'
      c.gate.refresh_token(refresh_token: 'r-1')
      assert_equal "#{BASE}/@portal/gate/refresh", h.urls.last
    end
  end

  def test_refresh_rotates_the_refresh_token_and_the_hint_follows_it
    answer = lambda do |u|
      if u.end_with?('/gate/locate') then door('us01', 'https://acme.api-us01.k9o.io')
      elsif u.end_with?('/signin') then json(200, { 'data' => AUTH_RESULT, 'meta' => {} })
      else json(200, { 'data' => { 'accessToken' => 'a2', 'refreshToken' => 'r-2', 'expiresAt' => 'x' }, 'meta' => {} })
      end
    end
    with_harness(answer) do |h, c|
      c.gate.sign_in(email: 'a@b.co', password: 'pw')
      out = c.gate.refresh_token(refresh_token: 'r-1')
      assert_equal 'r-2', out.data['refreshToken']
      c.gate.refresh_token(refresh_token: 'r-2')
      assert_equal ['https://acme.api-us01.k9o.io/@portal/gate/refresh'] * 2, h.urls.select { |u| u.end_with?('/refresh') }
      c.gate.sign_out(refresh_token: 'r-1') # the old secret has no hint any more
      assert_equal "#{BASE}/@portal/gate/signout", h.urls.last
    end
  end

  %w[replay revoked inactive max_length].each do |reason|
    define_method("test_a_refused_refresh_carries_the_session_expired_reason_#{reason}") do
      body = { 'code' => 'K9O_SESSION_EXPIRED', 'message' => 'The session has ended.', 'context' => { 'reason' => reason } }
      with_harness(->(_u) { json(401, body) }) do |_h, c|
        e = assert_raises(K9o::KError) { c.gate.refresh_token(refresh_token: 'r-1') }
        assert_equal 'K9O_SESSION_EXPIRED', e.code
        assert_equal 401, e.status
        assert_equal reason, e.context['reason']
      end
    end
  end

  def test_revoke_all_sessions_posts_with_the_bearer_and_returns_the_count
    with_harness(->(_) { json(200, { 'data' => { 'revokedCount' => 3 }, 'meta' => {} }) }) do |h, c|
      out = c.gate.revoke_all_sessions
      assert_equal 3, out.data['revokedCount']
      assert_equal 1, h.seen.size
      assert_equal 'POST', h.seen[0].method
      assert_equal "#{BASE}/@portal/auth/sessions/revoke-all", h.seen[0].url
      assert_nil h.seen[0].body
      assert_equal 'Bearer secret-key', h.seen[0].headers.transform_keys(&:downcase)['authorization']
    end
  end

  %w[K9O_TRUST_ZONE_VIOLATION K9O_PROJECT_SCOPE_MISMATCH].each do |code|
    define_method("test_revoke_all_sessions_refusal_#{code.downcase}_is_a_kerror") do
      body = { 'code' => code, 'message' => 'refused', 'context' => {} }
      with_harness(->(_u) { json(403, body) }) do |_h, c|
        e = assert_raises(K9o::KError) { c.gate.revoke_all_sessions }
        assert_equal code, e.code
        assert_equal 403, e.status
      end
    end
  end

  def test_the_hint_map_is_bounded
    70.times { |i| K9o::Locate.remember("rt-#{i}", 'https://acme.api-us01.k9o.io') }
    assert_nil K9o::Locate.hint('rt-0')
    assert_equal 'https://acme.api-us01.k9o.io', K9o::Locate.hint('rt-69')
    assert_operator K9o::Locate::HINTS.size, :<=, 64
  end

  def test_sign_up_and_whoami_do_not_use_the_door
    with_harness(->(_) { json(200, { 'data' => AUTH_RESULT, 'meta' => {} }) }) do |h, c|
      c.gate.sign_up(email: 'a@b.co', password: 'pw-long-enough-1')
      c.gate.whoami
      refute(h.urls.any? { |u| u.end_with?('/locate') })
    end
  end
end
