# frozen_string_literal: true

require 'minitest/autorun'
require 'json'
require 'pp'
require_relative '../lib/k9o'

# client.crypto: encrypt, decrypt and rewrap against a stubbed transport.
class CryptoTest < Minitest::Test
  Resp = Struct.new(:code, :body, :headers) do
    def [](name)
      (headers || {})[name.downcase]
    end
  end

  class Stub
    attr_reader :reqs
    attr_accessor :use_ssl, :read_timeout

    def initialize(*answers, modes: nil)
      @answers = answers
      @modes = modes
      @reqs = []
    end

    # The mode answers (last one repeats) are kept apart from the crypto answers, so a test reads in call order per path.
    def request(req)
      @reqs << req
      queue = req.path.split('?').first.end_with?('/crypto/mode') ? @modes : @answers
      a = queue.size > 1 ? queue.shift : queue.first
      Resp.new(a[0].to_s, a[1], a[2])
    end

    def paths
      @reqs.map { |r| "#{r.method} #{r.path.split('?').first}" }
    end

    # The raw query string of each mode GET, in call order (nil when none).
    def mode_queries
      @reqs.select { |r| r.path.split('?').first.end_with?('/crypto/mode') }.map { |r| r.path.split('?', 2)[1] }
    end

    def posts
      @reqs.reject { |r| r.path.split('?').first.end_with?('/crypto/mode') }
    end
  end

  def env(items)
    [200, JSON.dump('data' => { 'items' => items }, 'meta' => { 'context' => { 'requestId' => 'req_1' } })]
  end

  def err(status, code, context = {}, headers = {})
    [status, JSON.dump('code' => code, 'message' => 'no', 'context' => context), headers]
  end

  def mode_ok(mode = 'PLATFORM_MANAGED', epoch = 'ep-1', **extra)
    [200, JSON.dump('data' => { 'custodyMode' => mode, 'epoch' => epoch }.merge(extra.transform_keys(&:to_s)), 'meta' => {})]
  end

  def client(*answers, modes: [mode_ok])
    @http = Stub.new(*answers, modes: modes)
    K9o.create_client(base_url: 'https://acme.api-de01.k9o.io', api_key: 'k', project_slug: 'portal', http_client: @http)
  end

  def sent
    JSON.parse(@http.posts.last.body)
  end

  def b64(bytes)
    [bytes].pack('m0')
  end

  def test_encrypt_body_and_decoding
    c = client(env([{ 'ciphertext' => 'Y3Q5' }, { 'ciphertext' => 'Y3QxMA==' }]))
    out = c.crypto.encrypt('payments', [{ plaintext: 'card-1', context: 'order-9' }, 'card-2'])
    assert_equal ['POST', '/@portal/crypto/encrypt'], [@http.posts[0].method, @http.posts[0].path]
    assert_equal({ 'crypt' => 'payments', 'custodyEpoch' => 'ep-1',
                   'items' => [{ 'plaintext' => b64('card-1'), 'context' => 'order-9' }, { 'plaintext' => b64('card-2') }] }, sent)
    assert_equal %w[Y3Q5 Y3QxMA==], out.data['items'].map { |i| i['ciphertext'] }
    assert_equal 'req_1', out.meta.context.request_id
  end

  def test_encrypt_sends_the_bytes_of_any_string_and_accepts_string_keys
    raw = "\xFF\x00\xFE".b
    client(env([{ 'ciphertext' => 'x' }])).crypto.encrypt('k', [{ 'plaintext' => raw }])
    assert_equal b64(raw), sent['items'][0]['plaintext']
    client(env([{ 'ciphertext' => 'x' }])).crypto.encrypt('k', ["héllo"])
    assert_equal b64("héllo".b), sent['items'][0]['plaintext']
  end

  def test_decrypt_body_decodes_plaintext_to_bytes_in_item_order_and_keeps_item_failures
    items = [{ 'plaintext' => b64("one\xFF".b) }, { 'code' => 'K9O_ENVELOPE_INTEGRITY_FAILURE', 'message' => 'cannot open', 'extra' => 1 },
             { 'plaintext' => b64('three'), 'note' => 'kept' }]
    c = client(env(items))
    out = c.crypto.decrypt('payments', [{ ciphertext: 'ct1', context: 'order-9' }, 'ct2', { ciphertext: 'ct3' }]).data['items']
    assert_equal ['POST', '/@portal/crypto/decrypt'], [@http.posts[0].method, @http.posts[0].path]
    assert_equal({ 'crypt' => 'payments', 'items' => [{ 'ciphertext' => 'ct1', 'context' => 'order-9' },
                                                         { 'ciphertext' => 'ct2' }, { 'ciphertext' => 'ct3' }] }, sent)
    assert_equal "one\xFF".b, out[0]['plaintext']
    assert_equal Encoding::BINARY, out[0]['plaintext'].encoding
    assert_equal({ 'code' => 'K9O_ENVELOPE_INTEGRITY_FAILURE', 'message' => 'cannot open', 'extra' => 1 }, out[1])
    assert_equal ['three', 'kept'], [out[2]['plaintext'], out[2]['note']]
    assert_equal 'three', K9o::Crypto.text(out[2])
    assert_equal Encoding::UTF_8, K9o::Crypto.text(out[2]).encoding
    assert_nil K9o::Crypto.text(out[1])
  end

  def test_rewrap
    c = client(env([{ 'ciphertext' => 'new1' }]))
    out = c.crypto.rewrap('payments', [{ ciphertext: 'old1', context: 'c' }])
    assert_equal ['POST', '/@portal/crypto/rewrap'], [@http.posts[0].method, @http.posts[0].path]
    assert_equal({ 'crypt' => 'payments', 'items' => [{ 'ciphertext' => 'old1', 'context' => 'c' }] }, sent)
    assert_equal 'new1', out.data['items'][0]['ciphertext']
  end

  def test_crypt_is_validated
    c = client(env([]))
    ['', 'Upper', 'has space', 'a_b', 'x' * 65, nil, :sym].each do |bad|
      e = assert_raises(K9o::KError) { c.crypto.encrypt(bad, ['p']) }
      assert_equal 'K9O_INVALID_FIELD_VALUE', e.code
    end
    c.crypto.encrypt('a' * 64, ['p'])
    c.crypto.encrypt('a-b-0', ['p'])
    assert_equal 2, @http.posts.size
  end

  def test_the_name_actions_is_refused_with_no_request_and_actions_2_is_accepted
    c = client(env([]))
    e = assert_raises(K9o::KError) { c.crypto.encrypt('actions', ['p']) }
    assert_equal 'K9O_INVALID_FIELD_VALUE', e.code
    assert_equal 'crypt must be 1 to 64 characters of a-z, 0-9 and -, and not "actions"', e.message
    assert_equal 'K9O_INVALID_FIELD_VALUE', assert_raises(K9o::KError) { c.crypto.decrypt('actions', ['ct']) }.code
    assert_equal 'K9O_INVALID_FIELD_VALUE', assert_raises(K9o::KError) { c.crypto.rewrap('actions', ['ct']) }.code
    assert_equal 'K9O_INVALID_FIELD_VALUE', assert_raises(K9o::KError) { c.crypto.federated_token('actions', 'encrypt') }.code
    assert_empty @http.reqs
    c.crypto.encrypt('actions-2', ['p'])
    assert_equal 'actions-2', sent['crypt']
  end

  def test_encrypt_crypt_not_found_404_passes_through_unchanged
    c = client(err(404, 'K9O_CRYPT_NOT_FOUND'))
    e = assert_raises(K9o::KError) { c.crypto.encrypt('nope', ['p']) }
    assert_equal ['K9O_CRYPT_NOT_FOUND', 404], [e.code, e.status]
    assert_equal K9o::Crypto::CRYPT_NOT_FOUND, e.code
    assert_equal 1, @http.posts.size
  end

  def test_encrypt_crypt_retired_409_passes_through_unchanged
    c = client(err(409, 'K9O_CRYPT_RETIRED'))
    e = assert_raises(K9o::KError) { c.crypto.encrypt('old', ['p']) }
    assert_equal ['K9O_CRYPT_RETIRED', 409], [e.code, e.status]
    assert_equal K9o::Crypto::CRYPT_RETIRED, e.code
    assert_equal 1, @http.posts.size
  end

  def test_item_count_and_shape_are_validated
    c = client(env([]))
    [[], nil, 'p', Array.new(101, 'p')].each do |bad|
      assert_equal 'K9O_INVALID_FIELD_VALUE', assert_raises(K9o::KError) { c.crypto.encrypt('k', bad) }.code
    end
    [[{}], [42], [{ plaintext: 1 }], [{ plaintext: 'a', ciphertext: 'b' }], [{ plaintext: 'a', context: 7 }],
     [{ plaintext: 'a', context: 'x' * 257 }], [{ plaintext: 'a', context: "\xFF".b }]].each do |bad|
      assert_equal 'K9O_INVALID_FIELD_VALUE', assert_raises(K9o::KError) { c.crypto.encrypt('k', bad) }.code
    end
    assert_equal 'K9O_INVALID_FIELD_VALUE', assert_raises(K9o::KError) { c.crypto.decrypt('k', [{ plaintext: 'a' }]) }.code
    assert_equal 'K9O_INVALID_FIELD_VALUE', assert_raises(K9o::KError) { c.crypto.decrypt('k', ['']) }.code
    assert_equal 'K9O_INVALID_FIELD_VALUE', assert_raises(K9o::KError) { c.crypto.rewrap('k', [{ ciphertext: nil }]) }.code
    assert_empty @http.reqs
    c.crypto.encrypt('k', Array.new(100, 'p'))
    c.crypto.encrypt('k', [{ plaintext: 'a', context: 'x' * 256 }])
    assert_equal 2, @http.posts.size
  end

  def test_sizes_are_validated_with_the_server_code_and_nothing_is_sent
    c = client(env([]))
    e = assert_raises(K9o::KError) { c.crypto.encrypt('k', ['a' * (64 * 1024 + 1)]) }
    assert_equal 'K9O_PAYLOAD_TOO_LARGE', e.code
    big = 'a' * (64 * 1024)
    e = assert_raises(K9o::KError) { c.crypto.encrypt('k', Array.new(17, big)) } # 17 x 64 KiB > 1 MiB
    assert_equal 'K9O_PAYLOAD_TOO_LARGE', e.code
    assert_empty @http.reqs
    c.crypto.encrypt('k', Array.new(16, big)) # exactly 1 MiB
    c.crypto.encrypt('k', [big])
    assert_equal 2, @http.posts.size
  end

  def test_project_slug_is_required
    c = K9o.create_client(base_url: 'https://acme.api-de01.k9o.io', api_key: 'k', http_client: Stub.new(env([])))
    assert_equal 'K9O_MISSING_PROJECT_CONTEXT', assert_raises(K9o::KError) { c.crypto.encrypt('k', ['p']) }.code
  end

  def test_each_error_code_is_typed
    cases = [[400, 'K9O_ENVELOPE_INTEGRITY_FAILURE', {}], [409, 'K9O_SEALED_UNDER_RETIRED_KEY', { 'resealableUntil' => '2026-11-03T00:00:00Z' }],
             [413, 'K9O_PAYLOAD_TOO_LARGE', {}], [403, 'K9O_RBAC_DENY', {}], [404, 'K9O_NOT_FOUND', {}],
             [503, 'K9O_KEY_SERVICE_UNAVAILABLE', {}], [503, 'K9O_BYOK_KEY_UNREACHABLE', {}], [503, 'K9O_HYOK_CLUSTER_UNREACHABLE', {}]]
    cases.each do |status, code, ctx|
      %i[encrypt decrypt rewrap].each do |op|
        arg = op == :encrypt ? ['p'] : ['ct']
        e = assert_raises(K9o::KError) { client(err(status, code, ctx)).crypto.public_send(op, 'k', arg) }
        assert_equal [code, status, ctx], [e.code, e.status, e.context]
      end
    end
  end

  def test_rate_limited_carries_retry_after
    c = client(err(429, 'K9O_RATE_LIMITED', {}, 'retry-after' => '7'))
    e = assert_raises(K9o::KError) { c.crypto.encrypt('k', ['p']) }
    assert_equal ['K9O_RATE_LIMITED', 429, 7], [e.code, e.status, e.retry_after_sec]
    assert_equal 1, @http.posts.size
  end

  def test_no_automatic_retry_after_a_5xx_or_a_429
    [502, 503, 504, 500, 429].each do |status|
      %i[encrypt decrypt rewrap].each do |op|
        c = client(err(status, 'K9O_KEY_SERVICE_UNAVAILABLE'), env([{ 'ciphertext' => 'x' }]))
        assert_raises(K9o::KError) { c.crypto.public_send(op, 'k', ['p']) }
        assert_equal 1, @http.posts.size, "#{op} #{status}"
      end
    end
  end

  def test_unexpected_answer_shape_is_passed_through
    out = client([200, JSON.dump('data' => { 'items' => [{ 'ciphertext' => 'x', 'keyVersion' => 3 }], 'usage' => 1 }, 'meta' => {})])
          .crypto.encrypt('k', ['p'])
    assert_equal({ 'items' => [{ 'ciphertext' => 'x', 'keyVersion' => 3 }], 'usage' => 1 }, out.data)
  end

  # ---- routing -------------------------------------------------------------------------------------------------

  class FakeCore
    attr_reader :calls, :opts

    def initialize(answer = nil, enforces: true)
      @enforces = enforces
      @calls = []
      @opts = []
      @answer = answer
    end

    def enforces_expected_key_refs?
      @enforces
    end

    %i[encrypt decrypt rewrap].each do |op|
      define_method(op) do |crypt, items, **opts|
        @calls << [op, crypt, items]
        @opts << opts
        @answer || items.map { |_| op == :decrypt ? { 'plaintext' => 'core'.b } : { 'ciphertext' => "core-#{op}" } }
      end
    end
  end

  def zk_409(route, epoch = 'ep-2', mode = 'BYOK')
    err(409, 'K9O_ZK_STORE_FLOW_REQUIRED', { 'custodyMode' => mode, 'route' => route, 'epoch' => epoch })
  end

  def test_platform_managed_encrypt_is_one_mode_get_then_one_post_with_the_epoch
    c = client(env([{ 'ciphertext' => 'x' }]))
    c.crypto.encrypt('k', ['p'])
    assert_equal ['GET /@portal/crypto/mode', 'POST /@portal/crypto/encrypt'], @http.paths
    assert_equal %w[crypt items custodyEpoch].sort, sent.keys.sort
    assert_equal 'ep-1', sent['custodyEpoch']
  end

  def test_encrypt_mode_check_names_the_crypt_and_public_mode_does_not
    c = client(env([{ 'ciphertext' => 'x' }]))
    c.crypto.encrypt('customer-notes', ['p'])
    assert_equal ['crypt=customer-notes'], @http.mode_queries
    @http.reqs.clear
    c.crypto.mode
    assert_equal [nil], @http.mode_queries
  end

  def test_public_mode_takes_an_optional_crypt
    c = client(env([{ 'ciphertext' => 'x' }]))
    assert_equal 'PLATFORM_MANAGED', c.crypto.mode(crypt: 'customer-notes').custody_mode
    assert_equal ['crypt=customer-notes'], @http.mode_queries
    @http.reqs.clear
    c.crypto.mode
    assert_equal [nil], @http.mode_queries
    @http.reqs.clear
    [nil.to_s, 'actions', 'Upper', 'a b', 'x' * 65, 7].each do |bad|
      assert_equal 'K9O_INVALID_FIELD_VALUE', assert_raises(K9o::KError) { c.crypto.mode(crypt: bad) }.code
    end
    assert_empty @http.reqs
  end

  def test_server_modes_all_route_to_the_server
    %w[PLATFORM_MANAGED CONFIDENTIAL_WORKLOAD SKR].each do |m|
      client(env([{ 'ciphertext' => 'x' }]), modes: [mode_ok(m)]).crypto.encrypt('k', ['p'])
      assert_equal 1, @http.posts.size, m
    end
  end

  def test_two_encrypts_make_two_mode_gets
    c = client(env([{ 'ciphertext' => 'x' }]))
    c.crypto.encrypt('k', ['p'])
    c.crypto.encrypt('k', ['p'])
    assert_equal 2, @http.paths.count('GET /@portal/crypto/mode')
    assert_equal 2, @http.posts.size
  end

  def test_a_batch_is_one_mode_check
    client(env([{ 'ciphertext' => 'x' }, { 'ciphertext' => 'y' }])).crypto.encrypt('k', %w[a b])
    assert_equal 1, @http.paths.count('GET /@portal/crypto/mode')
  end

  def test_the_mode_is_never_cached_a_move_to_byok_is_seen
    c = client(env([{ 'ciphertext' => 'x' }]), modes: [mode_ok('PLATFORM_MANAGED', 'ep-1'), mode_ok('BYOK', 'ep-2')])
    c.crypto.encrypt('k', ['p'])
    e = assert_raises(K9o::KError) { c.crypto.encrypt('k', ['p']) }
    assert_equal 'K9O_ZK_CLIENT_CORE_UNAVAILABLE', e.code
    assert_equal 1, @http.posts.size
  end

  def test_byok_and_hyok_without_a_client_core_raise_and_send_no_plaintext
    %w[BYOK HYOK].each do |m|
      e = assert_raises(K9o::KError) { client(env([]), modes: [mode_ok(m)]).crypto.encrypt('k', ['secret']) }
      assert_equal ['K9O_ZK_CLIENT_CORE_UNAVAILABLE', 501], [e.code, e.status]
      assert_equal({ 'custodyMode' => m, 'requirement' => 'kibo-client-core' }, e.context)
      assert_match(/Kibo client core/, e.message)
      assert_equal ['GET /@portal/crypto/mode'], @http.paths
    end
    assert_equal 'K9O_ZK_CLIENT_CORE_UNAVAILABLE', K9o::Crypto::ZK_CLIENT_CORE_UNAVAILABLE
  end

  # ---- route from the mode answer -----------------------------------------------------------------------------

  def test_byok_with_no_route_uses_the_client_core
    core = FakeCore.new
    c = client(env([]), modes: [mode_ok('BYOK')])
    c.crypto.use_client_core(core)
    c.crypto.encrypt('k', ['p'])
    assert_equal 1, core.calls.size
    assert_empty @http.posts
  end

  def test_byok_and_hyok_route_server_sends_to_the_server_not_the_core
    %w[BYOK HYOK].each do |m|
      core = FakeCore.new
      c = client(env([{ 'ciphertext' => 'x' }]), modes: [mode_ok(m, 'ep-9', route: 'server')])
      c.crypto.use_client_core(core)
      c.crypto.encrypt('k', ['p'])
      assert_equal 1, @http.posts.size, m
      assert_equal 'ep-9', sent['custodyEpoch']
      assert_empty core.calls
    end
  end

  def test_byok_route_client_uses_the_core
    core = FakeCore.new
    c = client(env([]), modes: [mode_ok('BYOK', 'ep-1', route: 'client')])
    c.crypto.use_client_core(core)
    c.crypto.encrypt('k', ['p'])
    assert_equal 1, core.calls.size
    assert_empty @http.posts
  end

  def test_an_unknown_route_refuses_and_sends_nothing
    ['bogus', 5, '', 'Server'].each do |r|
      %w[BYOK PLATFORM_MANAGED].each do |m|
        core = FakeCore.new
        c = client(env([]), modes: [mode_ok(m, 'ep-1', route: r)])
        c.crypto.use_client_core(core)
        e = assert_raises(K9o::KError) { c.crypto.encrypt('k', ['p']) }
        assert_equal 'K9O_CRYPTO_CUSTODY_UNKNOWN', e.code
        expected = { 'custodyMode' => m }
        expected['route'] = r if r.is_a?(String)
        assert_equal expected, e.context
        assert_empty @http.posts
        assert_empty core.calls
      end
    end
  end

  def test_every_non_string_route_value_refuses_and_sends_nothing
    [123, 0, 1.5, true, false, [], {}, ['server']].each do |r|
      %w[BYOK PLATFORM_MANAGED].each do |m|
        core = FakeCore.new
        c = client(env([]), modes: [mode_ok(m, 'ep-1', route: r)])
        c.crypto.use_client_core(core)
        e = assert_raises(K9o::KError) { c.crypto.encrypt('k', ['p']) }
        assert_equal 'K9O_CRYPTO_CUSTODY_UNKNOWN', e.code
        assert_equal({ 'custodyMode' => m }, e.context)
        assert_empty @http.posts
        assert_empty core.calls
      end
    end
  end

  def test_a_json_null_route_is_unknown_and_a_missing_route_is_not
    %w[BYOK HYOK PLATFORM_MANAGED].each do |m|
      core = FakeCore.new
      c = client(env([]), modes: [mode_ok(m, 'ep-1', route: nil)])
      c.crypto.use_client_core(core)
      e = assert_raises(K9o::KError) { c.crypto.encrypt('k', ['p']) }
      assert_equal 'K9O_CRYPTO_CUSTODY_UNKNOWN', e.code
      assert_equal({ 'custodyMode' => m }, e.context)
      assert_empty @http.posts
      assert_empty core.calls
    end
    core = FakeCore.new
    c = client(env([]), modes: [mode_ok('BYOK', 'ep-1')])
    c.crypto.use_client_core(core)
    c.crypto.encrypt('k', ['p'])
    assert_equal 1, core.calls.size
    assert_empty @http.posts
  end

  def test_byok_route_server_without_an_epoch_refuses
    [nil, ''].each do |ep|
      core = FakeCore.new
      c = client(env([]), modes: [mode_ok('BYOK', ep, route: 'server')])
      c.crypto.use_client_core(core)
      e = assert_raises(K9o::KError) { c.crypto.encrypt('k', ['p']) }
      assert_equal 'K9O_CRYPTO_CUSTODY_UNKNOWN', e.code
      assert_equal({ 'custodyMode' => 'BYOK', 'route' => 'server' }, e.context)
      assert_empty @http.posts
      assert_empty core.calls
    end
  end

  def test_platform_managed_with_route_server_or_client_goes_to_the_server
    %w[server client].each do |r|
      client(env([{ 'ciphertext' => 'x' }]), modes: [mode_ok('PLATFORM_MANAGED', 'ep-1', route: r)]).crypto.encrypt('k', ['p'])
      assert_equal 1, @http.posts.size
    end
  end

  def test_the_route_is_read_fresh_and_mode_struct_has_a_route_member
    core = FakeCore.new
    c = client(env([{ 'ciphertext' => 'x' }]), modes: [mode_ok('BYOK', 'ep-1', route: 'server'), mode_ok('BYOK', 'ep-1')])
    c.crypto.use_client_core(core)
    c.crypto.encrypt('k', ['p'])
    c.crypto.encrypt('k', ['p'])
    assert_equal 2, @http.paths.count('GET /@portal/crypto/mode')
    assert_equal 1, @http.posts.size
    assert_equal 1, core.calls.size
    assert_equal %i[custody_mode epoch route], c.crypto.mode.to_h.keys
  end

  def test_byok_with_a_registered_core_calls_the_core_and_no_server_encrypt
    core = FakeCore.new
    c = client(env([]), modes: [mode_ok('HYOK')])
    assert_same core, c.crypto.use_client_core(core)
    out = c.crypto.encrypt('payments', [{ plaintext: 'card', context: 'o1' }, 'two'])
    assert_equal [[:encrypt, 'payments', [{ plaintext: 'card'.b, context: 'o1' }, { plaintext: 'two'.b }]]], core.calls
    assert_equal %w[core-encrypt core-encrypt], out.data['items'].map { |i| i['ciphertext'] }
    assert_equal ['GET /@portal/crypto/mode'], @http.paths
  end

  def byok_client(refs)
    @http = Stub.new(env([]), modes: [mode_ok('BYOK')])
    K9o.create_client(base_url: 'https://acme.api-de01.k9o.io', api_key: 'k', project_slug: 'portal', http_client: @http,
                      expected_key_refs: refs)
  end

  def test_expected_key_refs_is_passed_to_the_core_on_every_call_when_set
    core = FakeCore.new
    refs = ['arn:aws:kms:eu-west-1:111122223333:key/abc']
    c = byok_client(refs)
    c.crypto.use_client_core(core)
    c.crypto.encrypt('k', ['p'])
    @http = Stub.new(err(409, 'K9O_ZK_STORE_FLOW_REQUIRED', { 'custodyMode' => 'BYOK', 'route' => 'client' }), modes: [mode_ok('BYOK')])
    c2 = K9o.create_client(base_url: 'https://acme.api-de01.k9o.io', api_key: 'k', project_slug: 'portal', http_client: @http,
                           expected_key_refs: refs)
    c2.crypto.use_client_core(core)
    c2.crypto.decrypt('k', ['ct'])
    c2.crypto.rewrap('k', ['ct'])
    assert_equal 3, core.opts.size
    assert(core.opts.all? { |o| o == { expected_key_refs: refs } })
    assert(core.opts.all? { |o| o[:expected_key_refs].frozen? })
  end

  def test_expected_key_refs_is_absent_when_unset
    core = FakeCore.new
    c = client(env([]), modes: [mode_ok('BYOK')])
    c.crypto.use_client_core(core)
    c.crypto.encrypt('k', ['p'])
    assert_equal [{}], core.opts
  end

  def test_expected_key_refs_is_copied_and_frozen
    refs = ['alias/orders']
    c = byok_client(refs)
    refs << 'alias/other'
    assert_equal ['alias/orders'], c.config.expected_key_refs
    assert c.config.expected_key_refs.frozen?
  end

  def test_invalid_expected_key_refs_are_rejected_at_build_time
    [[], 'arn', [''], ['  '], ['a b'], [1], ['arn:aws:kms:*:*:key/*'], ['*']].each do |bad|
      e = assert_raises(K9o::KError, bad.inspect) { byok_client(bad) }
      assert_equal 'K9O_INVALID_FIELD_VALUE', e.code
      assert_equal 'expectedKeyRefs', e.context['field']
      assert e.message.start_with?('expectedKeyRefs: ')
    end
  end

  def pinned_ops(core)
    refs = ['alias/orders']
    c = byok_client(refs)
    c.crypto.use_client_core(core)
    c2 = K9o.create_client(base_url: 'https://acme.api-de01.k9o.io', api_key: 'k', project_slug: 'portal',
                           http_client: Stub.new(err(409, 'K9O_ZK_STORE_FLOW_REQUIRED', { 'custodyMode' => 'BYOK', 'route' => 'client' }),
                                                 modes: [mode_ok('BYOK')]),
                           expected_key_refs: refs)
    c2.crypto.use_client_core(core)
    [-> { c.crypto.encrypt('k', ['p']) }, -> { c2.crypto.decrypt('k', ['ct']) }, -> { c2.crypto.rewrap('k', ['ct']) }]
  end

  def test_a_core_that_does_not_declare_enforcement_is_refused_when_the_list_is_set
    core = FakeCore.new(nil, enforces: false)
    pinned_ops(core).each do |call|
      e = assert_raises(K9o::KError) { call.call }
      assert_equal 'K9O_CRYPTO_KEY_PIN_UNENFORCED', e.code
      assert_equal 'K9O_CRYPTO_KEY_PIN_UNENFORCED', K9o::Crypto::KEY_PIN_UNENFORCED
      assert_nil e.status
      assert_equal({ 'custodyMode' => 'BYOK', 'requirement' => 'client-core-enforces-expected-key-refs' }, e.context)
      assert_match(/does not declare that it enforces it; nothing was sent/, e.message)
      assert_match(/enforces_expected_key_refs\?/, e.recommendation)
    end
    assert_empty core.calls
  end

  def test_a_core_without_the_method_or_not_returning_true_is_refused
    [Class.new { %i[encrypt decrypt rewrap].each { |m| define_method(m) { |*_a, **_o| [] } } }.new,
     Class.new(FakeCore) { def enforces_expected_key_refs?; 'yes'; end }.new].each do |core|
      pinned_ops(core).each do |call|
        assert_equal 'K9O_CRYPTO_KEY_PIN_UNENFORCED', assert_raises(K9o::KError) { call.call }.code
      end
      assert_empty(core.calls) if core.respond_to?(:calls)
    end
  end

  def test_an_undeclared_core_works_when_no_list_is_set
    core = FakeCore.new(nil, enforces: false)
    c = client(env([]), modes: [mode_ok('BYOK')])
    c.crypto.use_client_core(core)
    c.crypto.encrypt('k', ['p'])
    assert_equal 1, core.calls.size
  end

  GCP_KEY = 'projects/p/locations/europe-west1/keyRings/r/cryptoKeys/k'
  AZ_KEY = 'https://Vault.Example.net/keys/orders'
  ARN_KEY = 'arn:aws:kms:eu-west-1:111122223333:key/abc'

  def test_key_ref_matches_azure_ignores_case_and_version
    assert K9o::Crypto.key_ref_matches?("#{AZ_KEY}/0123456789abcdef0123456789abcdef", ['https://vault.example.net/keys/ORDERS'], provider: :azure)
    assert K9o::Crypto.key_ref_matches?('https://vault.example.net/keys/orders', ["#{AZ_KEY}/v1"], provider: :azure)
    refute K9o::Crypto.key_ref_matches?(AZ_KEY, ['https://vault.example.net/keys/other'], provider: :azure)
    assert K9o::Crypto.key_ref_matches?(AZ_KEY, [AZ_KEY], provider: :azure)
  end

  def test_key_ref_matches_vault_ignores_a_colon_version
    assert K9o::Crypto.key_ref_matches?('transit/keys/orders:3', ['transit/keys/orders'], provider: :vault)
    assert K9o::Crypto.key_ref_matches?('orders:7', ['orders'], provider: :vault)
    refute K9o::Crypto.key_ref_matches?('transit/keys/orders:3', ['transit/other/orders'], provider: :vault)
    refute K9o::Crypto.key_ref_matches?('a/orders', ['b/orders'], provider: :vault)
  end

  def test_key_ref_matches_gcp_and_aws
    assert K9o::Crypto.key_ref_matches?("#{GCP_KEY}/cryptoKeyVersions/7", [GCP_KEY], provider: :gcp)
    assert K9o::Crypto.key_ref_matches?(GCP_KEY, ["#{GCP_KEY}/cryptoKeyVersions/2"], provider: :gcp)
    refute K9o::Crypto.key_ref_matches?("#{GCP_KEY}2/cryptoKeyVersions/1", [GCP_KEY], provider: :gcp)
    assert K9o::Crypto.key_ref_matches?(ARN_KEY, ['alias/x', ARN_KEY], provider: :aws)
    refute K9o::Crypto.key_ref_matches?(ARN_KEY, ['arn:aws:kms:eu-west-1:111122223333:key/abd'], provider: :aws)
    refute K9o::Crypto.key_ref_matches?(ARN_KEY, [ARN_KEY.upcase], provider: :aws)
  end

  def test_key_ref_matches_provider_is_required_and_decides_the_rule
    assert K9o::Crypto.key_ref_matches?('http://h/keys/k/v', ['http://H/keys/K'], provider: :azure)
    assert K9o::Crypto.key_ref_matches?('p/cryptoKeyVersions/1', ['p/cryptoKeyVersions/9'], provider: :gcp)
    # the same text compares by the provider named: as AWS the whole reference counts, as Vault the :version is dropped
    refute K9o::Crypto.key_ref_matches?('alias/k:1', ['alias/k'], provider: :aws)
    assert K9o::Crypto.key_ref_matches?('alias/k:1', ['alias/k'], provider: :vault)
    assert_raises(ArgumentError) { K9o::Crypto.key_ref_matches?('alias/k', ['alias/k']) }
    assert_equal 'K9O_INVALID_FIELD_VALUE',
                 assert_raises(K9o::KError) { K9o::Crypto.key_ref_matches?('a', ['a'], provider: :other) }.code
  end

  def test_key_ref_matches_url_looking_vault_reference_uses_the_vault_rule_only
    ref = 'https://vault.example.com:8200/transit/keys/orders:3'
    assert K9o::Crypto.key_ref_matches?(ref, ['https://vault.example.com:8200/transit/keys/orders'], provider: :vault)
    refute K9o::Crypto.key_ref_matches?(ref, ['https://vault.example.com:8200/transit/keys/other'], provider: :vault)
    refute K9o::Crypto.key_ref_matches?(ref, ['https://vault.example.com:8200/transit/keys/orders'], provider: :aws)
  end

  def test_use_client_core_checks_the_interface_and_nil_removes_it
    c = client(env([]), modes: [mode_ok('BYOK')])
    assert_equal 'K9O_INVALID_FIELD_VALUE', assert_raises(K9o::KError) { c.crypto.use_client_core(Object.new) }.code
    c.crypto.use_client_core(FakeCore.new)
    c.crypto.use_client_core(nil)
    assert_equal 'K9O_ZK_CLIENT_CORE_UNAVAILABLE', assert_raises(K9o::KError) { c.crypto.encrypt('k', ['p']) }.code
  end

  def test_epoch_race_rechecks_and_reroutes_to_the_core
    core = FakeCore.new
    c = client(zk_409('client'), modes: [mode_ok('PLATFORM_MANAGED', 'ep-1'), mode_ok('BYOK', 'ep-2')])
    c.crypto.use_client_core(core)
    out = c.crypto.encrypt('k', ['p'])
    assert_equal ['GET /@portal/crypto/mode', 'POST /@portal/crypto/encrypt', 'GET /@portal/crypto/mode'], @http.paths
    assert_equal 1, core.calls.size
    assert_equal 'core-encrypt', out.data['items'][0]['ciphertext']
  end

  def test_epoch_race_reroutes_to_the_server_with_the_new_epoch
    c = client(zk_409('server', 'ep-2', 'PLATFORM_MANAGED'), env([{ 'ciphertext' => 'x' }]),
               modes: [mode_ok('PLATFORM_MANAGED', 'ep-1'), mode_ok('PLATFORM_MANAGED', 'ep-2')])
    c.crypto.encrypt('k', ['p'])
    assert_equal 2, @http.posts.size
    assert_equal 'ep-2', sent['custodyEpoch']
  end

  def test_a_second_409_is_raised_after_one_reroute
    c = client(zk_409('client'), modes: [mode_ok('PLATFORM_MANAGED', 'ep-1'), mode_ok('PLATFORM_MANAGED', 'ep-2')])
    e = assert_raises(K9o::KError) { c.crypto.encrypt('k', ['p']) }
    assert_equal ['K9O_ZK_STORE_FLOW_REQUIRED', 409, 'client'], [e.code, e.status, e.context['route']]
    assert_equal 2, @http.posts.size
    assert_equal 2, @http.paths.count('GET /@portal/crypto/mode')
  end

  def test_other_encrypt_errors_are_not_rerouted
    c = client(err(409, 'K9O_SEALED_UNDER_RETIRED_KEY'))
    assert_equal 'K9O_SEALED_UNDER_RETIRED_KEY', assert_raises(K9o::KError) { c.crypto.encrypt('k', ['p']) }.code
    assert_equal 1, @http.paths.count('GET /@portal/crypto/mode')
  end

  def test_unknown_or_missing_mode_fails_closed_with_nothing_sent
    [mode_ok('SOMETHING_NEW'), mode_ok(nil), mode_ok('platform_managed'), [200, JSON.dump('data' => {}, 'meta' => {})],
     [200, JSON.dump('data' => { 'custodyMode' => 'SKR' }, 'meta' => {})]].each do |bad|
      e = assert_raises(K9o::KError) { client(env([]), modes: [bad]).crypto.encrypt('k', ['secret']) }
      assert_equal 'K9O_CRYPTO_CUSTODY_UNKNOWN', e.code
      assert_empty @http.posts
    end
  end

  def test_a_failing_mode_call_fails_closed_with_nothing_sent
    [err(404, 'K9O_NOT_FOUND'), err(403, 'K9O_RBAC_DENY'), err(500, 'K9O_INTERNAL_ERROR')].each do |bad|
      c = client(env([]), modes: [bad])
      assert_raises(K9o::KError) { c.crypto.encrypt('k', ['secret']) }
      assert_empty @http.posts
    end
  end

  def test_mode_method
    m = client(env([])).crypto.mode
    assert_equal ['PLATFORM_MANAGED', 'ep-1'], [m.custody_mode, m.epoch]
    assert_equal ['GET /@portal/crypto/mode'], @http.paths
  end

  def test_mode_returns_the_route_the_gateway_sent
    %w[server client].each do |route|
      c = client(env([]), modes: [mode_ok('HYOK', 'ep-1', route: route)])
      assert_equal route, c.crypto.mode.route
      assert_equal route, c.crypto.mode(crypt: 'customer-notes').route
    end
  end

  def test_mode_route_is_nil_when_absent_or_unknown
    [{}, { route: 'edge' }, { route: nil }, { route: 7 }].each do |extra|
      c = client(env([]), modes: [mode_ok('HYOK', 'ep-1', **extra)])
      assert_nil c.crypto.mode.route, extra.inspect
      assert_nil c.crypto.mode(crypt: 'customer-notes').route, extra.inspect
      assert_equal 'HYOK', c.crypto.mode.custody_mode
    end
  end

  def test_validation_happens_before_the_mode_check
    assert_raises(K9o::KError) { client(env([])).crypto.encrypt('Bad', ['p']) }
    assert_empty @http.reqs
  end

  def test_decrypt_and_rewrap_200_never_touch_the_core_or_the_mode
    core = FakeCore.new
    %i[decrypt rewrap].each do |op|
      c = client(env([{ 'ciphertext' => 'x' }]))
      c.crypto.use_client_core(core)
      c.crypto.public_send(op, 'k', ['ct'])
      assert_equal ["POST /@portal/crypto/#{op}"], @http.paths
    end
    assert_empty core.calls
  end

  def test_decrypt_409_client_route_opens_with_the_core
    core = FakeCore.new
    c = client(zk_409('client'))
    c.crypto.use_client_core(core)
    out = c.crypto.decrypt('k', [{ ciphertext: 'ct', context: 'c1' }])
    assert_equal [[:decrypt, 'k', [{ ciphertext: 'ct', context: 'c1' }]]], core.calls
    assert_equal ['core'.b], out.data['items'].map { |i| i['plaintext'] }
    assert_equal ['POST /@portal/crypto/decrypt'], @http.paths
  end

  def test_rewrap_409_client_route_uses_the_core
    core = FakeCore.new
    c = client(zk_409('client', 'ep-2', 'HYOK'))
    c.crypto.use_client_core(core)
    out = c.crypto.rewrap('k', ['ct'])
    assert_equal [[:rewrap, 'k', [{ ciphertext: 'ct' }]]], core.calls
    assert_equal 'core-rewrap', out.data['items'][0]['ciphertext']
  end

  def test_decrypt_and_rewrap_409_client_route_without_a_core_raise_unavailable
    %i[decrypt rewrap].each do |op|
      e = assert_raises(K9o::KError) { client(zk_409('client')).crypto.public_send(op, 'k', ['ct']) }
      assert_equal ['K9O_ZK_CLIENT_CORE_UNAVAILABLE', 501], [e.code, e.status]
      assert_equal({ 'custodyMode' => 'BYOK', 'requirement' => 'kibo-client-core' }, e.context)
    end
  end

  def test_other_409_and_errors_are_raised_unchanged_for_decrypt_and_rewrap
    core = FakeCore.new
    [zk_409('server'), err(409, 'K9O_ZK_STORE_FLOW_REQUIRED'), err(409, 'K9O_SEALED_UNDER_RETIRED_KEY', 'resealableUntil' => 'x'),
     err(400, 'K9O_ENVELOPE_INTEGRITY_FAILURE')].each do |bad|
      %i[decrypt rewrap].each do |op|
        c = client(bad)
        c.crypto.use_client_core(core)
        e = assert_raises(K9o::KError) { c.crypto.public_send(op, 'k', ['ct']) }
        assert_equal bad[1] && JSON.parse(bad[1])['code'], e.code
      end
    end
    assert_empty core.calls
  end

  TOKEN_DATA = { 'token' => 'eyJhbGciOiJSUzI1NiJ9.secret-payload.sig', 'expiresAt' => '2026-11-02T10:15:00Z', 'issuer' => 'https://acme.api-de01.k9o.io',
                 'subject' => 'svc_1', 'audience' => 'crypto:payments', 'kid' => 'kid-1' }.freeze

  def token_ok(data = TOKEN_DATA)
    [200, JSON.dump('data' => data, 'meta' => {})]
  end

  def test_federated_token_posts_crypt_and_op_and_returns_the_typed_result
    t = client(token_ok).crypto.federated_token('payments', 'decrypt')
    assert_equal ['POST /@portal/crypto/federated-token'], @http.paths
    assert_equal({ 'crypt' => 'payments', 'op' => 'decrypt' }, sent)
    assert_equal ['eyJhbGciOiJSUzI1NiJ9.secret-payload.sig', '2026-11-02T10:15:00Z', 'https://acme.api-de01.k9o.io', 'svc_1', 'crypto:payments', 'kid-1', nil, nil], t.to_a
    assert_equal 'kid-1', t.kid
    assert_equal '2026-11-02T10:15:00Z', t.expires_at
  end

  def test_federated_token_decodes_provider_and_project_id_when_the_gateway_names_them
    t = client(token_ok(TOKEN_DATA.merge('provider' => 'aws', 'projectId' => 'proj_1'))).crypto.federated_token('payments', 'decrypt')
    assert_equal 'aws', t.provider
    assert_equal 'proj_1', t.project_id
    assert_nil client(token_ok).crypto.federated_token('payments', 'decrypt').provider
    assert_includes t.inspect, 'provider="aws"'
  end

  def test_federated_token_accepts_each_op
    %w[encrypt decrypt rewrap].each do |op|
      client(token_ok).crypto.federated_token('k', op)
      assert_equal op, sent['op']
    end
  end

  def test_federated_token_refuses_a_bad_crypt_or_op_before_sending
    c = client(token_ok)
    ['Bad Ring', '', 'a' * 65, nil, :payments].each do |k|
      e = assert_raises(K9o::KError) { c.crypto.federated_token(k, 'encrypt') }
      assert_equal 'K9O_INVALID_FIELD_VALUE', e.code
    end
    ['sign', 'ENCRYPT', '', nil, :encrypt].each do |op|
      e = assert_raises(K9o::KError) { c.crypto.federated_token('payments', op) }
      assert_equal 'K9O_INVALID_FIELD_VALUE', e.code
    end
    assert_empty @http.reqs
  end

  def test_federated_token_passes_409_503_and_429_through_and_never_retries
    [[409, 'K9O_CUSTODY_SERVER_ROUTE'], [503, 'K9O_KEY_SERVICE_UNAVAILABLE'], [429, 'K9O_RATE_LIMITED']].each do |status, code|
      c = client(err(status, code), token_ok)
      e = assert_raises(K9o::KError) { c.crypto.federated_token('payments', 'encrypt') }
      assert_equal [code, status], [e.code, e.status]
      assert_equal 1, @http.reqs.size
    end
  end

  def test_federated_token_missing_field_is_a_malformed_response
    TOKEN_DATA.each_key do |field|
      e = assert_raises(K9o::KError) { client(token_ok(TOKEN_DATA.reject { |k, _| k == field })).crypto.federated_token('payments', 'encrypt') }
      assert_equal 'K9O_INTERNAL_ERROR', e.code
      refute_includes e.message, TOKEN_DATA['token']
    end
  end

  def test_federated_token_is_not_in_inspect_or_to_s
    t = client(token_ok).crypto.federated_token('payments', 'encrypt')
    [t.inspect, t.to_s, "#{t}", t.pretty_inspect].each do |text|
      refute_includes text, 'secret-payload'
      assert_includes text, 'kid-1'
    end
  end

  CRYPT = { 'name' => 'payments', 'status' => 'active', 'createdAt' => '2026-11-03T09:00:00Z', 'retiredAt' => nil }.freeze

  def crypt_ok(data = CRYPT, status = 200)
    [status, JSON.dump('data' => data, 'meta' => {})]
  end

  def test_crypts_list_returns_the_crypts
    retired = CRYPT.merge('name' => 'old', 'status' => 'retired', 'retiredAt' => '2026-11-03T10:00:00Z')
    out = client(crypt_ok('crypts' => [CRYPT, retired])).crypto.crypts_list
    assert_equal ['GET /@portal/crypto/crypts'], @http.paths
    assert_equal [CRYPT, retired], out.data['crypts']
  end

  def test_crypts_list_empty
    assert_equal [], client(crypt_ok('crypts' => [])).crypto.crypts_list.data['crypts']
  end

  def test_crypts_create_sends_only_the_name
    out = client(crypt_ok(CRYPT, 201)).crypto.crypts_create('payments')
    assert_equal ['POST /@portal/crypto/crypts'], @http.paths
    assert_equal({ 'name' => 'payments' }, sent)
    assert_equal CRYPT, out.data
  end

  def test_crypts_retire_sends_no_body_to_the_named_url
    retired = CRYPT.merge('status' => 'retired', 'retiredAt' => '2026-11-03T10:00:00Z')
    out = client(crypt_ok(retired)).crypto.crypts_retire('payments')
    assert_equal ['POST /@portal/crypto/crypts/payments/retire'], @http.paths
    assert_nil @http.posts.last.body
    assert_equal 'retired', out.data['status']
  end

  def test_crypts_bad_names_are_refused_before_sending
    c = client(crypt_ok)
    ['Bad Ring', '', 'actions', 'a' * 65, 'a/b', nil, :payments].each do |n|
      %i[crypts_create crypts_retire].each do |m|
        e = assert_raises(K9o::KError) { c.crypto.public_send(m, n) }
        assert_equal 'K9O_INVALID_FIELD_VALUE', e.code
        assert_equal 'name', e.context[:field] || e.context['field']
        assert_includes e.message, K9o::Crypto::CRYPT_RULE.sub('crypt must', 'name must')
      end
    end
    assert_empty @http.reqs
  end

  def test_crypts_gateway_refusals_pass_through
    [[409, 'K9O_CRYPT_ALREADY_EXISTS'], [409, 'K9O_CRYPT_LIMIT_EXCEEDED'], [409, 'K9O_CRYPT_RETIRED'], [404, 'K9O_CRYPT_NOT_FOUND'],
     [403, 'K9O_ACCESS_DENIED'], [403, 'K9O_IAM_POLICY_DENIED'], [403, 'K9O_RBAC_DENY']].each do |status, code|
      %i[crypts_create crypts_retire].each do |m|
        e = assert_raises(K9o::KError) { client(err(status, code)).crypto.public_send(m, 'payments') }
        assert_equal [code, status], [e.code, e.status]
      end
      e = assert_raises(K9o::KError) { client(err(status, code)).crypto.crypts_list }
      assert_equal code, e.code
    end
  end

  def test_crypts_malformed_answers_fail_closed
    bad = [CRYPT.reject { |k, _| k == 'name' }, CRYPT.merge('status' => 'paused'), CRYPT.reject { |k, _| k == 'createdAt' },
           CRYPT.merge('retiredAt' => 5), CRYPT.merge('retiredAt' => false), 'x', nil]
    bad.each do |d|
      e = assert_raises(K9o::KError) { client(crypt_ok(d)).crypto.crypts_create('payments') }
      assert_equal 'K9O_INTERNAL_ERROR', e.code
      assert_match(/\Acrypto\.crypts\.create: the gateway answered /, e.message)
      e = assert_raises(K9o::KError) { client(crypt_ok(d)).crypto.crypts_retire('payments') }
      assert_match(/\Acrypto\.crypts\.retire: the gateway answered /, e.message)
      e = assert_raises(K9o::KError) { client(crypt_ok('crypts' => [d])).crypto.crypts_list }
      assert_match(/\Acrypto\.crypts\.list: the gateway answered /, e.message)
    end
    [{}, { 'crypts' => 'x' }, nil].each do |d|
      e = assert_raises(K9o::KError) { client(crypt_ok(d)).crypto.crypts_list }
      assert_equal 'K9O_INTERNAL_ERROR', e.code
      assert_equal 'crypto.crypts.list: the gateway answered without crypts', e.message
    end
  end
end
