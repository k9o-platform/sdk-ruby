# frozen_string_literal: true

require 'json'

module K9o
  # client.crypto: application encryption with the project's key. The caller never names a key. The calls route by
  # custody (see "Routing" below): a platform-managed key is used at the API; a key in the customer's own KMS or HSM
  # (BYOK or HYOK) is used by a registered client core, so the platform never sees plaintext.
  #
  #   encrypt(crypt, items)   POST /@<slug>/crypto/encrypt   items: [{ plaintext:, context: }]
  #   decrypt(crypt, items)   POST /@<slug>/crypto/decrypt   items: [{ ciphertext:, context: }]
  #   rewrap(crypt, items)    POST /@<slug>/crypto/rewrap    items: [{ ciphertext:, context: }]
  #   federated_token(crypt, op)  POST /@<slug>/crypto/federated-token   op: "encrypt", "decrypt" or "rewrap"
  #   crypts_list                 GET  /@<slug>/crypto/crypts
  #   crypts_create(name)         POST /@<slug>/crypto/crypts            body: { name: }
  #   crypts_retire(name)         POST /@<slug>/crypto/crypts/<name>/retire   no body
  #
  # An item is a Hash (symbol or string keys) or, for brevity, a bare String (the plaintext, or the ciphertext).
  # Plaintext goes in as a String of bytes (any encoding; its bytes are sent) and comes back as a binary String;
  # the SDK does the base64 on both sides. A ciphertext is the base64 String the gateway gave you: one opaque container
  # that the SDK never parses. +context+ is an optional String of at most 256 bytes; the same +crypt+ and +context+
  # must be given on decrypt.
  #
  # The answer is an Envelope whose +data+ is { "items" => [...] } in the order sent. Each item is
  # { "ciphertext" } (encrypt, rewrap), { "plaintext" } (decrypt, decoded to bytes) or { "code", "message" } for an item
  # that failed on its own; fields the SDK does not know are kept as they are. A call-level failure raises K9o::KError:
  # 400 K9O_ENVELOPE_INTEGRITY_FAILURE (every cannot-open, with no reason, on purpose), 409
  # K9O_SEALED_UNDER_RETIRED_KEY (+context["resealableUntil"]+ while #rewrap can still fix it), 413
  # K9O_PAYLOAD_TOO_LARGE, 429 K9O_RATE_LIMITED (+retry_after_sec+), 503 K9O_KEY_SERVICE_UNAVAILABLE (fails the whole
  # call).
  #
  # Routing. #encrypt checks the project's custody mode on every call (GET crypto/mode, never cached), then sends
  # plaintext to the API only for a platform-managed, confidential-workload or SKR project (the body carries the
  # +custodyEpoch+ from the check). A BYOK or HYOK project goes to the client core; an unknown mode or a failed check
  # sends nothing. If the API answers 409 K9O_ZK_STORE_FLOW_REQUIRED (custody moved between check and send), the mode
  # is checked again and the call is routed once more; a second 409 is raised. #decrypt and #rewrap route by the
  # ciphertext: they go to the API first, and a 409 K9O_ZK_STORE_FLOW_REQUIRED whose +context["route"]+ is "client"
  # reroutes the same call to the client core. With no client core registered (#use_client_core), a call that needs
  # one raises K9o::KError K9O_ZK_CLIENT_CORE_UNAVAILABLE (501).
  # The SDK checks the crypt, the item count and the sizes before sending, with the same codes. It never retries
  # these calls on its own.
  class Crypto
    CRYPT_PATTERN = /\A(?!actions\z)[a-z0-9-]{1,64}\z/.freeze
    MAX_ITEMS = 100
    MAX_ITEM_BYTES = 64 * 1024
    MAX_CALL_BYTES = 1024 * 1024
    MAX_CONTEXT_BYTES = 256

    ZK_STORE_FLOW_REQUIRED = 'K9O_ZK_STORE_FLOW_REQUIRED'
    ZK_CLIENT_CORE_UNAVAILABLE = 'K9O_ZK_CLIENT_CORE_UNAVAILABLE'
    CUSTODY_MODE_UNKNOWN = 'K9O_CRYPTO_CUSTODY_UNKNOWN'
    KEY_PIN_UNENFORCED = 'K9O_CRYPTO_KEY_PIN_UNENFORCED'
    # 404 on encrypt: the crypt name is not registered. 409 on encrypt: the crypt name is retired. Both pass through as KError.
    CRYPT_NOT_FOUND = 'K9O_CRYPT_NOT_FOUND'
    CRYPT_RETIRED = 'K9O_CRYPT_RETIRED'
    # Gateway refusals of crypts_create and crypts_retire; they pass through as KError.
    CRYPT_ALREADY_EXISTS = 'K9O_CRYPT_ALREADY_EXISTS'
    CRYPT_LIMIT_EXCEEDED = 'K9O_CRYPT_LIMIT_EXCEEDED'
    CRYPT_RULE = 'crypt must be 1 to 64 characters of a-z, 0-9 and "-", and not "actions"'
    CRYPT_STATUSES = %w[active retired].freeze
    SERVER_MODES = %w[PLATFORM_MANAGED CONFIDENTIAL_WORKLOAD SKR].freeze
    CLIENT_MODES = %w[BYOK HYOK].freeze
    CLIENT_CORE_METHODS = %i[encrypt decrypt rewrap].freeze

    # The answer of GET crypto/mode: the project's custody mode and the opaque epoch that changes with every custody
    # transition. +route+ is "client" or "server" when the gateway named one, otherwise nil (an older gateway, or a value this
    # SDK does not know): follow it, do not infer the route from +custody_mode+.
    Mode = Struct.new(:custody_mode, :epoch, :route)

    TOKEN_OPS = %w[encrypt decrypt rewrap].freeze
    TOKEN_FIELDS = %w[token expiresAt issuer subject audience kid].freeze

    # The answer of POST crypto/federated-token: a short-lived RS256 JWT (+token+, valid for at most 15 minutes) for
    # the crypt and operation asked, with +expires_at+ (date-time String), +issuer+, +subject+, +audience+ and the
    # signing +kid+. When the gateway names them, +provider+ (the cloud, for example "aws") and +project_id+ (the +projectId+
    # field) are decoded too, otherwise they are nil; they are only ever checked against your configuration, never followed.
    # The token is a credential: +inspect+, +to_s+ and +pp+ leave it out.
    FederatedToken = Struct.new(:token, :expires_at, :issuer, :subject, :audience, :kid, :provider, :project_id) do
      def inspect
        extra = +''
        extra << " provider=#{provider.inspect}" unless provider.nil?
        extra << " project_id=#{project_id.inspect}" unless project_id.nil?
        "#<struct K9o::Crypto::FederatedToken token=[redacted] expires_at=#{expires_at.inspect} issuer=#{issuer.inspect} " \
          "subject=#{subject.inspect} audience=#{audience.inspect} kid=#{kid.inspect}#{extra}>"
      end

      def to_s
        inspect
      end

      def pretty_print(pp)
        pp.text(inspect)
      end
    end

    def initialize(config)
      @config = config
      @client_core = nil
    end

    # Register the client core: an object with +encrypt(crypt, items, **options)+, +decrypt(crypt, items, **options)+ and
    # +rewrap(crypt, items, **options)+. This is the hook the Ruby Kibo binding fills. When the client was built with
    # +expected_key_refs:+ the router passes it as the keyword +expected_key_refs:+ (a frozen Array of String) on every
    # call, and the core must refuse a key whose reference (version ignored, see Crypto.key_ref_matches?) is not in it,
    # before it uses any token or makes any network call. The keyword is absent when the option was not set. A core
    # declares that it does this with a method +enforces_expected_key_refs?+ that returns true; with the option set and
    # no such declaration the call raises K9o::KError K9O_CRYPTO_KEY_PIN_UNENFORCED before the core is called. Items are Hashes with symbol keys
    # ({ plaintext:, context: } with binary plaintext bytes, or { ciphertext:, context: }; +context+ only when given).
    # Each method answers the per-item results (an Array of item Hashes in the order given, or a Hash or Envelope whose
    # data holds "items"), with plaintext as bytes and ciphertext as the base64 String. Pass nil to remove it. Returns the core.
    def use_client_core(core)
      unless core.nil? || CLIENT_CORE_METHODS.all? { |m| core.respond_to?(m) }
        raise invalid('client core must respond to encrypt, decrypt and rewrap')
      end

      @client_core = core
    end

    # The project's custody mode and epoch right now (GET crypto/mode), as a Mode with +custody_mode+, +epoch+ and +route+.
    # With +crypt:+ the gateway authorizes the caller on that crypt (a personal access token or workload policy scoped to
    # named crypts is refused without one); the crypt is checked first (K9O_INVALID_FIELD_VALUE) and nothing is sent if invalid.
    def mode(crypt: nil)
      slug = Studio.require_project_slug(@config, 'crypto')
      unless crypt.nil? || (crypt.is_a?(String) && CRYPT_PATTERN.match?(crypt))
        raise invalid('crypt must be 1 to 64 characters of a-z, 0-9 and -, and not "actions"', crypt: crypt)
      end
      data = mode_answer(slug, crypt)
      route = %w[client server].include?(data['route']) ? data['route'] : nil
      Mode.new(data['custodyMode'], data['epoch'], route)
    end

    # Encrypt each item's plaintext (up to 64 KiB each and 1 MiB per call). A crypt is a registered name. The gateway can
    # answer 404 K9O_CRYPT_NOT_FOUND (name not registered) or 409 K9O_CRYPT_RETIRED (name retired); both raise K9o::KError
    # unchanged. Decrypt and rewrap are not refused for either.
    def encrypt(crypt, items)
      route_encrypt(*prepare('encrypt', crypt, items, :plaintext))
    end

    # Open each item's ciphertext. +data["items"][n]["plaintext"]+ is a binary String.
    def decrypt(crypt, items)
      route_by_ciphertext('decrypt', *prepare('decrypt', crypt, items, :ciphertext))
    end

    # Open and re-seal each item's ciphertext under the project's current key version in one call; the plaintext never
    # leaves the platform. It is the fix for 409 K9O_SEALED_UNDER_RETIRED_KEY while the window is open.
    def rewrap(crypt, items)
      route_by_ciphertext('rewrap', *prepare('rewrap', crypt, items, :ciphertext))
    end

    # Ask the gateway for a short-lived federated token (POST crypto/federated-token) for +op+ ("encrypt", "decrypt" or
    # "rewrap") on +crypt+, as a FederatedToken. The SDK checks both before sending, with K9O_INVALID_FIELD_VALUE. The
    # call is never retried. The token is a credential: keep it out of logs and error reports. A refusal raises
    # K9o::KError (400 K9O_INVALID_FIELD_VALUE, 401, 403, 409 K9O_CUSTODY_SERVER_ROUTE (context['route'] is 'server' or 'client-idp'), 429 K9O_RATE_LIMITED, 503
    # K9O_KEY_SERVICE_UNAVAILABLE).
    def federated_token(crypt, op)
      slug = Studio.require_project_slug(@config, 'crypto')
      unless crypt.is_a?(String) && CRYPT_PATTERN.match?(crypt)
        raise invalid('crypt must be 1 to 64 characters of a-z, 0-9 and -, and not "actions"', crypt: crypt)
      end
      raise invalid('op must be encrypt, decrypt or rewrap', op: op.is_a?(String) ? op : nil) unless TOKEN_OPS.include?(op)

      data = HttpTransport.request(config: @config, method: 'POST', path: UrlGrammar.project_path(slug, 'crypto/federated-token'),
                                   body: { crypt: crypt, op: op }).data
      unless data.is_a?(Hash) && TOKEN_FIELDS.all? { |f| data[f].is_a?(String) && !data[f].empty? }
        raise KError.new(code: 'K9O_INTERNAL_ERROR', message: 'Malformed crypto/federated-token response: expected token, expiresAt, issuer, subject, audience and kid')
      end

      optional = %w[provider projectId].map { |f| data[f].is_a?(String) && !data[f].empty? ? data[f] : nil }
      FederatedToken.new(*TOKEN_FIELDS.map { |f| data[f] }, *optional)
    end

    # The crypts you hold (GET crypto/crypts): +data["crypts"]+ is an Array of { "name", "status" ("active" or "retired"),
    # "createdAt", "retiredAt" (String or nil) }. Every crypt if you have a +*+ grant on crypts, none if you are a member
    # with no grant. A malformed answer raises K9O_INTERNAL_ERROR. Gateway refusals (K9O_ACCESS_DENIED) raise K9o::KError.
    def crypts_list
      slug = Studio.require_project_slug(@config, 'crypto')
      envelope = HttpTransport.request(config: @config, method: 'GET', path: UrlGrammar.project_path(slug, 'crypto/crypts'))
      data = envelope.data
      raise malformed_crypt('list', 'without crypts') unless data.is_a?(Hash) && data['crypts'].is_a?(Array)

      Envelope.new(data: { 'crypts' => data['crypts'].map { |c| crypt_of(c, 'list') } }, meta: envelope.meta)
    end

    # Register a crypt so #encrypt accepts it (POST crypto/crypts, body { name: } and nothing else). +name+ is 1 to 64
    # characters of a-z, 0-9 and -, and not "actions"; a bad name raises K9O_INVALID_FIELD_VALUE before anything is sent.
    # Needs crypto:manage_crypts (project admins by default). Gateway refusals: 409 K9O_CRYPT_ALREADY_EXISTS, 409
    # K9O_CRYPT_LIMIT_EXCEEDED (256 per project, retired ones counted), 409 K9O_CRYPT_RETIRED; all raise K9o::KError.
    def crypts_create(name)
      slug = Studio.require_project_slug(@config, 'crypto')
      check_crypt_name(name, 'create')
      envelope = HttpTransport.request(config: @config, method: 'POST', path: UrlGrammar.project_path(slug, 'crypto/crypts'),
                                       body: { name: name })
      Envelope.new(data: crypt_of(envelope.data, 'create'), meta: envelope.meta)
    end

    # Retire a crypt (POST crypto/crypts/<name>/retire, no body): #encrypt then refuses the name. #decrypt and #rewrap
    # never read the registry, so data stays readable. This does not isolate, enforce or destroy anything. Needs
    # crypto:manage_crypts; a personal access token is refused (K9O_RBAC_DENY). Gateway refusals: 404 K9O_CRYPT_NOT_FOUND,
    # 409 K9O_CRYPT_RETIRED.
    def crypts_retire(name)
      slug = Studio.require_project_slug(@config, 'crypto')
      check_crypt_name(name, 'retire')
      envelope = HttpTransport.request(config: @config, method: 'POST',
                                       path: UrlGrammar.project_path(slug, "crypto/crypts/#{name}/retire"))
      Envelope.new(data: crypt_of(envelope.data, 'retire'), meta: envelope.meta)
    end

    # Check the +expected_key_refs:+ client option and return a frozen copy (nil when not set). It must be a non-empty
    # Array of non-blank Strings without whitespace, and none may contain "*", since a wildcard pins nothing. Raises
    # K9o::KError K9O_INVALID_FIELD_VALUE (+context["field"]+ is "expectedKeyRefs") otherwise.
    def self.check_expected_key_refs(refs)
      return nil if refs.nil?

      bad = lambda do |message|
        KError.new(code: 'K9O_INVALID_FIELD_VALUE', message: "expectedKeyRefs: #{message}", context: { 'field' => 'expectedKeyRefs' })
      end
      raise bad.call('pass a non-empty Array of key identifiers, or leave it out') unless refs.is_a?(Array) && !refs.empty?

      refs.each do |r|
        raise bad.call('each entry must be a key identifier without spaces') unless r.is_a?(String) && !r.strip.empty? && !r.match?(/\s/)
        raise bad.call('an entry cannot contain "*"; name the exact key') if r.include?('*')
      end
      refs.map { |r| r.dup.freeze }.freeze
    end

    # Whether +key_ref+ is one of +expected+, ignoring the key version, by the rule the Kibo client core applies: AWS
    # compares the whole reference; GCP drops +/cryptoKeyVersions/<n>+ and what follows; Azure compares the first five
    # +/+-separated parts (+https://<host>/keys/<key>+) in lower case, so a version and the case of the host and key name
    # are ignored; Vault compares +<path>/<key>+ without a +:<version>+ suffix. +provider:+ is required (:aws, :gcp,
    # :azure or :vault) and is never inferred from the reference, because a Vault reference can look like a URL. Any
    # other value raises K9O_INVALID_FIELD_VALUE. For authors of a client core; the SDK does not call it.
    def self.key_ref_matches?(key_ref, expected, provider:)
      k = key_identity(key_ref.to_s, provider)
      Array(expected).any? { |e| key_identity(e.to_s, provider) == k }
    end

    def self.key_identity(ref, provider)
      case provider.respond_to?(:to_sym) ? provider.to_sym : provider
      when :aws then ref
      when :gcp then ref.split('/cryptoKeyVersions/', -1).first.to_s
      when :azure then ref.split('/', -1).first(5).join('/').downcase
      when :vault
        cut = ref.rindex('/')
        path = cut.nil? ? '' : ref[0...cut]
        key = cut.nil? ? ref : ref[(cut + 1)..]
        "#{path}/#{key.split(':', 2).first.to_s}"
      else
        raise KError.new(code: 'K9O_INVALID_FIELD_VALUE', message: 'provider must be :aws, :gcp, :azure or :vault',
                         context: { 'field' => 'provider' })
      end
    end
    private_class_method :key_identity

    # The text of a decrypted item as a UTF-8 String (nil for an item without plaintext).
    def self.text(item)
      plain = item.is_a?(Hash) ? item['plaintext'] : nil
      plain.is_a?(String) ? plain.dup.force_encoding(Encoding::UTF_8) : nil
    end

    private

    def check_crypt_name(name, op)
      return name if name.is_a?(String) && CRYPT_PATTERN.match?(name)

      raise invalid("crypto.crypts.#{op}: #{CRYPT_RULE.sub('crypt must', 'name must')}", field: 'name')
    end

    def malformed_crypt(op, why)
      KError.new(code: 'K9O_INTERNAL_ERROR', message: "crypto.crypts.#{op}: the gateway answered #{why}")
    end

    def crypt_of(item, op)
      raise malformed_crypt(op, 'without a crypt') unless item.is_a?(Hash)
      raise malformed_crypt(op, 'without a name') unless item['name'].is_a?(String) && !item['name'].empty?
      raise malformed_crypt(op, 'with an unknown status') unless CRYPT_STATUSES.include?(item['status'])
      raise malformed_crypt(op, 'without createdAt') unless item['createdAt'].is_a?(String) && !item['createdAt'].empty?
      unless item['retiredAt'].nil? || item['retiredAt'].is_a?(String)
        raise malformed_crypt(op, 'with a retiredAt that is neither a date nor null')
      end

      { 'name' => item['name'], 'status' => item['status'], 'createdAt' => item['createdAt'], 'retiredAt' => item['retiredAt'] }
    end

    def invalid(message, context = {})
      ApprovalChecks.invalid(message, context)
    end

    def too_large(message, context)
      KError.new(code: 'K9O_PAYLOAD_TOO_LARGE', message: message, context: context)
    end

    # Validate, then [crypt, wire items, client-core items]. Nothing is sent here.
    def prepare(_op, crypt, items, field)
      unless crypt.is_a?(String) && CRYPT_PATTERN.match?(crypt)
        raise invalid('crypt must be 1 to 64 characters of a-z, 0-9 and -, and not "actions"', crypt: crypt)
      end
      unless items.is_a?(Array) && items.size >= 1 && items.size <= MAX_ITEMS
        raise invalid("items must be an Array of 1 to #{MAX_ITEMS} items", count: items.is_a?(Array) ? items.size : nil)
      end

      total = 0
      wire = []
      plain = []
      items.each_with_index do |item, i|
        entry, size, core_item = wire_item(item, i, field)
        total += size
        wire << entry
        plain << core_item
      end
      if field == :plaintext && total > MAX_CALL_BYTES
        raise too_large("plaintext is at most #{MAX_CALL_BYTES} bytes per call", limit: MAX_CALL_BYTES, bytes: total)
      end

      [crypt, wire, plain]
    end

    def route_encrypt(crypt, wire, plain)
      attempts = 0
      loop do
        attempts += 1
        answer = mode_answer(Studio.require_project_slug(@config, 'crypto'), crypt)
        custody = answer['custodyMode']
        epoch = answer['epoch']
        route = answer['route']
        has_epoch = epoch.is_a?(String) && !epoch.empty?
        # An unknown route refuses before anything is sent, in every custody mode.
        # A route that is present but JSON null counts as unknown; only an absent key is "no route".
        if answer.key?('route') && route != 'server' && route != 'client'
          raise custody_unknown(custody, route)
        end
        if CLIENT_MODES.include?(custody)
          return client_call('encrypt', crypt, plain, custody) unless route == 'server'
          raise custody_unknown(custody, route) unless has_epoch
        elsif !(SERVER_MODES.include?(custody) && has_epoch)
          raise custody_unknown(custody, route)
        end

        begin
          return post('encrypt', 'crypt' => crypt, 'items' => wire, 'custodyEpoch' => epoch)
        rescue KError => e
          raise unless attempts < 2 && zk_flow_required?(e)
        end
      end
    end

    # The raw GET crypto/mode answer as a Hash. Read fresh on every call; never cached.
    # A non-nil +crypt+ goes out as ?crypt= so the gateway authorizes the caller on that crypt (encrypt's custody check).
    def mode_answer(slug, crypt = nil)
      data = HttpTransport.request(config: @config, method: 'GET', path: UrlGrammar.project_path(slug, 'crypto/mode'),
                                   query: crypt.nil? ? nil : { 'crypt' => crypt }).data
      data.is_a?(Hash) ? data : {}
    end

    def custody_unknown(custody, route)
      context = { 'custodyMode' => custody }
      context['route'] = route if route.is_a?(String)
      KError.new(code: CUSTODY_MODE_UNKNOWN, status: nil,
                 message: 'the project custody mode or route is unknown, so nothing was sent; plaintext is never sent when the route is unclear',
                 context: context)
    end

    def route_by_ciphertext(op, crypt, wire, plain)
      post(op, 'crypt' => crypt, 'items' => wire)
    rescue KError => e
      raise unless zk_flow_required?(e) && e.context.is_a?(Hash) && e.context['route'] == 'client'

      client_call(op, crypt, plain, e.context['custodyMode'])
    end

    def zk_flow_required?(error)
      error.status == 409 && error.code == ZK_STORE_FLOW_REQUIRED
    end

    def post(op, body)
      slug = Studio.require_project_slug(@config, 'crypto')
      envelope = HttpTransport.request(config: @config, method: 'POST',
                                       path: UrlGrammar.project_path(slug, "crypto/#{op}"), body: body)
      Envelope.new(data: decode(envelope.data), meta: envelope.meta)
    end

    def client_call(op, crypt, items, custody)
      if @client_core.nil?
        raise KError.new(code: ZK_CLIENT_CORE_UNAVAILABLE, status: 501,
                         message: "this project's key is held in your own KMS; install and register the Kibo client core " \
                                  'for this language (crypto.use_client_core), or call kibo.encrypt/decrypt directly',
                         context: { 'custodyMode' => custody, 'requirement' => 'kibo-client-core' })
      end

      refs = @config.expected_key_refs
      unless refs.nil? || (@client_core.respond_to?(:enforces_expected_key_refs?) && @client_core.enforces_expected_key_refs? == true)
        raise KError.new(code: KEY_PIN_UNENFORCED, status: nil,
                         message: 'expectedKeyRefs is set but the client core does not declare that it enforces it; nothing was sent',
                         context: { 'custodyMode' => custody, 'requirement' => 'client-core-enforces-expected-key-refs' },
                         recommendation: 'Use a client core that enforces the pin (enforces_expected_key_refs? returns true), ' \
                                         'or leave expected_key_refs out.')
      end

      opts = {}
      opts[:expected_key_refs] = refs unless refs.nil?
      result = @client_core.public_send(op, crypt, items, **opts)
      result = result.data if result.is_a?(Envelope)
      result = { 'items' => result } if result.is_a?(Array)
      Envelope.new(data: result, meta: Meta.from_wire({}))
    end

    # [wire item, plaintext bytes, client-core item]
    def wire_item(item, index, field)
      item = { field => item } if item.is_a?(String)
      unless item.is_a?(Hash)
        raise invalid("items[#{index}] must be a Hash or a String", index: index)
      end

      value = item[field] || item[field.to_s]
      unless value.is_a?(String) && (field == :plaintext || !value.empty?)
        raise invalid("items[#{index}].#{field} is required and must be a String", index: index)
      end
      other = field == :plaintext ? :ciphertext : :plaintext
      if item.key?(other) || item.key?(other.to_s)
        raise invalid("items[#{index}] takes #{field}, not #{other}", index: index)
      end

      size = 0
      entry = {}
      core_item = {}
      if field == :plaintext
        bytes = value.b
        size = bytes.bytesize
        if size > MAX_ITEM_BYTES
          raise too_large("plaintext is at most #{MAX_ITEM_BYTES} bytes per item", limit: MAX_ITEM_BYTES, index: index,
                                                                              bytes: size)
        end
        entry['plaintext'] = [bytes].pack('m0')
        core_item[:plaintext] = bytes
      else
        entry['ciphertext'] = value
        core_item[:ciphertext] = value
      end

      context = item.key?(:context) ? item[:context] : item['context']
      unless context.nil?
        unless context.is_a?(String) && context.bytesize <= MAX_CONTEXT_BYTES
          raise invalid("items[#{index}].context must be a String of at most #{MAX_CONTEXT_BYTES} bytes", index: index)
        end
        unless context.dup.force_encoding(Encoding::UTF_8).valid_encoding?
          raise invalid("items[#{index}].context must be valid UTF-8 text", index: index)
        end

        entry['context'] = context
        core_item[:context] = context
      end
      [entry, size, core_item]
    end

    # Decode each plaintext back to bytes; every other field stays as the gateway sent it.
    def decode(data)
      return data unless data.is_a?(Hash) && data['items'].is_a?(Array)

      items = data['items'].map do |item|
        next item unless item.is_a?(Hash) && item['plaintext'].is_a?(String)

        bytes = begin
          item['plaintext'].unpack1('m0')
        rescue ArgumentError
          nil
        end
        bytes.nil? ? item : item.merge('plaintext' => bytes)
      end
      data.merge('items' => items)
    end
  end
end
