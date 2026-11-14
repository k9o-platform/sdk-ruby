# frozen_string_literal: true

require 'minitest/autorun'
require 'json'
require 'pp'
require_relative '../lib/k9o'

# K9o::KiboClientCore against a fake core (the bound Rust core cannot be built in CI here).
class KiboClientCoreTest < Minitest::Test
  KEY = 'arn:aws:kms:eu-central-1:111122223333:key/mine'
  OTHER = 'arn:aws:kms:eu-central-1:111122223333:key/other'

  def tok(over = {})
    data = { token: 'jwt-secret', expires_at: 'x', issuer: 'i', subject: 'proj_1:crypt:c:op:encrypt', audience: 'a', kid: 'k',
             provider: 'aws', project_id: 'proj_1' }.merge(over)
    K9o::Crypto::FederatedToken.new(*data.values_at(:token, :expires_at, :issuer, :subject, :audience, :kid, :provider, :project_id))
  end

  class FakeCore
    attr_reader :log, :inputs
    attr_writer :caps, :on_seal, :on_exchange

    def initialize(log)
      @log = log
      @inputs = []
      @caps = ['expected_key_refs']
    end

    def core_capabilities
      @caps
    end

    def exchange_inputs
      @exchange_inputs ||= []
    end

    def acquire_kms_credential_blocking(input)
      exchange_inputs << input
      @log << "exchange:#{input[:identity_token]}"
      return @on_exchange.call(input) if @on_exchange

      { secret: 'cred-1', expires_at_unix_secs: 10_000 }
    end

    def app_crypto_seal_blocking(input)
      @inputs << input
      @log << "seal:#{input[:crypt]}:#{input[:project_id]}:#{input[:expected_key_refs].join(',')}"
      return @on_seal.call(input) if @on_seal

      { container: [1, 2, 3].pack('C*') + input[:plaintext] }
    end

    def app_crypto_open_blocking(input)
      @inputs << input
      @log << "open:#{input[:crypt]}:#{input[:expected_key_refs].join(',')}"
      raise 'K9O_CRYPTO_UNEXPECTED_KEY: no' if input[:container].getbyte(0) != 1

      { plaintext: input[:container].byteslice(3..-1) }
    end
  end

  def make(log, core: FakeCore.new(log), token: nil, **over)
    token ||= lambda do |crypt, op|
      log << "token:#{crypt}:#{op}"
      tok
    end
    K9o::KiboClientCore.new(
      provider: :aws, posture: :byok, project_id: 'proj_1',
      key_ref: { version: 1, external_ref: KEY },
      federation: { provider: 'aws', role_arn: 'arn:aws:iam::1:role/r', session_name: 's', region: 'eu-central-1', key_arn: KEY, duration_secs: 900 },
      expected_key_refs: [KEY], federated_token: token, core: core, now: -> { 1000 }, **over
    )
  end

  def pt(s = 'x')
    [{ plaintext: s.b }]
  end

  def code_of(&blk)
    assert_raises(K9o::KError, &blk).code
  end

  def test_encrypt_token_then_exchange_then_seal_round_trips_through_decrypt
    log = []
    core = make(log)
    enc = core.encrypt('c', pt('hi'))
    assert_equal ['token:c:encrypt', 'exchange:jwt-secret', "seal:c:proj_1:#{KEY}"], log
    ct = enc['items'][0]['ciphertext']
    dec = core.decrypt('c', [{ ciphertext: ct }])
    assert_equal 'hi', dec['items'][0]['text']
    assert_equal 'hi', K9o::Crypto.text(dec['items'][0])
  end

  def vault_core(log, federation, core: FakeCore.new(log))
    K9o::KiboClientCore.new(
      provider: :vault, posture: :byok, project_id: 'proj_1', key_ref: { version: 1, external_ref: 'transit/keys/k' },
      federation: federation, expected_key_refs: ['transit/keys/k'], federated_token: ->(_c, _o) { tok(provider: 'vault') },
      core: core, now: -> { 1000 }
    )
  end

  def test_vault_federation_jwt_auth_mount_reaches_the_core_as_its_mount_field
    log = []
    core = FakeCore.new(log)
    vault_core(log, { provider: 'vault', vault_addr: 'https://v', jwt_auth_mount: 'jwt', role: 'r' }, core: core).encrypt('c', pt)
    assert_equal({ provider: 'vault', vault_addr: 'https://v', mount: 'jwt', role: 'r' }, core.exchange_inputs.last[:spec])
  end

  def test_vault_federation_needs_vault_addr_jwt_auth_mount_and_role
    ok = { provider: 'vault', vault_addr: 'https://v', jwt_auth_mount: 'jwt', role: 'r' }
    %i[vault_addr jwt_auth_mount role].each do |field|
      e = assert_raises(K9o::KError) { vault_core([], ok.reject { |k, _| k == field }) }
      assert_equal 'K9O_INVALID_FIELD_VALUE', e.code
      assert_equal "federation.#{field}", e.context['field']
    end
    assert_raises(K9o::KError) { vault_core([], ok.merge(jwt_auth_mount: '')) }
    # the core's own field name is not accepted in place of the SDK's
    assert_raises(K9o::KError) { vault_core([], { provider: 'vault', vault_addr: 'https://v', mount: 'jwt', role: 'r' }) }
  end

  def test_declares_it_enforces_the_pin
    assert_equal true, make([]).enforces_expected_key_refs?
  end

  def test_refuses_to_be_built_without_a_pin_with_an_empty_pin_or_with_a_key_outside_the_pin
    assert_match(/is required/, assert_raises(K9o::KError) { make([], expected_key_refs: nil) }.message)
    assert_raises(K9o::KError) { make([], expected_key_refs: []) }
    e = assert_raises(K9o::KError) { make([], expected_key_refs: [OTHER]) }
    assert_match(/key_ref/, e.message)
  end

  def test_an_empty_pin_from_the_router_reaches_no_network_and_no_kms
    log = []
    core = make(log)
    e = assert_raises(K9o::KError) { core.decrypt('c', [{ ciphertext: 'AQID' }], expected_key_refs: []) }
    assert_match(/key pin/, e.message)
    assert_raises(K9o::KError) { core.encrypt('c', pt, expected_key_refs: []) }
    assert_empty log
  end

  def test_a_per_call_pin_without_the_configured_key_is_refused_before_token_exchange_seal_or_open
    log = []
    core = make(log)
    r = core.encrypt('c', pt + pt, expected_key_refs: [OTHER])
    assert_equal 2, r['items'].size
    r['items'].each { |i| assert_equal 'K9O_CRYPTO_UNEXPECTED_KEY', i['code'] }
    assert_equal 'K9O_CRYPTO_UNEXPECTED_KEY', core.decrypt('c', [{ ciphertext: 'AQID' }], expected_key_refs: [OTHER])['items'][0]['code']
    assert_equal 'K9O_CRYPTO_UNEXPECTED_KEY', core.rewrap('c', [{ ciphertext: 'AQID' }], expected_key_refs: [OTHER])['items'][0]['code']
    assert_empty log
    ok = core.encrypt('c', pt, expected_key_refs: [KEY])
    assert_equal true, ok['items'][0]['ok']
    assert_equal ['token:c:encrypt', 'exchange:jwt-secret', "seal:c:proj_1:#{KEY}"], log
  end

  def test_the_pin_from_the_router_is_the_one_passed_to_the_core
    log = []
    make(log).encrypt('c', pt, expected_key_refs: [KEY, OTHER])
    assert_equal "seal:c:proj_1:#{KEY},#{OTHER}", log.last
  end

  def test_a_core_that_does_not_list_expected_key_refs_is_refused_before_any_token_is_fetched
    log = []
    fake = FakeCore.new(log)
    fake.caps = []
    assert_equal 'K9O_CRYPTO_KEY_PIN_UNENFORCED', code_of { make(log, core: fake).encrypt('c', pt) }
    assert_empty log
  end

  def test_an_older_core_without_the_new_functions_is_refused
    log = []
    old = Object.new
    def old.core_capabilities
      ['expected_key_refs']
    end
    assert_equal 'KIBO_WASM_ERROR', code_of { make(log, core: old).encrypt('c', pt) }
    assert_empty log
  end

  def test_a_response_naming_another_provider_or_project_is_refused_and_nothing_is_exchanged
    [{ provider: 'gcp' }, { project_id: 'proj_other' }].each do |over|
      log = []
      core = make(log, token: ->(_c, _o) { tok(over) })
      assert_equal 'K9O_INVALID_FIELD_VALUE', code_of { core.encrypt('c', pt) }
      assert_empty log
    end
  end

  def test_project_id_comes_from_the_response_only_when_not_configured
    log = []
    make(log, project_id: nil).encrypt('c', pt)
    assert_equal "seal:c:proj_1:#{KEY}", log.last
    none = make([], project_id: nil, token: ->(_c, _o) { tok(project_id: nil) })
    assert_equal 'K9O_INVALID_FIELD_VALUE', code_of { none.encrypt('c', pt) }
  end

  def test_a_token_without_provider_or_project_is_accepted_when_configured
    log = []
    make(log, token: ->(_c, _o) { tok(provider: nil, project_id: nil) }).encrypt('c', pt)
    assert_equal "seal:c:proj_1:#{KEY}", log.last
  end

  def test_the_exchanged_credential_is_reused_until_near_expiry_then_exchanged_again
    log = []
    t = 1000
    core = make(log, now: -> { t })
    2.times { core.encrypt('c', pt) }
    assert_equal 1, log.count { |l| l.start_with?('exchange') }
    assert_equal 2, log.count { |l| l.start_with?('token') }
    t = 9_950 # inside the 60 s skew of 10_000
    core.encrypt('c', pt)
    assert_equal 2, log.count { |l| l.start_with?('exchange') }
  end

  def test_the_credential_cache_is_per_op
    log = []
    core = make(log)
    core.encrypt('c', pt)
    core.decrypt('c', [{ ciphertext: 'AQID' }])
    assert_equal 2, log.count { |l| l.start_with?('exchange') }
  end

  def test_a_stalled_exchange_is_abandoned_at_the_deadline
    fake = FakeCore.new([])
    fake.on_exchange = ->(_i) { sleep }
    started = Time.now
    assert_equal 'KIBO_EXCHANGE_TIMEOUT', code_of { make([], core: fake, exchange_deadline: 0.05).encrypt('c', pt) }
    assert_operator Time.now - started, :<, 5
  end

  def test_one_bad_item_fails_on_its_own_and_carries_the_cores_code_the_others_succeed
    core = make([])
    good = core.encrypt('c', pt("\x09"))['items'][0]
    r = core.decrypt('c', [{ ciphertext: 'AAAA' }, { ciphertext: good['ciphertext'] }])
    assert_equal false, r['items'][0]['ok']
    assert_equal 'K9O_CRYPTO_UNEXPECTED_KEY', r['items'][0]['code']
    assert_equal 'no', r['items'][0]['message']
    assert_equal true, r['items'][1]['ok']
  end

  def test_the_users_own_kms_failure_keeps_its_code
    fake = FakeCore.new([])
    fake.on_seal = ->(_i) { raise 'UPSTREAM_KMS_ERROR: denied' }
    r = make([], core: fake).encrypt('c', pt)
    assert_equal({ 'ok' => false, 'code' => 'UPSTREAM_KMS_ERROR', 'message' => 'denied' }, r['items'][0])
  end

  def test_rewrap_opens_and_seals_under_the_configured_key_with_the_rewrap_token
    log = []
    core = make(log)
    ct = core.encrypt('c', pt("\x07"))['items'][0]['ciphertext']
    log.clear
    r = core.rewrap('c', [{ ciphertext: ct }])
    assert_equal true, r['items'][0]['ok']
    assert_equal 'token:c:rewrap', log[0]
    assert_equal %w[open seal], log.last(2).map { |l| l.split(':')[0] }
  end

  def test_decrypt_uses_the_decrypt_token
    log = []
    make(log).decrypt('c', [{ ciphertext: 'AQID' }])
    assert_equal 'token:c:decrypt', log[0]
  end

  def test_neither_the_token_nor_the_credential_appears_in_an_item_failure
    fake = FakeCore.new([])
    fake.on_seal = ->(_i) { raise 'UPSTREAM_KMS_ERROR: denied for jwt-secret with cred-1' }
    s = JSON.dump(make([], core: fake).encrypt('c', pt))
    refute_includes s, 'jwt-secret'
    refute_includes s, 'cred-1'
  end

  def test_neither_the_token_nor_the_credential_appears_in_a_call_level_error
    fake = FakeCore.new([])
    fake.on_exchange = ->(_i) { raise 'UPSTREAM_KMS_ERROR: bad token jwt-secret' }
    e = assert_raises(K9o::KError) { make([], core: fake).encrypt('c', pt) }
    assert_equal 'UPSTREAM_KMS_ERROR', e.code
    refute_includes e.message, 'jwt-secret'
  end

  def test_inspect_and_to_s_leave_out_credentials
    core = make([])
    core.encrypt('c', pt)
    [core.inspect, core.to_s, core.pretty_inspect].each do |s|
      refute_includes s, 'cred-1'
      refute_includes s, 'jwt-secret'
    end
  end

  def test_the_key_provider_and_region_come_from_configuration
    log = []
    fake = FakeCore.new(log)
    make(log, core: fake, provider_config: { aws_region: 'eu-central-1' }).encrypt('c', pt)
    i = fake.inputs.last
    assert_equal 'aws-kms', i[:provider]
    assert_equal 'byok', i[:posture]
    assert_equal({ version: 1, external_ref: KEY }, i[:key_ref])
    assert_equal({ aws_region: 'eu-central-1', vault_address: nil }, i[:provider_config])
  end

  def test_registers_as_the_client_core
    core = make([])
    crypto = K9o::Crypto.new(Struct.new(:expected_key_refs).new(nil))
    assert_same core, crypto.use_client_core(core)
  end
end
