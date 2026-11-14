# frozen_string_literal: true

module K9o
  # Realtime Subscriptions namespace.
  #
  # Transport: SSE over GET /@<slug>/realtime/subscribe. The gateway closes each stream after at most 300 seconds
  # and sends a +:hb+ comment every 15 seconds on a quiet feed. #subscribe returns an Enumerator that reconnects
  # with +Last-Event-ID+, drops events it has already delivered and, when the gateway reports that the position
  # is lost (+event: resync+), calls +on_resync+ and continues from a fresh connection.
  class Realtime
    @idle_timeout = 45
    @max_backoff = 30
    @sleeper = ->(seconds) { sleep(seconds) }
    DEFAULT_RETRY_MS = 1000
    SEEN_LIMIT = 1024

    class << self
      # Seconds without any bytes (events, comments, heartbeats) after which a connection is abandoned.
      attr_accessor :idle_timeout
      # Longest reconnect delay in seconds.
      attr_accessor :max_backoff
      # Callable taking seconds; replaceable in tests.
      attr_accessor :sleeper
    end

    def initialize(config)
      @config = config
    end

    # Subscribe via SSE; returns an Enumerator yielding event hashes
    # { 'topic', 'eventType', 'payload', 'occurredAt', 'eventId' } (the gateway's spelling).
    #
    # The enumerator reconnects when the stream ends or fails, sending +Last-Event-ID+, and drops events whose
    # +eventId+ it has already delivered (delivery is at-least-once). A client error (4xx) is raised once as a
    # K9o::KError; server errors and network errors are retried with a capped backoff (30 seconds at most).
    # An +event: resync+ frame is not yielded: +on_resync+ (a callable, may be nil) receives its
    # { 'reason', 'action' } hash, then a fresh connection starts without +Last-Event-ID+. Stop by leaving the
    # +each+ block (break) or by taking a finite number (+first(n)+).
    def subscribe(topic, filter: nil, on_resync: nil)
      slug = Studio.require_project_slug(@config, 'realtime')
      q = { 'topic' => topic }
      q['filter'] = JSON.dump(filter) if filter
      feed(UrlGrammar.project_path(slug, 'realtime/subscribe'), q, nil, on_resync)
    end

    # POST /@<slug>/realtime/replay: a batch of past events for +topic+ (required, the same topic strings as
    # #subscribe, 1 to 200 characters). +from_sequence+ and +until_sequence+ (whole numbers, 0 or more) bound the
    # range; +limit+ (1 to 10,000) caps the batch, and the gateway's own default applies when omitted.
    #
    # Answers an Envelope whose +data+ is { "events" => [event], "nextCursor", "hasMore" } and, when the gateway
    # says the topic has no stored history, "resync" => "reread-source" (re-read the current state instead). Each
    # event is a Hash as the gateway sent it, in the spelling #subscribe yields ("topic", "eventType", "payload",
    # "occurredAt", "eventId"; an event from the audit log also carries "sequence"). A 4xx raises K9o::KError.
    def replay(topic, from_sequence: nil, until_sequence: nil, limit: nil)
      unless topic.is_a?(String) && !topic.empty? && topic.length <= 200
        raise ApprovalChecks.invalid('topic must be a realtime topic string of 1 to 200 characters', topic: topic)
      end
      { from_sequence: from_sequence, until_sequence: until_sequence }.each do |name, value|
        next if value.nil? || (value.is_a?(Integer) && value >= 0)

        raise ApprovalChecks.invalid("#{name} must be a whole number, 0 or more", name => value)
      end
      unless limit.nil? || (limit.is_a?(Integer) && limit >= 1 && limit <= 10_000)
        raise ApprovalChecks.invalid('limit must be a whole number from 1 to 10000', limit: limit)
      end

      body = { 'topic' => topic }
      body['fromSequence'] = from_sequence unless from_sequence.nil?
      body['untilSequence'] = until_sequence unless until_sequence.nil?
      body['limit'] = limit unless limit.nil?
      slug = Studio.require_project_slug(@config, 'realtime')
      envelope = HttpTransport.request(config: @config, method: 'POST',
                                       path: UrlGrammar.project_path(slug, 'realtime/replay'), body: body)
      Envelope.new(data: replay_page(envelope.data), meta: envelope.meta)
    end

    # The reconnecting reader behind #subscribe, Metadata#subscribe, Rollups#subscribe and Audit#tail.
    # +initial_query+ is added to the query of the first connection only, and only while the feed has no position of
    # its own.
    #
    # Frame options. By default a frame's JSON data is the event: +type_key+ is the field it must carry as a String
    # to count (nil accepts any JSON object) and +id_key+ names the event (the frame's SSE +id+ when absent).
    # A feed whose frames wrap the event passes +decode+, a callable taking the parsed data and the frame
    # ({ event:, id:, data:, retry: }) and answering the event Hash to deliver, or nil to skip the frame.
    # +keys+ (callable taking the event and the frame, or nil for a caught-up event) answers the strings that identify
    # the event for de-duplication; +cursor+ (same arguments) answers the value sent as +Last-Event-ID+ when the
    # connection is reopened (default: the first key). +accept+ (a callable) drops events after they have been counted
    # as delivered. +catch_up+ (a callable taking the resync hash and the last delivered event, or nil, and answering an
    # Array of events) is called on a resync instead of clearing the memory of delivered events. The feed first opens a
    # fresh connection (no +Last-Event-ID+) and buffers its frames, then calls +catch_up+ (only when an event had been
    # delivered), yields its events, then the buffered and live frames, all de-duplicated through +keys+; an event
    # published while +catch_up+ ran is on the fresh connection, so nothing is lost. A fresh connection that is itself
    # answered with a resync backs off before the next attempt. A resync that is the first
    # data of a connection opened with no position (neither +Last-Event-ID+ nor the +initial_query+ start position) is informational and ignored (the stream goes on); this is the
    # default (+fresh_head_resync: true+). A resync after data, or on a connection that sent a position, is a lost position.
    def feed(route, q, initial_query, on_resync, type_key: 'eventType', id_key: 'eventId', accept: nil, catch_up: nil,
             decode: nil, keys: nil, cursor: nil, fresh_head_resync: true)
      keys ||= lambda do |event, frame|
        id = event[id_key].is_a?(String) ? event[id_key] : (frame && frame[:id])
        id ? [id] : []
      end
      remember = lambda do |seen, ks|
        ks.each do |k|
          seen[k] = true
          seen.shift while seen.size > SEEN_LIMIT
        end
      end
      Enumerator.new do |yielder|
        use_initial = true
        last_id = nil
        last_event = nil
        seen = {}
        retry_ms = DEFAULT_RETRY_MS
        failures = 0
        resyncs = 0
        buffered = nil
        loop do
          headers = last_id ? { 'Last-Event-ID' => last_id } : nil
          resync_info = nil
          failed = false
          got_event = false
          seen_resync = false
          sent_position = !last_id.nil?
          begin
            query = use_initial && last_id.nil? && initial_query ? q.merge(initial_query) : q
            sent_position ||= !query.equal?(q)
            use_initial = false
            frames = buffered || HttpTransport.stream_sse(config: @config, method: 'GET', path: route, query: query,
                                                          headers: headers, idle_timeout: self.class.idle_timeout, raw: true)
            buffered = nil
            catch(:resync) do
              frames.each do |frame|
                retry_ms = frame[:retry] if frame[:retry]
                next if frame[:data].nil? && frame[:event].nil?

                if frame[:event] == 'resync'
                  # Informational: a fresh connection (no Last-Event-ID sent) opens with the live head's resync;
                  # events follow on the same stream, so keep reading it.
                  if fresh_head_resync && !sent_position && !got_event && !seen_resync
                    seen_resync = true
                    next
                  end

                  info = parse(frame[:data])
                  resync_info = info.is_a?(Hash) ? info : {}
                  throw :resync
                end
                data = parse(frame[:data])
                if decode
                  event = decode.call(data, frame)
                  next unless event.is_a?(Hash)
                else
                  event = data
                  next unless event.is_a?(Hash) && (type_key.nil? || event[type_key].is_a?(String))
                end

                failures = 0
                resyncs = 0
                got_event = true
                ks = keys.call(event, frame)
                next if ks.any? { |k| seen.key?(k) }

                remember.call(seen, ks)
                pos = cursor ? cursor.call(event, frame) : ks.first
                last_id = pos if pos
                last_event = event
                yielder << event if accept.nil? || accept.call(event)
              end
            end
          rescue KError => e
            raise if e.status && e.status < 500

            failed = true
          ensure
            frames.close if frames.respond_to?(:close)
          end

          if resync_info
            failures = 0
            use_initial = false
            if catch_up
              resyncs += 1
              last_id = nil
              delay = resyncs >= 2 ? [retry_ms / 1000.0 * (2**(resyncs - 2)), self.class.max_backoff].min : retry_ms / 1000.0
              self.class.sleeper.call(delay) if delay.positive?
              if last_event
                buffered = BufferedStream.new(HttpTransport.stream_sse(config: @config, method: 'GET', path: route,
                                                                        query: q, idle_timeout: self.class.idle_timeout,
                                                                        raw: true))
                begin
                  buffered.wait_open
                  Array(catch_up.call(resync_info, last_event)).each do |event|
                    next unless event.is_a?(Hash)

                    ks = keys.call(event, nil)
                    next if ks.any? { |k| seen.key?(k) }

                    remember.call(seen, ks)
                    last_event = event
                    yielder << event if accept.nil? || accept.call(event)
                  end
                rescue Exception # rubocop:disable Lint/RescueException
                  buffered.close
                  buffered = nil
                  raise
                end
              end
              on_resync&.call(resync_info)
              next
            end
            last_id = nil
            last_event = nil
            seen.clear
            on_resync&.call(resync_info)
            next
          end
          failures += 1 if failed
          delay = failed ? [retry_ms / 1000.0 * (2**(failures - 1)), self.class.max_backoff].min : retry_ms / 1000.0
          self.class.sleeper.call(delay) if delay.positive?
        end
      end
    end

    # Reads an SSE frame enumerator on a thread into a queue, so the connection stays open (and its frames are kept)
    # while something else runs. +each+ replays the kept frames, then the live ones; a failure is raised from +each+.
    class BufferedStream
      def initialize(source)
        @queue = Queue.new
        @head = nil
        @thread = Thread.new do
          begin
            source.each { |frame| @queue << [:frame, frame] }
            @queue << [:end]
          rescue Exception => e # rubocop:disable Lint/RescueException
            @queue << [:error, e]
          end
        end
        @thread.report_on_exception = false
      end

      # Blocks until the connection answered (first frame), failed or ended.
      def wait_open
        @head ||= @queue.pop
      end

      def each
        loop do
          msg = @head || @queue.pop
          @head = nil
          case msg.first
          when :frame then yield msg[1]
          when :error then raise msg[1]
          else break
          end
        end
      end

      def close
        @thread.kill
      end
    end

    private

    def replay_page(data)
      data = {} unless data.is_a?(Hash)
      page = { 'events' => Array(data['events']).select { |e| e.is_a?(Hash) },
               'nextCursor' => data['nextCursor'], 'hasMore' => data['hasMore'] == true }
      page['resync'] = data['resync'] if data['resync'].is_a?(String)
      page
    end

    def parse(text)
      JSON.parse(text.to_s)
    rescue JSON::ParserError
      nil
    end

    public

    module Topic
      module_function

      def collection(collection)
        "collections.#{collection}.*"
      end

      def workflow_runs
        'studio.workflows.runs.*'
      end

      def query_executed(query_id)
        "studio.queries.executed.#{query_id}"
      end

      def dashboard_refresh(dashboard_id)
        "studio.dashboards.refresh.#{dashboard_id}"
      end

      def function_invocations(function_id)
        "forge.functions.invocations.#{function_id}"
      end

      def audit_org(event_family)
        "audit.org.#{event_family}"
      end
    end
  end
end
