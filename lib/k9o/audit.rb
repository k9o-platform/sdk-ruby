# frozen_string_literal: true

module K9o
  # Project-plane audit log namespace — k9o.audit.*.
  # Distinct from k9o.org.audit_log.
  class Audit
    TOPIC = 'audit.project'
    TYPE_PATTERN = /\A[A-Za-z0-9_][A-Za-z0-9_.\-]*\z/.freeze
    DEFAULT_REPLAY_LIMIT = 1000
    EVENT_ID_PATTERN = /\Aevt_[0-9A-Za-z]{1,40}\z/.freeze

    def initialize(config)
      @config = config
    end

    # GET /@<slug>/audit-log — reverse-chronological; filters AND-compose. Requires the AUDIT_READER role.
    #   event_type: audit-event name prefix (e.g. 'data.write.access')    actor_id: filter by actor
    #   after / before: ISO 8601 bounds (events after / before this instant)
    #   limit: page size (bounded server-side)    cursor: from the prior response's meta.cursor.next
    def query(event_type: nil, actor_id: nil, after: nil, before: nil, limit: nil, cursor: nil)
      slug = Studio.require_project_slug(@config, 'audit')
      q = {}
      q['eventType'] = event_type unless event_type.nil?
      q['actorId'] = actor_id unless actor_id.nil?
      q['after'] = after unless after.nil?
      q['before'] = before unless before.nil?
      q['limit'] = limit unless limit.nil?
      q['cursor'] = cursor unless cursor.nil?
      HttpTransport.request(config: @config, method: 'GET', path: UrlGrammar.project_path(slug, 'audit-log'), query: q)
    end

    # Live tail of the project's audit events: an Enumerator of { "auditEventId", "type", "actorType", "occurredAt",
    # "outcome", "eventId" }. The first five are the audit event (read the full row with #query by event type and
    # time); +eventId+ is the publisher's own id for the frame, which is not the +auditEventId+.
    #
    # +types+ is a list of audit event types: one type subscribes to +audit.project.<type>+, none to
    # +audit.project.*+, several to +audit.project.*+ with the SDK keeping only those types. Needs ORG_OWNER,
    # ORG_ADMIN, PROJECT_ADMIN or PROJECT_AUDITOR (re-checked every 60 seconds; others get 403 K9O_RBAC_DENY);
    # extensions cannot subscribe. +warden.checkpoint+ events are not in the live tail: the audit log and #replay
    # carry them.
    #
    # It is the same reconnecting reader as +realtime.subscribe+: it resumes with +Last-Event-ID+ (the frame's SSE
    # +id+), drops events it already delivered (by the frame's +eventId+ and by +auditEventId+), ignores heartbeats
    # and abandons a connection that has been silent for +Realtime.idle_timeout+ seconds. When the gateway says the
    # position is lost (+event: resync+, action +replay-ledger+; audit streams cannot be resumed by sequence) the tail
    # first reconnects fresh and buffers that connection's frames, then calls #replay after the last +auditEventId+ it
    # delivered (page by page while there are more), yields the events it missed (they also carry +sequence+, and may
    # include +warden.checkpoint+), calls +on_resync+ with the frame's hash, then yields the buffered and live frames,
    # each event once. Nothing is lost: the connection is open before the replay runs. If it had delivered nothing yet
    # it only reconnects (a new connection starts at the live head; a resync that opens a fresh connection is informational and ignored). Stop with +break+ or +first(n)+.
    def tail(types: nil, on_resync: nil)
      topic, keep = topic_for(types)
      slug = Studio.require_project_slug(@config, 'audit')
      catch_up = lambda do |_info, last_event|
        last_event ? collect_replay(topic, last_event['auditEventId']) : []
      end
      decode = lambda do |data, frame|
        payload = data.is_a?(Hash) ? data['payload'] : nil
        next nil unless payload.is_a?(Hash) && payload['auditEventId'].is_a?(String)

        event = {
          'auditEventId' => payload['auditEventId'],
          'type' => payload['type'].is_a?(String) ? payload['type'] : (data['eventType'] || frame[:event]),
          'actorType' => payload['actorType'],
          'occurredAt' => payload['occurredAt'],
          'outcome' => payload['outcome']
        }
        event['eventId'] = data['eventId'] if data['eventId'].is_a?(String)
        event
      end
      keys = lambda do |event, _frame|
        [event['eventId'], event['auditEventId']].compact
      end
      cursor = lambda do |event, frame|
        (frame && frame[:id]) || event['eventId']
      end
      Realtime.new(@config).feed(UrlGrammar.project_path(slug, 'realtime/subscribe'), { 'topic' => topic }, nil,
                                 on_resync, decode: decode, keys: keys, cursor: cursor, accept: keep,
                                 catch_up: catch_up, fresh_head_resync: true)
    end

    # POST /@<slug>/realtime/replay for the audit tail: a batch of past audit events in order, including
    # +warden.checkpoint+. +topic+ is +audit.project.*+ (default) or +audit.project.<type>+. Give
    # +after_audit_event_id+ (the last +auditEventId+ you received; unknown ids answer 400 K9O_INVALID_CURSOR) or
    # +from_sequence+ (+after_audit_event_id+ wins when both are given); +until_sequence+ and +limit+ bound the batch (+limit+ is
    # 1000 when omitted, up to 10,000). Needs the audit log's access.
    #
    # +data+ is the typed page { "events" => [event], "nextCursor", "hasMore" }; each event is { "auditEventId", "type",
    # "actorType", "occurredAt", "outcome", "sequence" } (+sequence+ is a String, as the gateway sends it).
    def replay(topic: "#{TOPIC}.*", after_audit_event_id: nil, from_sequence: nil, until_sequence: nil, limit: nil)
      unless topic.is_a?(String) && (topic == TOPIC || topic.start_with?("#{TOPIC}."))
        raise ApprovalChecks.invalid('topic must be audit.project.* or audit.project.<type>', topic: topic)
      end
      unless after_audit_event_id.nil? || (after_audit_event_id.is_a?(String) && EVENT_ID_PATTERN.match?(after_audit_event_id))
        raise ApprovalChecks.invalid('after_audit_event_id must look like evt_<id>', after_audit_event_id: after_audit_event_id)
      end
      {from_sequence: from_sequence, until_sequence: until_sequence}.each do |name, value|
        next if value.nil? || (value.is_a?(Integer) && value >= 0)

        raise ApprovalChecks.invalid("#{name} must be a whole number, 0 or more", name => value)
      end
      unless limit.nil? || (limit.is_a?(Integer) && limit >= 1 && limit <= 10_000)
        raise ApprovalChecks.invalid('limit must be a whole number from 1 to 10000', limit: limit)
      end

      body = { 'topic' => topic }
      body['afterAuditEventId'] = after_audit_event_id unless after_audit_event_id.nil?
      body['fromSequence'] = from_sequence unless from_sequence.nil?
      body['untilSequence'] = until_sequence unless until_sequence.nil?
      body['limit'] = limit.nil? ? DEFAULT_REPLAY_LIMIT : limit
      slug = Studio.require_project_slug(@config, 'audit')
      envelope = HttpTransport.request(config: @config, method: 'POST',
                                       path: UrlGrammar.project_path(slug, 'realtime/replay'), body: body)
      Envelope.new(data: replay_page(envelope.data), meta: envelope.meta)
    end

    private

    # [topic, filter or nil]
    def topic_for(types)
      list = types.nil? ? [] : Array(types).map { |t| t.is_a?(Symbol) ? t.to_s : t }
      list.each do |t|
        unless t.is_a?(String) && TYPE_PATTERN.match?(t)
          raise ApprovalChecks.invalid('types must be audit event type names such as "data.write.access"', type: t)
        end
      end
      list = list.uniq
      return ["#{TOPIC}.*", nil] if list.empty?
      return ["#{TOPIC}.#{list.first}", nil] if list.size == 1

      ["#{TOPIC}.*", ->(event) { list.include?(event['type']) }]
    end

    # The replay answer with its events flattened to the tail's shape (+sequence+ kept).
    def replay_page(data)
      data = {} unless data.is_a?(Hash)
      events = Array(data['events']).map { |e| flatten_replayed(e) }.compact
      { 'events' => events, 'nextCursor' => data['nextCursor'], 'hasMore' => data['hasMore'] == true }
    end

    def flatten_replayed(raw)
      return nil unless raw.is_a?(Hash)

      payload = raw['payload'].is_a?(Hash) ? raw['payload'] : {}
      return nil unless payload['auditEventId'].is_a?(String)

      event = {
        'auditEventId' => payload['auditEventId'],
        'type' => payload['type'].is_a?(String) ? payload['type'] : raw['eventType'],
        'actorType' => payload['actorType'],
        'occurredAt' => payload['occurredAt'],
        'outcome' => payload['outcome']
      }
      event['sequence'] = raw['sequence'] if raw.key?('sequence')
      event
    end

    # Events after +last_id+ from the replay route, page after page while it says there are more. The route has no
    # page cursor: each next page starts after the last event of the one before.
    def collect_replay(topic, last_id)
      out = []
      cursor = last_id
      loop do
        data = replay(topic: topic, after_audit_event_id: cursor).data
        events = data['events']
        break if events.empty?

        out.concat(events)
        next_cursor = events.last['auditEventId']
        break unless data['hasMore'] && next_cursor != cursor

        cursor = next_cursor
      end
      out
    end
  end
end
