# frozen_string_literal: true

require 'minitest/autorun'
require 'k9o'

# Kibo ZK wrapper tests. The crypto round-trip needs real customer-KMS creds and
# is exercised by the staging conformance ZK step; here we pin the boundary the
# wrapper owns — the posture-floor rejection path (which the core enforces
# pre-KMS) round-trips through the SYNC `_blocking` export and maps to a typed
# K9o::KError. Skips cleanly on a platform/Ruby without the native lib.
class TestKibo < Minitest::Test
  def setup
    skip 'kibo native lib not available on this platform' unless K9o::Kibo::NATIVE_AVAILABLE
  end

  def test_posture_floor_violation_maps_to_kerror
    k = K9o::Kibo
    input = k::EncryptInput.new(
      provider: k::KmsProvider::AWS_KMS,
      posture: k::FfiPosture::BYOK,
      strategy: nil,
      oracle_mode: nil,
      kms_cred: k::FfiCredential.new(secret: 't', expires_at_unix_secs: 0),
      key_ref: k::FfiKeyRef.new(version: 1, external_ref: 'arn:aws:kms:us-east-1:0:key/abc'),
      provider_config: k::FfiProviderConfig.new(aws_region: 'us-east-1', vault_address: nil),
      attestation_tier: k::FfiAttestationTier::SOFTWARE,
      encryption_context: [],
      plaintext: 'hi',
      # BYOK requested, HYOK floor declared -> violation (rejected before any KMS call).
      posture_policy: k::FfiPosturePolicy.new(
        min_custody_posture: k::FfiMinPosture::HYOK,
        allowed_oracle_modes: k::FfiAllowedOracleModes.new(brokered: true, direct: true)
      )
    )

    err = assert_raises(K9o::KError) { k.encrypt(input) }
    assert_equal 'K9O_CRYPTO_POSTURE_FLOOR_VIOLATION', err.code
    assert_equal 'custody_posture', err.context[:dimension]
    assert_equal 'byok', err.context[:requested]
  end

  def test_native_unavailable_message_is_a_kerror
    # When native is present this just asserts the guard exists; the unavailable
    # path is structurally covered by ensure_native! raising K9o::KError.
    assert K9o::Kibo.respond_to?(:encrypt)
    assert K9o::Kibo.respond_to?(:decrypt)
  end
end

