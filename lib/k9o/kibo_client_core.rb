# frozen_string_literal: true

require 'timeout'
require_relative 'kerror'
require_relative 'crypto'

module K9o
  # The client core for +client.crypto+ on a BYOK or HYOK project: it opens and seals data on this machine, against your
  # own KMS or HSM, so the platform never sees plaintext or the key. There is no crypto here. Sealing, opening, the key
  # pin and the token exchange all run in the audited Rust core (+kibo-kms-rest-ffi+, zk-bundle-v2.16.3 or later). This
  # class only sequences them:
  #
  #   federated token (platform) -> acquire_kms_credential (your cloud) -> app_crypto_seal / app_crypto_open (your KMS)
  #
  # Everything that picks a key, a provider, a role, a region or an endpoint comes from the configuration you pass here.
  # Nothing comes from the platform's answer: the token response's +provider+ and +project_id+ are checked against your
  # configuration, and a mismatch is refused, never followed.
  #
  #   core = K9o::KiboClientCore.new(
  #     provider: :aws, posture: :byok,
  #     key_ref: { version: 1, external_ref: key_arn },
  #     provider_config: { aws_region: 'eu-central-1' },
  #     federation: { provider: 'aws', role_arn: role_arn, session_name: 'app', region: 'eu-central-1',
  #                   key_arn: key_arn, duration_secs: 900 },
  #     expected_key_refs: [key_arn],                       # required
  #     federated_token: client.crypto.method(:federated_token),
  #     core: K9o::KiboFfiCore.new
  #   )
  #   client.crypto.use_client_core(core)
  #
  # +core:+ is the bound Kibo core: K9o::KiboFfiCore.new, which wraps the generated binding and the native library, or any
  # object that responds to +app_crypto_seal_blocking+, +app_crypto_open_blocking+, +acquire_kms_credential_blocking+ and
  # +core_capabilities+ (Ruby has no async, so it calls the +_blocking+ exports). Inputs are passed as Hashes with snake_case
  # keys, the field names of the core's input types; an answer may be a Hash or an object with the same readers.
  # Ciphertext is the base64 String of the container bytes.
  class KiboClientCore
    EXCHANGE_TIMEOUT = 'KIBO_EXCHANGE_TIMEOUT'
    CORE_FUNCTIONS = %i[app_crypto_seal_blocking app_crypto_open_blocking acquire_kms_credential_blocking
                        core_capabilities].freeze
    PROVIDER_WIRE = { aws: 'aws-kms', gcp: 'gcp-kms', azure: 'azure-kv', vault: 'hashicorp-vault' }.freeze
    POSTURES = %i[byok hyok].freeze
    OPS = %w[encrypt decrypt rewrap].freeze
    # Refresh a credential this long before it expires.
    SKEW_SECS = 60
    DEFAULT_DEADLINE_SECS = 30

    Cred = Struct.new(:secret, :expires_at_unix_secs) do
      def inspect
        "#<struct K9o::KiboClientCore::Cred secret=[redacted] expires_at_unix_secs=#{expires_at_unix_secs.inspect}>"
      end

      def to_s
        inspect
      end

      def to_h
        { secret: secret, expires_at_unix_secs: expires_at_unix_secs }
      end
    end
    private_constant :Cred

    # +provider+: :aws, :gcp, :azure or :vault, the same as +federation[:provider]+.
    # +posture+: :byok or :hyok.
    # +project_id+: the project id (+proj_...+), bound into what is sealed. Leave it out only if you want the token
    #   response's value; a value given here is never overridden.
    # +key_ref+: the exact key this application uses, +{ version:, external_ref: }+.
    # +provider_config+: +{ aws_region:, vault_address: }+ (only the ones you need).
    # +federation+: how to exchange the platform's identity token for a credential on your cloud (the core's
    #   FfiFederationSpec, with a String +provider+ of "aws", "gcp", "azure" or "vault"). For "vault" it is
    #   +{ provider: 'vault', vault_addr:, jwt_auth_mount:, role: }+, where +jwt_auth_mount+ is the JWT auth mount: the name
    #   Vault serves the JWT login under, "jwt" for +auth/jwt+ (not the transit mount, which comes from the key reference).
    #   It is handed to the core as the core's own +mount+ field.
    # +expected_key_refs+: the keys this application allows. Required and non-empty.
    # +federated_token+: anything that answers +call(crypt, op)+ with a Crypto::FederatedToken, for example
    #   +client.crypto.method(:federated_token)+.
    # +exchange_deadline+: seconds the exchange may take before it is abandoned. Default 30.
    # +now+: the host clock, a callable answering Unix seconds.
    def initialize(provider:, posture:, key_ref:, federation:, expected_key_refs:, federated_token:, core:,
                   project_id: nil, provider_config: {}, exchange_deadline: DEFAULT_DEADLINE_SECS,
                   now: -> { Time.now.to_i })
      @provider = provider.respond_to?(:to_sym) ? provider.to_sym : provider
      @federation = symbolize(federation)
      check_vault_federation(@federation) if @federation[:provider].to_s == 'vault'
      fed_provider = @federation[:provider].respond_to?(:to_sym) ? @federation[:provider].to_sym : @federation[:provider]
      raise bad('provider and federation.provider must be the same cloud', 'provider') unless @provider == fed_provider
      raise bad('provider must be :aws, :gcp, :azure or :vault', 'provider') unless PROVIDER_WIRE.key?(@provider)

      @posture = posture.respond_to?(:to_sym) ? posture.to_sym : posture
      raise bad('posture must be :byok or :hyok', 'posture') unless POSTURES.include?(@posture)

      @pin = check_pin(expected_key_refs)
      key_ref = symbolize(key_ref)
      @key_ref = { version: key_ref[:version], external_ref: key_ref[:external_ref] }
      unless @key_ref[:external_ref].is_a?(String) && Crypto.key_ref_matches?(@key_ref[:external_ref], @pin, provider: @provider)
        raise bad('key_ref is not in expected_key_refs', 'keyRef')
      end

      raise bad('federated_token must respond to call(crypt, op)', 'federatedToken') unless federated_token.respond_to?(:call)

      @project_id = project_id
      @provider_config = symbolize(provider_config)
      @federated_token = federated_token
      @core = core
      @deadline = exchange_deadline
      @now = now
      @creds = {}
      @mutex = Mutex.new
      @caps_checked = false
    end

    # Declares that this core enforces the key pin (see Crypto#use_client_core).
    def enforces_expected_key_refs?
      true
    end

    # Neither the cached credentials nor the callables appear here.
    def inspect
      "#<#{self.class.name} provider=#{@provider.inspect} posture=#{@posture.inspect}>"
    end

    def to_s
      inspect
    end

    def pretty_print(pp)
      pp.text(inspect)
    end

    # Seal each item's plaintext under the configured key. Items: +{ plaintext:, context: }+. Answers
    # +{ 'items' => [{ 'ok' => true, 'ciphertext' => base64 } | { 'ok' => false, 'code', 'message' }] }+.
    def encrypt(crypt, items, **options)
      pin = effective_pin(options)
      return refused(items.size) unless key_in_pin?(pin)

      core = loaded_core
      cred, project_id, secrets = credential(core, crypt, 'encrypt')
      out = items.map do |it|
        guard(secrets) do
          { 'ok' => true, 'ciphertext' => seal(core, cred, project_id, crypt, it[:plaintext], it[:context], pin, options) }
        end
      end
      { 'items' => out }
    end

    # Open each item's ciphertext. Answers +'plaintext'+ as a binary String (and +'text'+ when it is valid UTF-8).
    def decrypt(crypt, items, **options)
      pin = effective_pin(options)
      return refused(items.size) unless key_in_pin?(pin)

      core = loaded_core
      cred, project_id, secrets = credential(core, crypt, 'decrypt')
      out = items.map do |it|
        guard(secrets) do
          plain = open_item(core, cred, project_id, crypt, it[:ciphertext], it[:context], pin, options)
          item = { 'ok' => true, 'plaintext' => plain }
          text = plain.dup.force_encoding(Encoding::UTF_8)
          item['text'] = text if text.valid_encoding?
          item
        end
      end
      { 'items' => out }
    end

    # Open each item, then seal it again under the configured key, with a "rewrap" federated token.
    def rewrap(crypt, items, **options)
      pin = effective_pin(options)
      return refused(items.size) unless key_in_pin?(pin)

      core = loaded_core
      cred, project_id, secrets = credential(core, crypt, 'rewrap')
      out = items.map do |it|
        guard(secrets) do
          plain = open_item(core, cred, project_id, crypt, it[:ciphertext], it[:context], pin, options)
          { 'ok' => true, 'ciphertext' => seal(core, cred, project_id, crypt, plain, it[:context], pin, options) }
        end
      end
      { 'items' => out }
    end

    private

    def bad(message, field)
      KError.new(code: 'K9O_INVALID_FIELD_VALUE', message: message, context: { 'field' => field })
    end

    def symbolize(hash)
      raise bad('expected a Hash', 'config') unless hash.is_a?(Hash)

      hash.each_with_object({}) { |(k, v), acc| acc[k.to_sym] = v }
    end

    def check_vault_federation(fed)
      %i[vault_addr jwt_auth_mount role].each do |field|
        next if fed[field].is_a?(String) && !fed[field].strip.empty?

        raise bad("federation.#{field} is required for vault and must be a non-empty String", "federation.#{field}")
      end
    end

    # The spec as the core names its fields: the SDK's +jwt_auth_mount+ is the core's +mount+.
    def core_spec
      spec = @federation.dup
      spec[:mount] = spec.delete(:jwt_auth_mount) if spec.key?(:jwt_auth_mount)
      spec
    end

    def check_pin(refs)
      pin = Crypto.check_expected_key_refs(refs)
      if pin.nil?
        raise bad('expected_key_refs is required: this client never seals or opens without a key pin', 'expectedKeyRefs')
      end

      pin
    end

    def effective_pin(options)
      p = options[:expected_key_refs].nil? ? @pin : options[:expected_key_refs]
      unless p.is_a?(Array) && !p.empty?
        raise bad('expected_key_refs is empty: refusing to call without a key pin', 'expectedKeyRefs')
      end

      p
    end

    # The call's own pin is matched against the configured key before any token is fetched or any credential is exchanged;
    # the key version is ignored.
    def key_in_pin?(pin)
      Crypto.key_ref_matches?(@key_ref[:external_ref], pin, provider: @provider)
    end

    def refused(count)
      item = { 'ok' => false, 'code' => 'K9O_CRYPTO_UNEXPECTED_KEY',
               'message' => "the configured key is not in this call's expected_key_refs; nothing was sent" }
      { 'items' => Array.new(count) { item.dup } }
    end

    # The core, once it is known to be 2.16.3 or later and to declare that it enforces the pin. Nothing is fetched or sent
    # before this passes.
    def loaded_core
      CORE_FUNCTIONS.each do |fn|
        next if @core.respond_to?(fn)

        raise KError.new(code: 'KIBO_WASM_ERROR',
                         message: "the Kibo core does not export #{fn}; it is older than zk-bundle-v2.16.3",
                         context: { 'missing' => fn.to_s },
                         recommendation: 'Use a build of the Kibo binding that ships zk-bundle-v2.16.3 or later.')
      end
      unless @caps_checked
        unless Array(@core.core_capabilities).include?('expected_key_refs')
          raise KError.new(code: Crypto::KEY_PIN_UNENFORCED,
                           message: 'the Kibo core does not declare that it enforces expected_key_refs; nothing was sent',
                           recommendation: 'Use a build of the Kibo binding that ships zk-bundle-v2.16.3 or later.')
        end
        @caps_checked = true
      end
      @core
    end

    # [credential, project id, secrets to scrub from messages]
    def credential(core, crypt, op)
      t = @federated_token.call(crypt, op)
      named_provider = t.respond_to?(:provider) ? t.provider : nil
      if !named_provider.nil? && named_provider.to_s != @provider.to_s
        raise bad("the platform named provider \"#{named_provider}\"; this client is configured for \"#{@provider}\"", 'provider')
      end

      named = t.respond_to?(:project_id) ? t.project_id : nil
      if !named.nil? && !@project_id.nil? && named != @project_id
        raise bad('the platform named a different project than the one configured', 'projectId')
      end

      project_id = @project_id.nil? && named.is_a?(String) ? named : @project_id
      raise bad('project_id is not configured and the platform did not name one', 'projectId') if project_id.nil?

      key = [crypt, op, t.subject].join("\u0000")
      # A token is fetched on every call (it is bound to the call's crypt and op); the credential from the exchange is
      # reused until it is close to expiring.
      cached = @mutex.synchronize { @creds[key] }
      return [cached, project_id, [t.token, cached.secret]] if cached && cached.expires_at_unix_secs - SKEW_SECS > @now.call

      out = exchange(core, t.token)
      secret = read(out, :secret)
      expiry = read(out, :expires_at_unix_secs)
      unless secret.is_a?(String) && expiry.is_a?(Numeric)
        raise KError.new(code: 'KIBO_WASM_DECODE_ERROR', message: 'the core returned a credential without secret or expiry')
      end

      cred = Cred.new(secret, expiry)
      @mutex.synchronize { @creds[key] = cred }
      [cred, project_id, [t.token, secret]]
    end

    # acquire_kms_credential_blocking under a deadline. A blocking native call cannot be interrupted, so it runs on its
    # own thread and is abandoned when the deadline passes.
    def exchange(core, token)
      input = { spec: core_spec, identity_token: token, now_unix_secs: @now.call }
      worker = Thread.new do
        Thread.current.report_on_exception = false
        core.acquire_kms_credential_blocking(input)
      end
      unless worker.join(@deadline)
        worker.kill
        raise KError.new(code: EXCHANGE_TIMEOUT,
                         message: "the token exchange with your cloud did not finish within #{@deadline} s",
                         context: { 'deadlineSecs' => @deadline },
                         recommendation: "Check that your cloud's token endpoint is reachable from this host.")
      end
      worker.value
    rescue KError => e
      raise scrub_error(e, [token])
    rescue StandardError => e
      raise map_core_error(e, [token])
    end

    def common(cred, project_id, crypt, context, pin, options)
      {
        kms_cred: cred.to_h,
        provider_config: { aws_region: @provider_config[:aws_region], vault_address: @provider_config[:vault_address] },
        project_id: project_id,
        crypt: crypt,
        context: context,
        expected_key_refs: pin.dup
      }
    end

    def seal(core, cred, project_id, crypt, plaintext, context, pin, options)
      out = core.app_crypto_seal_blocking(
        { provider: PROVIDER_WIRE[@provider], posture: @posture.to_s, key_ref: @key_ref.dup,
          plaintext: plaintext.b }.merge(common(cred, project_id, crypt, context, pin, options))
      )
      [to_bytes(read(out, :container))].pack('m0')
    end

    def open_item(core, cred, project_id, crypt, ciphertext, context, pin, options)
      container = ciphertext.to_s.unpack1('m0')
      out = core.app_crypto_open_blocking(
        { container: container }.merge(common(cred, project_id, crypt, context, pin, options))
      )
      to_bytes(read(out, :plaintext))
    end

    def read(obj, name)
      if obj.is_a?(Hash)
        obj.key?(name) ? obj[name] : obj[name.to_s]
      elsif obj.respond_to?(name)
        obj.public_send(name)
      end
    end

    def to_bytes(value)
      return value.b if value.is_a?(String)
      return value.pack('C*') if value.is_a?(Array)

      raise KError.new(code: 'KIBO_WASM_DECODE_ERROR', message: 'the core returned a non-byte value where bytes were expected')
    end

    # One item's failure stays its own: the core's code passes through ("<CODE>: <message>"; UPSTREAM_KMS_ERROR is your
    # own KMS failing).
    def guard(secrets)
      yield
    rescue StandardError => e
      k = map_core_error(e, secrets)
      { 'ok' => false, 'code' => k.code, 'message' => k.message }
    end

    def map_core_error(error, secrets)
      return scrub_error(error, secrets) if error.is_a?(KError)

      raw = scrub(error.message.to_s, secrets)
      head = /\A([A-Z][A-Z0-9_]*):\s*(.*)\z/m.match(raw)
      KError.new(code: head ? head[1] : 'KIBO_WASM_ERROR', message: head ? head[2] : raw)
    end

    def scrub_error(error, secrets)
      message = scrub(error.message.to_s, secrets)
      return error if message == error.message.to_s

      KError.new(code: error.code, message: message, context: error.context, recommendation: error.recommendation)
    end

    def scrub(text, secrets)
      secrets.compact.reduce(text) { |acc, s| s.to_s.empty? ? acc : acc.gsub(s.to_s, '[redacted]') }
    end
  end
end
