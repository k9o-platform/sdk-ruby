# frozen_string_literal: true

require 'json'

module K9o
  # client.keys: the project's encryption keys. Metadata only: no key material is ever returned.
  #
  #   list(status: nil)            GET  /@<slug>/vault/keys           data: { "items" => [key] } (not paged)
  #   get(key_id)                  GET  /@<slug>/vault/keys/<id>      data: key
  #   rotate(key_id, step_up: nil) POST /@<slug>/vault/keys/<id>/rotate
  #
  # A key is { "id", "version", "status", "custodyMode", "createdAt", "rotatedAt", "byokRef", "hyokRef" }.
  # Reading needs PROJECT_ADMIN or PROJECT_AUDITOR; rotating needs PROJECT_ADMIN and a fresh step-up proof.
  # A person's credential only: service, workload, extension and end-user tokens are refused (403).
  class Keys
    STATUSES = %w[active all].freeze
    STEP_UP_HEADER = 'x-k9o-step-up-proof'

    def initialize(config)
      @config = config
    end

    # The project's keys. Only the active key by default; +status:+ "all" adds the rotating and revoked versions.
    # The list is not paged: +data+ is { "items" => [key] } and nothing else.
    def list(status: nil)
      query = {}
      query['status'] = ApprovalChecks.enum!(status, STATUSES, 'status') unless status.nil?
      envelope = call('GET', '', query: query)
      data = envelope.data
      return envelope unless data.is_a?(Hash) && data.key?('nextCursor')

      Envelope.new(data: data.reject { |k, _| k == 'nextCursor' }, meta: envelope.meta)
    end

    def get(key_id)
      call('GET', "/#{ApprovalChecks.id_segment(key_id, 'key')}")
    end

    # Rotate the active key: every data key is re-wrapped under a new version and the old version is revoked.
    # +data+ is { "keyId", "previousVersion", "newVersion", "status" => "rotated" }.
    #
    # Rotation needs a fresh step-up proof. The first request answers 401 K9O_STEP_UP_REQUIRED with a challenge
    # (K9o::KError#step_up, a K9o::Keys::StepUpChallenge). Pass +step_up:+ a callable and the SDK hands it the
    # challenge, the HTTP method and the URL being called, expects { method:, proof: } back (+method+ is one of the
    # challenge's +methods+; +proof+ is that method's own proof, for DPoP bound to this method and URL) and sends the
    # same request again with the +x-k9o-step-up-proof+ header: base64url(JSON { scopeSetRoot, nonce, method, proof }).
    # It retries exactly once. Without a hook the K9O_STEP_UP_REQUIRED error is raised and carries the challenge.
    # An error from your hook, a second 401 or any other failure of the retry is raised as it is. The proof is never
    # logged. Nothing in the platform mints the proof for you.
    #
    # Other errors (all K9o::KError): 409 K9O_STATE_CONFLICT with context reason "rotation_in_flight" or
    # "key_not_active"; 429 K9O_RATE_LIMITED with reason "rotation_rate_cap" (at most 3 rotations per rolling 24 hours;
    # +retry_after_sec+ says when the next one is possible) or "key_service_busy". A refused rotation does not use up
    # a proof. +headers:+ adds request headers. The call is never retried otherwise.
    def rotate(key_id, step_up: nil, headers: nil)
      tail = "/#{ApprovalChecks.id_segment(key_id, 'key')}/rotate"
      unless step_up.nil? || step_up.respond_to?(:call)
        raise ApprovalChecks.invalid('step_up must respond to call(challenge, method, url)')
      end

      begin
        call('POST', tail, headers: headers)
      rescue KError => e
        raise unless step_up && e.code == 'K9O_STEP_UP_REQUIRED' && e.status == 401

        challenge = e.step_up
        raise unless challenge

        method = 'POST'
        url = "#{Region.resolve_origin(@config).sub(%r{/\z}, '')}#{UrlGrammar.project_path(slug_for_keys, "vault/keys#{tail}")}"
        answer = step_up.call(challenge, method, url)
        proof_header = StepUp.header(challenge, answer)
        call('POST', tail, headers: (headers || {}).merge(STEP_UP_HEADER => proof_header))
      end
    end

    # The step-up challenge from a 401 K9O_STEP_UP_REQUIRED (context.stepUp).
    StepUpChallenge = Struct.new(:scope_set_root, :nonce, :min_tier, :methods, :max_age_sec, :single_use, :rp_id,
                                 keyword_init: true)

    module StepUp
      module_function

      # The challenge in an error's context, or nil.
      def challenge_from(context)
        raw = context.is_a?(Hash) ? (context['stepUp'] || context[:stepUp]) : nil
        return nil unless raw.is_a?(Hash)

        root = raw['scopeSetRoot']
        nonce = raw['nonce']
        return nil unless root.is_a?(String) && nonce.is_a?(String)

        StepUpChallenge.new(scope_set_root: root, nonce: nonce, min_tier: raw['minTier'],
                            methods: Array(raw['methods']), max_age_sec: raw['maxAgeSec'],
                            single_use: raw['singleUse'], rp_id: raw['rpId'])
      end

      # base64url (no padding) of JSON { scopeSetRoot, nonce, method, proof }, from the hook's answer.
      def header(challenge, answer)
        unless answer.is_a?(Hash)
          raise ApprovalChecks.invalid('the step_up hook must return { method:, proof: }')
        end

        method = answer[:method] || answer['method']
        proof = answer[:proof] || answer['proof']
        unless method.is_a?(String) && !method.empty? && proof.is_a?(String) && !proof.empty?
          raise ApprovalChecks.invalid('the step_up hook must return a method and a proof, both non-empty strings')
        end
        unless challenge.methods.empty? || challenge.methods.include?(method)
          raise ApprovalChecks.invalid("step-up method must be one of: #{challenge.methods.join(', ')}")
        end

        json = JSON.generate('scopeSetRoot' => challenge.scope_set_root, 'nonce' => challenge.nonce,
                             'method' => method, 'proof' => proof)
        [json].pack('m0').tr('+/', '-_').delete('=')
      end
    end

    private

    def slug_for_keys
      Studio.require_project_slug(@config, 'keys')
    end

    def call(method, tail, query: nil, headers: nil)
      slug = slug_for_keys
      HttpTransport.request(config: @config, method: method, path: UrlGrammar.project_path(slug, "vault/keys#{tail}"),
                            query: query, headers: headers)
    end
  end
end
