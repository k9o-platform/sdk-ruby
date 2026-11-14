# frozen_string_literal: true

require 'minitest/autorun'
require 'json'
require 'socket'
require 'timeout'
require_relative '../lib/k9o'

# audit.tail (live audit events over the shared reconnecting reader) and audit.replay, with a scripted SSE stream.
class AuditTailTest < Minitest::Test
  # Answers each request with the next canned response. SSE responses stream their chunks; JSON ones have a body.
  class Scripted
    attr_accessor :use_ssl, :read_timeout
    attr_reader :reqs

    Resp = Struct.new(:code, :body, :chunks) do
      def [](_name)
        nil
      end

      def read_body(&blk)
        (chunks || [body]).each { |c| c.is_a?(Exception) ? raise(c) : blk.call(c) }
      end
    end

    def initialize(responses)
      @responses = responses
      @reqs = []
    end

    def request(req)
      @reqs << req
      resp = @responses[[@reqs.size - 1, @responses.size - 1].min]
      block_given? ? yield(resp) : resp
    end
  end

  # A live frame as the gateway sends it: the SSE id is the publisher's own id, the audit id sits in payload.
  def frame(audit_id, type = 'data.write.insert', outcome = nil, sse_id: nil)
    sse_id ||= "evt_pub_#{audit_id}"
    data = { 'topic' => "audit.project.#{type}", 'eventType' => type,
             'payload' => { 'auditEventId' => audit_id, 'type' => type, 'actorType' => 'user',
                            'occurredAt' => '2026-10-27T19:31:40.636Z', 'outcome' => outcome },
             'occurredAt' => '2026-10-27T19:31:40.636Z', 'eventId' => sse_id }
    "id: #{sse_id}\nevent: #{type}\ndata: #{JSON.generate(data)}\n\n"
  end

  # A replayed event as the replay route sends it.
  def replayed(audit_id, seq, type = 'data.write.insert')
    { 'sequence' => seq.to_s, 'topic' => "audit.project.#{type}", 'eventType' => type,
      'payload' => { 'auditEventId' => audit_id, 'type' => type, 'actorType' => 'user', 'occurredAt' => '2026-10-27T19:31:40.636Z',
                     'outcome' => nil },
      'occurredAt' => '2026-10-27T19:31:40.636Z' }
  end

  def resync
    "event: resync\ndata: {\"reason\":\"cursor-unknown\",\"action\":\"replay-ledger\"}\n\n"
  end

  def sse(*chunks)
    Scripted::Resp.new('200', nil, ["retry: 0\n:ok\n\n"] + chunks)
  end

  def json(data)
    Scripted::Resp.new('200', JSON.dump('data' => data, 'meta' => {}))
  end

  def err(status, code)
    Scripted::Resp.new(status.to_s, JSON.dump('code' => code, 'message' => 'no', 'context' => { 'reason' => 'x' }))
  end

  def client(*responses)
    @http = Scripted.new(responses)
    K9o.create_client(base_url: 'https://acme.api-de01.k9o.io', api_key: 'k', project_slug: 'portal', http_client: @http)
  end

  def query_of(req)
    URI.decode_www_form(URI.parse("https://x#{req.path}").query || '').to_h
  end

  def setup
    @sleeper = K9o::Realtime.sleeper
    @delays = []
    delays = @delays
    K9o::Realtime.sleeper = ->(s) { delays << s }
  end

  def teardown
    K9o::Realtime.sleeper = @sleeper
    K9o::Realtime.idle_timeout = 45
  end

  # The raw bytes captured live from the staging gateway (2026-10-27), unchanged.
  REAL_FRAME = "retry: 1000\n:ok\n\n" \
               "id: evt_TqfKnZdBRtggfnwJvuvroU\n" \
               "event: data.write.forge.scheduled_trigger.created\n" \
               'data: {"topic":"audit.project.data.write.forge.scheduled_trigger.created","eventType":"data.write.forge.scheduled_trigger.created","payload":{"auditEventId":"evt_UNs3pW7TSadU","type":"data.write.forge.scheduled_trigger.created","actorType":"user","occurredAt":"2026-10-27T19:31:40.636Z","outcome":null},"occurredAt":"2026-10-27T19:31:40.636Z","eventId":"evt_TqfKnZdBRtggfnwJvuvroU"}' \
               "\n\n"

  def test_real_captured_frame_is_flattened_to_the_audit_event
    c = client(Scripted::Resp.new('200', nil, [REAL_FRAME]))
    ev = c.audit.tail.first(1).first
    assert_equal({ 'auditEventId' => 'evt_UNs3pW7TSadU', 'type' => 'data.write.forge.scheduled_trigger.created',
                   'actorType' => 'user', 'occurredAt' => '2026-10-27T19:31:40.636Z', 'outcome' => nil,
                   'eventId' => 'evt_TqfKnZdBRtggfnwJvuvroU' }, ev)
  end

  def test_resume_uses_the_sse_id_not_the_audit_id
    c = client(Scripted::Resp.new('200', nil, [REAL_FRAME]), sse(frame('evt_Next')))
    evs = c.audit.tail.first(2)
    assert_equal %w[evt_UNs3pW7TSadU evt_Next], evs.map { |e| e['auditEventId'] }
    assert_equal 'evt_TqfKnZdBRtggfnwJvuvroU', @http.reqs[1]['last-event-id']
  end

  def test_frames_carry_the_five_fields_and_the_frame_event_id_and_topic_is_all_project_events
    c = client(sse(frame('evt_A')))
    ev = c.audit.tail.first(1).first
    assert_equal %w[actorType auditEventId eventId occurredAt outcome type], ev.keys.sort
    assert_equal 'evt_pub_evt_A', ev['eventId']
    assert_equal 'GET', @http.reqs[0].method
    assert_equal '/@portal/realtime/subscribe', URI.parse("https://x#{@http.reqs[0].path}").path
    assert_equal({ 'topic' => 'audit.project.*' }, query_of(@http.reqs[0]))
  end

  def test_one_type_subscribes_to_that_topic
    c = client(sse(frame('evt_A', 'auth.sign_in')))
    c.audit.tail(types: ['auth.sign_in']).first(1)
    assert_equal({ 'topic' => 'audit.project.auth.sign_in' }, query_of(@http.reqs[0]))
    client(sse(frame('evt_A'))).audit.tail(types: :'data.write.insert').first(1)
  end

  def test_several_types_use_the_wildcard_and_keep_only_those_types
    c = client(sse(frame('evt_A', 'auth.sign_in'), frame('evt_B', 'data.write.insert'), frame('evt_C', 'auth.sign_out')))
    evs = c.audit.tail(types: %w[auth.sign_in auth.sign_out]).first(2)
    assert_equal %w[evt_A evt_C], evs.map { |e| e['auditEventId'] }
    assert_equal({ 'topic' => 'audit.project.*' }, query_of(@http.reqs[0]))
  end

  def test_types_are_validated
    c = client(sse(frame('evt_A')))
    assert_raises(K9o::KError) { c.audit.tail(types: ['bad type']) }
    assert_raises(K9o::KError) { c.audit.tail(types: ['*']) }
    assert_empty @http.reqs
  end

  def test_dedupes_on_the_frame_event_id_and_resumes_with_the_sse_id
    c = client(sse(frame('evt_A'), frame('evt_B')), sse(frame('evt_A'), frame('evt_B'), frame('evt_C')))
    evs = c.audit.tail.first(3)
    assert_equal %w[evt_A evt_B evt_C], evs.map { |e| e['auditEventId'] }
    assert_nil @http.reqs[0]['last-event-id']
    assert_equal 'evt_pub_evt_B', @http.reqs[1]['last-event-id']
  end

  def test_heartbeats_are_ignored
    c = client(sse(":hb\n\n", ":hb\n", "\n", frame('evt_A')))
    assert_equal ['evt_A'], c.audit.tail.first(1).map { |e| e['auditEventId'] }
  end

  def test_a_frame_without_an_audit_payload_is_skipped
    odd = "id: evt_x\nevent: data.write.insert\ndata: {\"topic\":\"t\",\"eventType\":\"x\",\"eventId\":\"evt_x\"}\n\n"
    c = client(sse(odd, frame('evt_A')))
    assert_equal ['evt_A'], c.audit.tail.first(1).map { |e| e['auditEventId'] }
  end

  def test_resync_reconnects_fresh_then_replays_yields_missed_events_then_the_live_frames
    missed = [replayed('evt_B', 8, 'auth.sign_in'), replayed('evt_C', 9, 'warden.checkpoint'), replayed('evt_A', 7)]
    c = client(sse(frame('evt_A'), resync), sse(frame('evt_A'), frame('evt_D')), json('events' => missed, 'hasMore' => false))
    calls = []
    evs = c.audit.tail(on_resync: ->(info) { calls << info }).first(4)
    assert_equal %w[evt_A evt_B evt_C evt_D], evs.map { |e| e['auditEventId'] }
    assert_equal '9', evs[2]['sequence'] # replayed events carry their sequence, a String as sent
    assert_equal 'warden.checkpoint', evs[2]['type']
    assert_equal [{ 'reason' => 'cursor-unknown', 'action' => 'replay-ledger' }], calls

    assert_equal %w[GET GET POST], @http.reqs.map(&:method) # the fresh stream is open before the replay runs
    assert_nil @http.reqs[1]['last-event-id']
    assert_equal({ 'topic' => 'audit.project.*' }, query_of(@http.reqs[1]))
    replay = @http.reqs[2]
    assert_equal '/@portal/realtime/replay', replay.path
    assert_equal({ 'topic' => 'audit.project.*', 'afterAuditEventId' => 'evt_A', 'limit' => 1000 }, JSON.parse(replay.body))
  end

  def test_replay_pages_while_it_has_more_using_the_last_event_of_each_page
    page1 = [replayed('evt_B', 2)]
    page2 = [replayed('evt_C', 3)]
    c = client(sse(frame('evt_A'), resync), sse(frame('evt_D')), json('events' => page1, 'hasMore' => true),
               json('events' => page2, 'hasMore' => false))
    evs = c.audit.tail.first(4)
    assert_equal %w[evt_A evt_B evt_C evt_D], evs.map { |e| e['auditEventId'] }
    assert_equal 'evt_B', JSON.parse(@http.reqs[3].body)['afterAuditEventId']
  end

  def test_an_event_published_after_the_replay_ended_is_on_the_fresh_stream_and_yielded_once
    # E is not in the replay (published after its last event) but the fresh stream was open before the replay ran.
    c = client(sse(frame('evt_A'), resync), sse(frame('evt_B'), frame('evt_E')),
               json('events' => [replayed('evt_B', 2)], 'hasMore' => false))
    evs = c.audit.tail.first(3)
    assert_equal %w[evt_A evt_B evt_E], evs.map { |e| e['auditEventId'] }
    assert_equal 'evt_E', evs.last['auditEventId']
    assert_equal 1, evs.count { |e| e['auditEventId'] == 'evt_E' }
  end

  def test_frames_buffered_during_the_replay_come_after_the_replay_events_deduped
    c = client(sse(frame('evt_A'), resync), sse(frame('evt_B'), frame('evt_C'), frame('evt_D')),
               json('events' => [replayed('evt_B', 2), replayed('evt_C', 3)], 'hasMore' => false))
    evs = c.audit.tail.first(4)
    assert_equal %w[evt_A evt_B evt_C evt_D], evs.map { |e| e['auditEventId'] }
    assert_equal %w[2 3], [evs[1]['sequence'], evs[2]['sequence']] # B and C came from the replay, once
    assert_nil evs[3]['sequence']
  end

  def test_resync_replay_uses_the_typed_topic
    c = client(sse(frame('evt_A', 'auth.sign_in'), resync), sse(frame('evt_B', 'auth.sign_in')), json('events' => [], 'hasMore' => false))
    c.audit.tail(types: ['auth.sign_in']).first(2)
    assert_equal({ 'topic' => 'audit.project.auth.sign_in' }, query_of(@http.reqs[1]))
    assert_equal 'audit.project.auth.sign_in', JSON.parse(@http.reqs[2].body)['topic']
  end

  def test_resync_before_any_event_skips_the_replay_and_continues_from_the_fresh_connection
    c = client(sse(resync), sse(frame('evt_A')))
    assert_equal ['evt_A'], c.audit.tail.first(1).map { |e| e['auditEventId'] }
    assert_equal %w[GET GET], @http.reqs.map(&:method)
    assert_nil @http.reqs[1]['last-event-id']
  end

  # Captured from staging: a fresh connection opens with a head resync, then live frames on the same stream.
  def test_fresh_connection_head_resync_is_informational_and_the_stream_goes_on
    head = "event: resync\ndata: {\"reason\":\"cursor-evicted\",\"head\":75,\"action\":\"replay-ledger\"}\n\n"
    c = client(sse(head, frame('evt_A'), frame('evt_B')))
    calls = []
    evs = c.audit.tail(on_resync: ->(i) { calls << i }).first(2)
    assert_equal %w[evt_A evt_B], evs.map { |e| e['auditEventId'] }
    assert_empty calls
    assert_equal 1, @http.reqs.size
  end

  def test_a_second_resync_in_a_row_backs_off_and_does_not_spin
    slow = ->(*chunks) { Scripted::Resp.new('200', nil, ["retry: 1000\n:ok\n\n"] + chunks) }
    empty = json('events' => [], 'hasMore' => false)
    c = client(slow.call(frame('evt_A'), resync), slow.call(resync, resync), empty, slow.call(resync, resync), empty, slow.call(resync, resync), empty,
               slow.call(frame('evt_B')), empty)
    evs = c.audit.tail.first(2)
    assert_equal %w[evt_A evt_B], evs.map { |e| e['auditEventId'] }
    # first resync: the normal 1 s; then 1 s, 2 s, 4 s for each further resync with no event between.
    assert_equal [1.0, 1.0, 2.0, 4.0], @delays.select(&:positive?).first(4)
  end

  def test_a_normal_reconnect_after_a_drop_still_uses_last_event_id
    c = client(sse(frame('evt_A'), IOError.new('reset')), sse(frame('evt_B')))
    assert_equal %w[evt_A evt_B], c.audit.tail.first(2).map { |e| e['auditEventId'] }
    assert_equal 'evt_pub_evt_A', @http.reqs[1]['last-event-id']
  end

  def test_replay_failure_is_raised
    c = client(sse(frame('evt_A'), resync), sse(frame('evt_B')), err(400, 'K9O_INVALID_CURSOR'))
    e = assert_raises(K9o::KError) { c.audit.tail.first(2) }
    assert_equal 'K9O_INVALID_CURSOR', e.code
  end

  def test_denied_and_limit_errors_are_raised_once
    { 403 => 'K9O_RBAC_DENY', 401 => 'K9O_SESSION_EXPIRED', 429 => 'K9O_SUBSCRIPTION_LIMIT_EXCEEDED', 400 => 'K9O_INVALID_FILTER' }.each do |status, code|
      c = client(err(status, code), sse(frame('evt_A')))
      e = assert_raises(K9o::KError) { c.audit.tail.first(1) }
      assert_equal [code, status], [e.code, e.status]
      assert_equal 1, @http.reqs.size
    end
  end

  def test_server_errors_and_dropped_connections_are_retried
    c = client(err(503, 'K9O_UPSTREAM_UNAVAILABLE'), Scripted::Resp.new('200', nil, [IOError.new('reset')]), sse(frame('evt_A')))
    assert_equal ['evt_A'], c.audit.tail.first(1).map { |e| e['auditEventId'] }
    assert_equal 3, @http.reqs.size
  end

  def test_breaking_out_stops_reconnecting
    c = client(sse(frame('evt_A'), frame('evt_B')), sse(frame('evt_C')))
    seen = []
    c.audit.tail.each do |e|
      seen << e['auditEventId']
      break
    end
    assert_equal ['evt_A'], seen
    assert_equal 1, @http.reqs.size
  end

  # A real socket that goes quiet: the tail abandons the connection after the idle limit and reconnects.
  def test_idle_connection_is_abandoned_and_reconnected
    server = TCPServer.new('127.0.0.1', 0)
    port = server.addr[1]
    requests = []
    th = Thread.new do
      2.times do |i|
        s = server.accept
        head = +''
        head << s.gets until head.end_with?("\r\n\r\n")
        requests << head
        s.write("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n")
        body = i.zero? ? "retry: 0\n\n" : frame('evt_A')
        s.write("#{body.bytesize.to_s(16)}\r\n#{body}\r\n")
        if i == 1
          sleep 0.2
          s.close
        end
      end
    end
    K9o::Realtime.idle_timeout = 0.3
    c = K9o.create_client(base_url: "http://127.0.0.1:#{port}", api_key: 'k', project_slug: 'portal')
    evs = Timeout.timeout(10) { c.audit.tail.first(1) }
    assert_equal ['evt_A'], evs.map { |e| e['auditEventId'] }
    assert_equal 2, requests.size
  ensure
    th&.kill
    server&.close
  end

  # audit.replay ---------------------------------------------------------------------------------------------------

  def test_replay_body
    c = client(json('events' => []))
    c.audit.replay(topic: 'audit.project.auth.sign_in', after_audit_event_id: 'evt_A1', limit: 50)
    assert_equal ['POST', '/@portal/realtime/replay'], [@http.reqs[0].method, @http.reqs[0].path]
    assert_equal({ 'topic' => 'audit.project.auth.sign_in', 'afterAuditEventId' => 'evt_A1', 'limit' => 50 }, JSON.parse(@http.reqs[0].body))
    c.audit.replay(from_sequence: 12, until_sequence: 20)
    assert_equal({ 'topic' => 'audit.project.*', 'fromSequence' => 12, 'untilSequence' => 20, 'limit' => 1000 }, JSON.parse(@http.reqs[1].body))
  end

  def test_replay_limit_defaults_to_1000_and_is_bounded_client_side
    c = client(json('events' => []))
    c.audit.replay
    assert_equal 1000, JSON.parse(@http.reqs[0].body)['limit']
    c.audit.replay(limit: 10_000)
    assert_equal 10_000, JSON.parse(@http.reqs[1].body)['limit']
    [10_001, 0, -1].each do |bad|
      e = assert_raises(K9o::KError) { c.audit.replay(limit: bad) }
      assert_equal 'K9O_INVALID_FIELD_VALUE', e.code
    end
    assert_equal 2, @http.reqs.size
  end

  def test_replay_answers_a_typed_page_from_the_real_shape
    wire = { 'topic' => 'audit.project.*',
             'events' => [{ 'sequence' => '1', 'topic' => 'audit.project.data.write.pulse_stream.created',
                            'eventType' => 'data.write.pulse_stream.created',
                            'payload' => { 'auditEventId' => 'evt_UGgF77wit3Xx', 'type' => 'data.write.pulse_stream.created',
                                           'actorType' => 'user', 'occurredAt' => '2026-10-27T19:00:00.000Z', 'outcome' => nil },
                            'occurredAt' => '2026-10-27T19:00:00.000Z' }],
             'nextCursor' => '1', 'hasMore' => true }
    page = client(json(wire)).audit.replay(from_sequence: 0, limit: 3).data
    assert_equal %w[events hasMore nextCursor], page.keys.sort
    assert_equal true, page['hasMore']
    assert_equal '1', page['nextCursor']
    assert_equal [{ 'auditEventId' => 'evt_UGgF77wit3Xx', 'type' => 'data.write.pulse_stream.created', 'actorType' => 'user',
                    'occurredAt' => '2026-10-27T19:00:00.000Z', 'outcome' => nil, 'sequence' => '1' }], page['events']
  end

  def test_replay_validation_and_errors
    c = client(json('events' => []))
    assert_raises(K9o::KError) { c.audit.replay(topic: 'collections.x.*') }
    assert_raises(K9o::KError) { c.audit.replay(after_audit_event_id: 'nope') }
    assert_raises(K9o::KError) { c.audit.replay(from_sequence: -1) }
    assert_raises(K9o::KError) { c.audit.replay(limit: 10_001) }
    assert_empty @http.reqs
    e = assert_raises(K9o::KError) { client(err(400, 'K9O_INVALID_CURSOR')).audit.replay(after_audit_event_id: 'evt_zz') }
    assert_equal 'K9O_INVALID_CURSOR', e.code
    e = assert_raises(K9o::KError) { client(err(403, 'K9O_RBAC_DENY')).audit.replay }
    assert_equal 403, e.status
  end
end