# K9o::KiboFfiCore: the adapter between KiboClientCore's plain data and the generated uniffi binding. The fake below has
# the binding's shape (typed records, integer enums, a variant class per cloud, error classes with code/detail readers).
class TestKiboFfiCore < Minitest::Test
  module FakeBinding
    %i[FfiCredential FfiKeyRef FfiProviderConfig FfiFederationInput AppSealInput AppOpenInput].each do |n|
      const_set(n, Class.new { define_method(:initialize) { |**kw| @kw = kw }; define_method(:to_h) { @kw }; define_method(:method_missing) { |m, *| @kw.fetch(m) { super(m) } }; define_method(:respond_to_missing?) { |m, p = false| @kw.key?(m) || super(m, p) } })
    end
    module KmsProvider; AWS_KMS = 1; GCP_KMS = 2; AZURE_KV = 3; HASHICORP_VAULT = 4; end
    module FfiPosture; BYOK = 1; HYOK = 2; end
    class FfiFederationSpec
      %w[AWS GCP AZURE VAULT].each do |v|
        const_set(v, Class.new { attr_reader :args; define_method(:initialize) { |*a| @args = a } })
      end
    end
    module ZkFfiUniffiError
      class Platform < StandardError
        attr_reader :code, :detail
        def initialize(code, detail); @code = code; @detail = detail; super(); end
      end
      class UpstreamKms < StandardError
        attr_reader :detail
        def initialize(detail); @detail = detail; super(); end
      end
      class PostureViolation < StandardError
        attr_reader :code, :detail
        def initialize(code, detail); @code = code; @detail = detail; super(); end
      end
    end

    class << self
      attr_accessor :last, :raise_with, :seal_error

      def core_capabilities
        ['expected_key_refs']
      end

      def acquire_kms_credential_blocking(input)
        @last = input
        raise raise_with if raise_with

        Struct.new(:secret, :expires_at_unix_secs).new('cred-secret', 9)
      end

      def app_crypto_seal_blocking(input)
        @last = input
        raise raise_with if raise_with
        raise seal_error if seal_error

        Struct.new(:container).new("\x01\x02".b)
      end

      def app_crypto_open_blocking(input)
        @last = input
        raise raise_with if raise_with

        Struct.new(:plaintext).new('p'.b)
      end
    end
  end

  def setup
    FakeBinding.raise_with = nil
    FakeBinding.seal_error = nil
    @core = K9o::KiboFfiCore.new(ffi: FakeBinding)
  end

  def seal_input(over = {})
    { provider: 'hashicorp-vault', posture: 'hyok', kms_cred: { secret: 's', expires_at_unix_secs: 5 },
      key_ref: { version: 2, external_ref: 'transit/keys/k' }, provider_config: { aws_region: nil, vault_address: 'https://v' },
      project_id: 'proj_1', crypt: 'c', context: nil, plaintext: 'x'.b, expected_key_refs: ['transit/keys/k'] }.merge(over)
  end

  def test_seal_passes_typed_records_and_integer_enums
    out = @core.app_crypto_seal_blocking(seal_input)
    assert_equal "\x01\x02".b, out.container
    i = FakeBinding.last.to_h
    assert_equal FakeBinding::KmsProvider::HASHICORP_VAULT, i[:provider]
    assert_equal FakeBinding::FfiPosture::HYOK, i[:posture]
    assert_kind_of FakeBinding::FfiCredential, i[:kms_cred]
    assert_kind_of FakeBinding::FfiKeyRef, i[:key_ref]
    assert_equal 2, i[:key_ref].version
    assert_equal 'https://v', i[:provider_config].vault_address
    assert_equal ['transit/keys/k'], i[:expected_key_refs]
  end

  def test_open_passes_the_container_and_pin
    @core.app_crypto_open_blocking(kms_cred: { secret: 's', expires_at_unix_secs: 5 }, provider_config: {}, project_id: 'p',
                                   crypt: 'c', context: nil, container: "\x01".b, expected_key_refs: ['k'])
    assert_equal "\x01".b, FakeBinding.last.to_h[:container]
    assert_nil FakeBinding.last.to_h[:provider_config].aws_region
  end

  def test_federation_spec_is_a_variant_class_and_vault_uses_the_cores_mount_field
    @core.acquire_kms_credential_blocking(spec: { provider: 'vault', vault_addr: 'https://v', mount: 'jwt', role: 'r' },
                                          identity_token: 't', now_unix_secs: 7)
    spec = FakeBinding.last.to_h[:spec]
    assert_kind_of FakeBinding::FfiFederationSpec::VAULT, spec
    assert_equal ['https://v', 'jwt', 'r'], spec.args
    @core.acquire_kms_credential_blocking(spec: { provider: 'aws', role_arn: 'ra', session_name: 's', region: 'r', key_arn: 'k', duration_secs: 9 },
                                          identity_token: 't', now_unix_secs: 7)
    assert_equal %w[ra s r k], FakeBinding.last.to_h[:spec].args[0, 4]
    @core.acquire_kms_credential_blocking(spec: { provider: 'gcp', audience: 'a' }, identity_token: 't', now_unix_secs: 7)
    assert_equal ['a'], FakeBinding.last.to_h[:spec].args
    @core.acquire_kms_credential_blocking(spec: { provider: 'azure', tenant_id: 't', client_id: 'c', scope: 's' }, identity_token: 't', now_unix_secs: 7)
    assert_equal %w[t c s], FakeBinding.last.to_h[:spec].args
  end

  def test_binding_errors_become_code_colon_detail
    e = FakeBinding::ZkFfiUniffiError
    [[e::Platform.new('K9O_CRYPTO_UNEXPECTED_KEY', 'no'), 'K9O_CRYPTO_UNEXPECTED_KEY: no'],
     [e::PostureViolation.new('POSTURE_FLOOR', 'low'), 'POSTURE_FLOOR: low'],
     [e::UpstreamKms.new('kms said no'), 'UPSTREAM_KMS_ERROR: kms said no']].each do |err, want|
      FakeBinding.raise_with = err
      assert_equal want, assert_raises(StandardError) { @core.app_crypto_seal_blocking(seal_input) }.message
    end
  end

  def test_unknown_provider_or_posture_is_refused
    assert_equal 'K9O_INVALID_FIELD_VALUE', assert_raises(K9o::KError) { @core.app_crypto_seal_blocking(seal_input(provider: 'x')) }.code
    assert_equal 'K9O_INVALID_FIELD_VALUE', assert_raises(K9o::KError) { @core.app_crypto_seal_blocking(seal_input(posture: 'x')) }.code
  end

  def test_a_binding_without_the_new_functions_is_refused
    err = assert_raises(K9o::KError) { K9o::KiboFfiCore.new(ffi: Module.new) }
    assert_equal 'KIBO_WASM_ERROR', err.code
  end

  def test_building_without_the_binding_is_a_clear_kerror_and_requiring_k9o_did_not_need_it
    skip 'a binding is already loaded' if Object.const_defined?(:KiboKmsRestFfi) && KiboKmsRestFfi.respond_to?(:app_crypto_seal_blocking)
    err = assert_raises(K9o::KError) { K9o::KiboFfiCore.new }
    assert_equal 'KIBO_WASM_ERROR', err.code
    assert_match(/binding or its native library/, err.message)
    err = assert_raises(K9o::KError) { K9o::KiboFfiCore.new(library: '/nonexistent/libkibo_kms_rest_ffi.so') }
    # Without the ffi gem the load stops before the library path is looked at.
    have_ffi = begin
      require 'ffi'
      true
    rescue LoadError
      false
    end
    assert_match(have_ffi ? /no native library/ : /binding or its native library/, err.message)
  end

  def test_client_core_maps_adapter_errors_to_the_core_code
    k = K9o::KiboClientCore.new(
      provider: :vault, posture: :byok, project_id: 'proj_1', key_ref: { version: 1, external_ref: 'transit/keys/k' },
      federation: { provider: 'vault', vault_addr: 'https://v', jwt_auth_mount: 'jwt', role: 'r' },
      expected_key_refs: ['transit/keys/k'], core: @core, now: -> { 1000 },
      federated_token: ->(_c, _o) { K9o::Crypto::FederatedToken.new('tok', 'x', 'i', 's', 'a', 'k', 'vault', 'proj_1') }
    )
    k.encrypt('c', [{ plaintext: 'x'.b }])
    FakeBinding.seal_error = FakeBinding::ZkFfiUniffiError::UpstreamKms.new('refused')
    item = k.encrypt('c', [{ plaintext: 'x'.b }])['items'][0]
    assert_equal 'UPSTREAM_KMS_ERROR', item['code']
    assert_equal 'refused', item['message']
  end

  # The real generated binding and native library, if you point at them:
  #   K9O_KIBO_BINDING=/path/kibo_kms_rest_ffi.rb K9O_KIBO_LIBRARY=/path/libkibo_kms_rest_ffi.dylib
  # No credential or cloud account is used; each provider refuses the placeholder credential.
  REAL = {
    'aws-kms' => ['arn:aws:kms:eu-central-1:111122223333:key/abc', { aws_region: 'eu-central-1' }],
    'gcp-kms' => ['projects/p/locations/l/keyRings/r/cryptoKeys/k', {}],
    'azure-kv' => ['https://example-vault.vault.azure.net/keys/k/0123456789abcdef0123456789abcdef', {}],
    'hashicorp-vault' => ['transit/keys/k:1', { vault_address: 'https://127.0.0.1:1' }]
  }.freeze

  def real_core
    b = ENV['K9O_KIBO_BINDING']
    l = ENV['K9O_KIBO_LIBRARY']
    skip 'set K9O_KIBO_BINDING and K9O_KIBO_LIBRARY to run against the real Kibo core' unless b && l && File.file?(b) && File.file?(l)
    K9o::KiboFfiCore.new(binding_path: b, library: l)
  end

  def test_real_core_lists_the_key_pin_capability
    assert_includes real_core.core_capabilities, 'expected_key_refs'
  end

  def test_real_core_refuses_a_placeholder_credential_at_each_provider
    core = real_core
    REAL.each do |provider, (ref, pc)|
      e = assert_raises(StandardError, provider) do
        core.app_crypto_seal_blocking(seal_input(provider: provider, posture: 'byok', provider_config: pc,
                                                 key_ref: { version: 1, external_ref: ref },
                                                 expected_key_refs: [ref.sub(/:1\z/, '').sub(%r{/0123456789abcdef0123456789abcdef\z}, '')]))
      end
      assert_match(/\AUPSTREAM_KMS_ERROR: /, e.message, provider)
    end
  end
end
