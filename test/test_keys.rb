# frozen_string_literal: true

require 'minitest/autorun'
require 'json'
require_relative '../lib/k9o'

# client.keys: list, get and rotate against a stubbed transport.
class KeysTest < Minitest::Test
  Resp = Struct.new(:code, :body, :headers) do
    def [](name)
      (headers || {})[name.downcase]
    end
  end

  class Stub
    attr_reader :reqs
    attr_accessor :use_ssl, :read_timeout

    def initialize(*answers)
      @answers = answers
      @reqs = []
    end

    def request(req)
      @reqs << req
      a = @answers.size > 1 ? @answers.shift : @answers.first
      Resp.new(a[0].to_s, a[1], a[2])
    end
  end

  KEY = { 'id' => 'vkey_5b0d', 'version' => 2, 'status' => 'active', 'custodyMode' => 'BYOK',
          'createdAt' => '2026-10-01T09:00:00.000Z', 'rotatedAt' => '2026-10-20T09:00:00.000Z',
          'byokRef' => { 'provider' => 'aws-kms', 'region' => 'eu-central-1', 'externalKeyFingerprint' => 'Zm9vYmFyYmF6cXV4' },
          'hyokRef' => nil }.freeze
  HYOK = KEY.merge('id' => 'vkey_77aa', 'custodyMode' => 'HYOK', 'byokRef' => nil,
                   'hyokRef' => { 'clusterId' => 'hsm_1', 'clusterName' => 'berlin-hsm', 'externalKeyFingerprint' => 'cXV4YmF6YmFyZm9v' }).freeze

  def env(data)
    [200, JSON.dump('data' => data, 'meta' => { 'context' => { 'requestId' => 'req_1' } })]
  end

  def err(status, code, context = {}, headers = {})
    [status, JSON.dump('code' => code, 'message' => 'no', 'context' => context), headers]
  end

  def client(*answers)
    @http = Stub.new(*answers)
    K9o.create_client(base_url: 'https://acme.api-de01.k9o.io', api_key: 'k', project_slug: 'portal', http_client: @http)
  end

  def target
    u = URI.parse("https://x#{@http.reqs.last.path}")
    [@http.reqs.last.method, u.path, URI.decode_www_form(u.query || '').to_h]
  end

  def test_list_default_and_status_all_and_no_cursor_is_exposed
    c = client(env('items' => [KEY], 'nextCursor' => nil))
    page = c.keys.list
    assert_equal ['GET', '/@portal/vault/keys', {}], target
    assert_equal [KEY], page.data['items']
    assert_equal ['items'], page.data.keys
    c.keys.list(status: 'all')
    assert_equal ['GET', '/@portal/vault/keys', { 'status' => 'all' }], target
    assert_raises(K9o::KError) { c.keys.list(status: 'gone') }
    assert_raises(K9o::KError) { c.keys.list(status: 'rotating') } # only active or all
    c.keys.list(status: 'active')
  end

  def test_key_fields_are_exposed_as_sent
    c = client(env('items' => [KEY, HYOK], 'nextCursor' => nil))
    byok, hyok = c.keys.list(status: 'all').data['items']
    assert_equal %w[id version status custodyMode createdAt rotatedAt byokRef hyokRef], byok.keys
    assert_equal({ 'provider' => 'aws-kms', 'region' => 'eu-central-1', 'externalKeyFingerprint' => 'Zm9vYmFyYmF6cXV4' }, byok['byokRef'])
    assert_nil byok['hyokRef']
    assert_equal({ 'clusterId' => 'hsm_1', 'clusterName' => 'berlin-hsm', 'externalKeyFingerprint' => 'cXV4YmF6YmFyZm9v' }, hyok['hyokRef'])
    assert_nil hyok['byokRef']
  end

  def test_get
    c = client(env(KEY))
    assert_equal 2, c.keys.get('vkey_5b0d').data['version']
    assert_equal ['GET', '/@portal/vault/keys/vkey_5b0d', {}], target
    assert_raises(K9o::KError) { c.keys.get('') }
  end

  def test_get_not_found_and_trust_zone
    e = assert_raises(K9o::KError) { client(err(404, 'K9O_NOT_FOUND')).keys.get('vkey_x') }
    assert_equal 404, e.status
    c = client(err(403, 'K9O_TRUST_ZONE_VIOLATION'))
    e = assert_raises(K9o::KError) { c.keys.list }
    assert_equal ['K9O_TRUST_ZONE_VIOLATION', 403], [e.code, e.status]
  end

  def test_upstream_unavailable_on_list_is_retried_then_raised
    c = client(err(502, 'K9O_UPSTREAM_UNAVAILABLE'))
    c.config.instance_variable_set(:@retry_config, K9o::RetryConfig.new(max_retries: 1, backoff: 'none'))
    e = assert_raises(K9o::KError) { c.keys.list }
    assert_equal 502, e.status
    assert_equal 2, @http.reqs.size
  end

  def test_rotate
    c = client(env('keyId' => 'vkey_5b0d', 'previousVersion' => 2, 'newVersion' => 3, 'status' => 'rotated'))
    out = c.keys.rotate('vkey_5b0d').data
    assert_equal ['POST', '/@portal/vault/keys/vkey_5b0d/rotate', {}], target
    assert_equal [2, 3, 'rotated'], out.values_at('previousVersion', 'newVersion', 'status')
    assert_nil @http.reqs.last.body
  end

  def test_rotate_passes_extra_headers
    c = client(env('keyId' => 'vkey_5b0d', 'previousVersion' => 2, 'newVersion' => 3, 'status' => 'rotated'))
    c.keys.rotate('vkey_5b0d', headers: { 'x-extra' => 'p' })
    assert_equal 'p', @http.reqs.last['x-extra']
  end

  STEP_UP = { 'scopeSetRoot' => 'ssr_9f3a', 'nonce' => 'n_81c2', 'minTier' => 'T3_KEY_POSSESSION',
              'methods' => %w[webauthn dpop], 'maxAgeSec' => 120, 'singleUse' => true, 'rpId' => 'acme.k9o.io' }.freeze
  ROTATED = { 'keyId' => 'vkey_5b0d', 'previousVersion' => 2, 'newVersion' => 3, 'status' => 'rotated' }.freeze

  def decode_proof(header)
    JSON.parse(header.tr('-_', '+/').unpack1('m'))
  end

  def test_rotate_step_up_required_without_a_hook_carries_the_challenge
    e = assert_raises(K9o::KError) { client(err(401, 'K9O_STEP_UP_REQUIRED', 'stepUp' => STEP_UP)).keys.rotate('vkey_5b0d') }
    assert_equal ['K9O_STEP_UP_REQUIRED', 401, STEP_UP], [e.code, e.status, e.context['stepUp']]
    ch = e.step_up
    assert_equal ['ssr_9f3a', 'n_81c2', 'T3_KEY_POSSESSION', %w[webauthn dpop], 120, true, 'acme.k9o.io'],
                 [ch.scope_set_root, ch.nonce, ch.min_tier, ch.methods, ch.max_age_sec, ch.single_use, ch.rp_id]
    assert_nil K9o::KError.new(code: 'x', message: 'y').step_up
  end

  def test_rotate_hook_gets_challenge_method_and_url_then_retry_carries_the_header
    c = client(err(401, 'K9O_STEP_UP_REQUIRED', 'stepUp' => STEP_UP), env(ROTATED))
    seen = nil
    out = c.keys.rotate('vkey_5b0d', step_up: lambda { |challenge, method, url|
      seen = [challenge.nonce, challenge.methods, challenge.max_age_sec, challenge.rp_id, method, url]
      { method: 'dpop', proof: 'eyJ.proof.sig' }
    })
    assert_equal 'rotated', out.data['status']
    assert_equal ['n_81c2', %w[webauthn dpop], 120, 'acme.k9o.io', 'POST',
                  'https://acme.api-de01.k9o.io/@portal/vault/keys/vkey_5b0d/rotate'], seen
    assert_equal 2, @http.reqs.size
    assert_nil @http.reqs[0]['x-k9o-step-up-proof']
    header = @http.reqs[1]['x-k9o-step-up-proof']
    refute_match(/[=+\/]/, header) # base64url without padding
    assert_equal({ 'scopeSetRoot' => 'ssr_9f3a', 'nonce' => 'n_81c2', 'method' => 'dpop', 'proof' => 'eyJ.proof.sig' },
                 decode_proof(header))
    assert_equal ['POST', '/@portal/vault/keys/vkey_5b0d/rotate'], [@http.reqs[1].method, @http.reqs[1].path]
  end

  def test_rotate_hook_may_answer_with_string_keys
    c = client(err(401, 'K9O_STEP_UP_REQUIRED', 'stepUp' => STEP_UP), env(ROTATED))
    c.keys.rotate('vkey_5b0d', step_up: ->(_c, _m, _u) { { 'method' => 'webauthn', 'proof' => 'p' } })
    assert_equal 'webauthn', decode_proof(@http.reqs[1]['x-k9o-step-up-proof'])['method']
  end

  def test_rotate_hook_that_raises_stops_without_a_retry
    c = client(err(401, 'K9O_STEP_UP_REQUIRED', 'stepUp' => STEP_UP), env(ROTATED))
    e = assert_raises(RuntimeError) { c.keys.rotate('vkey_5b0d', step_up: ->(_c, _m, _u) { raise 'no passkey' }) }
    assert_equal 'no passkey', e.message
    assert_equal 1, @http.reqs.size
  end

  def test_rotate_second_401_is_not_retried_again
    c = client(err(401, 'K9O_STEP_UP_REQUIRED', 'stepUp' => STEP_UP))
    calls = 0
    e = assert_raises(K9o::KError) do
      c.keys.rotate('vkey_5b0d', step_up: ->(_c, _m, _u) { calls += 1; { method: 'dpop', proof: 'p' } })
    end
    assert_equal 'K9O_STEP_UP_REQUIRED', e.code
    assert_equal [1, 2], [calls, @http.reqs.size]
    c = client(err(401, 'K9O_STEP_UP_REQUIRED', 'stepUp' => STEP_UP), err(401, 'K9O_STEP_UP_PROOF_MALFORMED'))
    e = assert_raises(K9o::KError) { c.keys.rotate('vkey_5b0d', step_up: ->(_c, _m, _u) { { method: 'dpop', proof: 'bad' } }) }
    assert_equal ['K9O_STEP_UP_PROOF_MALFORMED', 401], [e.code, e.status]
    assert_equal 2, @http.reqs.size
  end

  def test_rotate_hook_answer_is_checked_before_sending
    ch = err(401, 'K9O_STEP_UP_REQUIRED', 'stepUp' => STEP_UP)
    [nil, {}, { method: 'mtls', proof: 'p' }, { method: 'dpop' }, { method: 'dpop', proof: '' }].each do |answer|
      c = client(ch, env(ROTATED))
      e = assert_raises(K9o::KError) { c.keys.rotate('vkey_5b0d', step_up: ->(_c, _m, _u) { answer }) }
      assert_equal 'K9O_INVALID_FIELD_VALUE', e.code
      assert_equal 1, @http.reqs.size
    end
    assert_raises(K9o::KError) { client(env(ROTATED)).keys.rotate('vkey_5b0d', step_up: 'nope') }
  end

  def test_rotate_hook_is_not_called_for_other_errors_or_a_missing_challenge
    called = false
    hook = ->(_c, _m, _u) { called = true; { method: 'dpop', proof: 'p' } }
    e = assert_raises(K9o::KError) { client(err(409, 'K9O_STATE_CONFLICT', 'reason' => 'key_not_active')).keys.rotate('k', step_up: hook) }
    assert_equal 409, e.status
    e = assert_raises(K9o::KError) { client(err(401, 'K9O_STEP_UP_REQUIRED', {})).keys.rotate('k', step_up: hook) }
    assert_equal 'K9O_STEP_UP_REQUIRED', e.code
    refute called
  end

  def test_rotate_in_flight_conflict
    e = assert_raises(K9o::KError) { client(err(409, 'K9O_STATE_CONFLICT', 'reason' => 'rotation_in_flight')).keys.rotate('vkey_5b0d') }
    assert_equal ['K9O_STATE_CONFLICT', 409, 'rotation_in_flight'], [e.code, e.status, e.context['reason']]
  end

  def test_rotate_rate_cap_surfaces_retry_after_and_is_not_retried
    c = client(err(429, 'K9O_RATE_LIMITED', { 'reason' => 'rotation_rate_cap' }, 'retry-after' => '3600'))
    e = assert_raises(K9o::KError) { c.keys.rotate('vkey_5b0d') }
    assert_equal ['K9O_RATE_LIMITED', 429, 'rotation_rate_cap', 3600], [e.code, e.status, e.context['reason'], e.retry_after_sec]
    assert_equal 1, @http.reqs.size
  end

  def test_rotate_other_errors
    { 403 => 'K9O_TRUST_ZONE_VIOLATION', 404 => 'K9O_NOT_FOUND', 500 => 'K9O_INTERNAL_ERROR', 502 => 'K9O_UPSTREAM_UNAVAILABLE' }.each do |status, code|
      e = assert_raises(K9o::KError) { client(err(status, code)).keys.rotate('vkey_5b0d') }
      assert_equal [code, status], [e.code, e.status]
    end
  end

  def test_retry_after_from_the_body_wins_over_the_header
    body = JSON.dump('code' => 'K9O_RATE_LIMITED', 'message' => 'x', 'context' => {}, 'recommendation' => { 'retryAfterSec' => 5 })
    e = assert_raises(K9o::KError) { client([429, body, { 'retry-after' => '99' }]).keys.rotate('vkey_5b0d') }
    assert_equal 5, e.retry_after_sec
    e = assert_raises(K9o::KError) { client(err(429, 'K9O_RATE_LIMITED', {}, 'retry-after' => 'Wed, 21 Oct 2026 07:28:00 GMT')).keys.rotate('k') }
    assert_nil e.retry_after_sec
  end
end
