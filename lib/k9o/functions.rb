# frozen_string_literal: true

module K9o
  # Function lifecycle namespace — k9o.functions.*.
  #
  # Upload the function's bytes first (+upload_artifact+ returns the +artifactKey+), then +deploy+ references that
  # artifact. Deploy requires PROJECT_ADMIN and returns with status +deploying+; the function is ready when status
  # flips to +active+.
  class Functions
    ARTIFACT_CONTENT_TYPES = { 'wasm' => 'application/wasm', 'tar' => 'application/x-tar' }.freeze

    attr_reader :triggers

    def initialize(config)
      @config = config
      @triggers = FunctionTriggers.new(config)
    end

    # POST /@<slug>/functions/artifacts with the raw bytes: a WebAssembly module for the gateway tier (for the platform operator; a project's deploy to it is refused) (up to 16 MiB,
    # +kind+ 'wasm') or an OCI image archive for the sandbox tier (up to 256 MiB, +kind+ 'tar'). Uploading the same
    # bytes again returns the same key. The envelope's data is { 'artifactKey' => String }.
    def upload_artifact(bytes, kind)
      content_type = ARTIFACT_CONTENT_TYPES[kind.to_s]
      raise ArgumentError, "kind must be 'wasm' or 'tar'" if content_type.nil?

      bytes = bytes.read if bytes.respond_to?(:read)
      raise ArgumentError, 'bytes must be a String or an IO' unless bytes.is_a?(String)

      slug = require_project_slug
      HttpTransport.request(config: @config, method: 'POST',
                            path: UrlGrammar.project_path(slug, 'functions/artifacts'),
                            raw_body: bytes, headers: { 'content-type' => content_type })
    end

    # POST /@<slug>/functions — deploy or redeploy from an uploaded artifact.
    #   Functions run in the sandbox. tier: 'sandbox' (OCI image archive); runtime: bun python go java kotlin dotnet
    #   swift php ruby rust zig. 'gateway' (WebAssembly) is for the platform operator and is refused for a customer
    #   deploy; tinygo and assemblyscript run only there, so they cannot be deployed to a project.
    #   artifact_key: the key +upload_artifact+ returned; version: label for this deploy (1 to 64 characters)
    def deploy(name:, runtime:, tier:, artifact_key:, version:, description: nil)
      slug = require_project_slug
      body = { 'name' => name, 'runtime' => runtime, 'tier' => tier, 'artifactKey' => artifact_key,
               'version' => version }
      body['description'] = description unless description.nil?
      HttpTransport.request(config: @config, method: 'POST', path: UrlGrammar.project_path(slug, 'functions'), body: body)
    end

    # GET /@<slug>/functions (cursor pagination).
    def list(status: nil, limit: nil, cursor: nil)
      slug = require_project_slug
      q = {}
      q['status'] = status unless status.nil?
      q['limit'] = limit unless limit.nil?
      q['cursor'] = cursor unless cursor.nil?
      HttpTransport.request(config: @config, method: 'GET', path: UrlGrammar.project_path(slug, 'functions'), query: q)
    end

    def get(name)
      slug = require_project_slug
      HttpTransport.request(config: @config, method: 'GET', path: UrlGrammar.project_path(slug, "functions/#{enc(name)}"))
    end

    # Retire a function; its name enters a 24h cooldown.
    def delete(name)
      slug = require_project_slug
      HttpTransport.request(config: @config, method: 'DELETE', path: UrlGrammar.project_path(slug, "functions/#{enc(name)}"))
    end

    # POST /@<slug>/functions/<name>/invoke. +payload+ is sent as the +payload+ field of the request body and passed
    # to the function runtime verbatim. Optional controls: +background+ (run asynchronously), +delegation+
    # ({ 'token' => ..., 'invokeSessionId' => ... }), +on_behalf_of+, +confined_to+.
    def invoke(name, payload = nil, background: nil, delegation: nil, on_behalf_of: nil, confined_to: nil)
      slug = require_project_slug
      body = {}
      body['payload'] = payload unless payload.nil?
      body['background'] = background unless background.nil?
      body['delegation'] = delegation unless delegation.nil?
      body['onBehalfOf'] = on_behalf_of unless on_behalf_of.nil?
      body['confinedTo'] = confined_to unless confined_to.nil?
      HttpTransport.request(config: @config, method: 'POST',
                            path: UrlGrammar.project_path(slug, "functions/#{enc(name)}/invoke"), body: body)
    end

    private

    def require_project_slug
      Studio.require_project_slug(@config, 'functions')
    end

    def enc(s)
      ::URI.encode_www_form_component(s)
    end
  end

  # Event triggers: k9o.functions.triggers.* run a function when a record is inserted, updated, deleted or upserted
  # in a collection. They need the project admin role. For triggers on a timetable see +k9o.schedules+.
  #
  #   list(name)                                   GET    /@<slug>/functions/<name>/triggers
  #   create(name, collection:, events:, ...)      POST   /@<slug>/functions/<name>/triggers
  #   update(name, trigger_id, **fields)           PATCH  /@<slug>/functions/<name>/triggers/<id>
  #   delete(name, trigger_id)                     DELETE /@<slug>/functions/<name>/triggers/<id>   (204, no body)
  class FunctionTriggers
    EVENTS = %w[insert update delete upsert].freeze
    COLLECTION_RE = /\A[a-zA-Z_][a-zA-Z0-9_]{0,127}\z/.freeze
    UPDATE_FIELDS = %i[events filter enabled log_ok_invocations].freeze

    def initialize(config)
      @config = config
    end

    # Every trigger of the function, newest first. Not paginated.
    def list(name)
      call('GET', path(name))
    end

    # Create an event trigger; answers 201 with the trigger. +events+ lists 1 to 4 of insert, update, delete, upsert.
    # +filter+ is a predicate Hash over the record; leave it out to fire on every matching event.
    def create(name, collection:, events:, filter: nil, enabled: nil, log_ok_invocations: nil)
      unless collection.is_a?(String) && COLLECTION_RE.match?(collection)
        raise ApprovalChecks.invalid('collection must match ^[a-zA-Z_][a-zA-Z0-9_]*$ (1 to 128 characters)',
                                     collection: collection)
      end

      body = { 'collection' => collection, 'events' => check_events(events) }
      body['filter'] = filter unless filter.nil?
      body['enabled'] = enabled unless enabled.nil?
      body['logOkInvocations'] = log_ok_invocations unless log_ok_invocations.nil?
      call('POST', path(name), body: body)
    end

    # Change a trigger; send at least one of +events+, +filter+, +enabled+, +log_ok_invocations+. A Hash +filter+
    # replaces the filter and an explicit +filter: nil+ clears it. The collection cannot be changed.
    def update(name, trigger_id, **fields)
      unknown = fields.keys - UPDATE_FIELDS
      raise ApprovalChecks.invalid("unknown field: #{unknown.join(', ')}") unless unknown.empty?
      raise ApprovalChecks.invalid("patch needs at least one of: #{UPDATE_FIELDS.join(', ')}") if fields.empty?

      body = {}
      body['events'] = check_events(fields[:events]) if fields.key?(:events)
      body['filter'] = fields[:filter] if fields.key?(:filter)
      body['enabled'] = fields[:enabled] if fields.key?(:enabled)
      body['logOkInvocations'] = fields[:log_ok_invocations] if fields.key?(:log_ok_invocations)
      call('PATCH', path(name, "/#{ApprovalChecks.id_segment(trigger_id, 'trigger')}"), body: body)
    end

    # Delete a trigger. Answers 204, so +data+ is nil; deleting again is a 404.
    def delete(name, trigger_id)
      call('DELETE', path(name, "/#{ApprovalChecks.id_segment(trigger_id, 'trigger')}"))
    end

    private

    def check_events(events)
      list = events.is_a?(Array) ? events.map { |e| e.is_a?(Symbol) ? e.to_s : e } : nil
      return list if list && list.size.between?(1, 4) && list.all? { |e| EVENTS.include?(e) }

      raise ApprovalChecks.invalid('events must list 1 to 4 of insert, update, delete, upsert', events: events)
    end

    def call(method, route, body: nil)
      HttpTransport.request(config: @config, method: method, path: route, body: body)
    end

    def path(name, tail = '')
      slug = Studio.require_project_slug(@config, 'functions')
      UrlGrammar.project_path(slug, "functions/#{ApprovalChecks.id_segment(name, 'function')}/triggers#{tail}")
    end
  end
end
