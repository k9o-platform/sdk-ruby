# frozen_string_literal: true

require 'minitest/autorun'
require 'json'
require 'socket'
require 'timeout'
require_relative '../lib/k9o'

# client.realtime.subscribe: resume with Last-Event-ID, dedupe by eventId, resync, heartbeat, errors, idle timeout.
class RealtimeTest < Minitest::Test
  # Answers each connection with the next canned response, recording the requests. A response whose chunks
  # contain an Exception raises it from read_body (a dropped connection).
  class ScriptedHttp
    attr_accessor :use_ssl, :read_timeout
    attr_reader :reqs, :timeouts

    Resp = Struct.new(:code, :chunks) do
      def read_body(&blk)
        chunks.each { |c| c.is_a?(Exception) ? raise(c) : blk.call(c) }
      end
    end

    def initialize(responses)
      @responses = responses
      @reqs = []
      @timeouts = []
    end

    def request(req)
      @timeouts << read_timeout
      @reqs << req
      resp = @responses[[@reqs.size - 1, @responses.size - 1].min]
      block_given? ? yield(resp) : resp
    end
  end

  TOPIC = 'collections.conformance_kv.*'

  def frame(id, rec = id)
    ev = { 'topic' => 'collections.conformance_kv.row_inserted', 'eventType' => 'row_inserted',
           'payload' => { 'collection' => 'conformance_kv', 'id' => rec },
           'occurredAt' => '2026-10-27T10:20:38.969Z', 'eventId' => id }
    "id: #{id}\nevent: row_inserted\ndata: #{JSON.generate(ev)}\n\n"
  end

  def resync
    "event: resync\ndata: {\"reason\":\"cursor-unknown\",\"action\":\"reread-source\"}\n\n"
  end

  def ok(*chunks)
    ScriptedHttp::Resp.new('200', ["retry: 0\n:ok\n\n"] + chunks)
  end

  def err(status, code = 'K9O_X')
    ScriptedHttp::Resp.new(status.to_s, [JSON.generate('code' => code, 'message' => 'no', 'context' => {})])
  end

  def client(http)
    K9o.create_client(base_url: 'https://acme.api-de01.k9o.io', api_key: 'k', project_slug: 'portal', http_client: http)
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

  def test_frame_is_yielded_with_event_id
    http = ScriptedHttp.new([ok(frame('evt_A'))])
    ev = client(http).realtime.subscribe(TOPIC).first(1).first
    assert_equal 'evt_A', ev['eventId']
    assert_equal 'row_inserted', ev['eventType']
    assert_equal 'conformance_kv', ev['payload']['collection']
    assert_equal({ 'topic' => TOPIC }, URI.decode_www_form(URI.parse("https://x#{http.reqs[0].path}").query).to_h)
    assert_nil http.reqs[0]['last-event-id']
    assert_equal 45, http.timeouts[0]
  end

  def test_reconnects_with_last_event_id
    http = ScriptedHttp.new([ok(frame('evt_A'), frame('evt_B')), ok(frame('evt_C'))])
    evs = client(http).realtime.subscribe(TOPIC).first(3)
    assert_equal %w[evt_A evt_B evt_C], evs.map { |e| e['eventId'] }
    assert_nil http.reqs[0]['last-event-id']
    assert_equal 'evt_B', http.reqs[1]['last-event-id']
  end

  def test_resent_duplicates_are_dropped
    http = ScriptedHttp.new([ok(frame('evt_A'), frame('evt_B')), ok(frame('evt_A'), frame('evt_B'), frame('evt_C'))])
    evs = client(http).realtime.subscribe(TOPIC).first(3)
    assert_equal %w[evt_A evt_B evt_C], evs.map { |e| e['eventId'] }
  end

  def test_resync_calls_handler_is_not_yielded_and_next_connection_has_no_last_event_id
    http = ScriptedHttp.new([ok(frame('evt_A'), resync, frame('evt_X')), ok(frame('evt_A'))])
    calls = []
    evs = client(http).realtime.subscribe(TOPIC, on_resync: ->(info) { calls << info }).first(2)
    assert_equal [{ 'reason' => 'cursor-unknown', 'action' => 'reread-source' }], calls
    assert_equal %w[evt_A evt_A], evs.map { |e| e['eventId'] } # dedupe set cleared by the resync
    assert_equal 2, http.reqs.size
    assert_nil http.reqs[1]['last-event-id']
  end

  def test_resync_without_handler_continues
    http = ScriptedHttp.new([ok(resync), ok(frame('evt_A'))])
    assert_equal ['evt_A'], client(http).realtime.subscribe(TOPIC).first(1).map { |e| e['eventId'] }
  end

  def head_resync
    "event: resync\ndata: {\"reason\":\"cursor-evicted\",\"head\":42,\"action\":\"reread-source\"}\n\n"
  end

  def test_opening_resync_on_a_fresh_connection_is_informational_and_events_follow_on_the_same_connection
    http = ScriptedHttp.new([ok(head_resync, frame('evt_A'))])
    calls = []
    # Without the fix the feed reconnects on the opening resync forever; the timeout turns that into a failure.
    evs = Timeout.timeout(5) { client(http).realtime.subscribe(TOPIC, on_resync: ->(info) { calls << info }).first(1) }
    assert_equal ['evt_A'], evs.map { |e| e['eventId'] }
    assert_empty calls
    assert_equal 1, http.reqs.size
  end

  def test_resync_after_an_event_is_a_real_resync
    http = ScriptedHttp.new([ok(frame('evt_A'), head_resync, frame('evt_X')), ok(frame('evt_B'))])
    calls = []
    evs = client(http).realtime.subscribe(TOPIC, on_resync: ->(info) { calls << info }).first(2)
    assert_equal %w[evt_A evt_B], evs.map { |e| e['eventId'] }
    assert_equal 1, calls.size
    assert_equal 'cursor-evicted', calls[0]['reason']
    assert_equal 2, http.reqs.size
    assert_nil http.reqs[1]['last-event-id']
  end

  def test_resync_on_a_connection_that_sent_last_event_id_is_a_real_resync
    http = ScriptedHttp.new([ok(frame('evt_A')), ok(head_resync, frame('evt_X')), ok(frame('evt_B'))])
    calls = []
    evs = client(http).realtime.subscribe(TOPIC, on_resync: ->(info) { calls << info }).first(2)
    assert_equal %w[evt_A evt_B], evs.map { |e| e['eventId'] }
    assert_equal 'evt_A', http.reqs[1]['last-event-id']
    assert_equal 1, calls.size
    assert_equal 3, http.reqs.size
    assert_nil http.reqs[2]['last-event-id']
  end

  def test_heartbeats_and_frames_without_event_type_are_ignored
    skipped = "id: evt_Z\nevent: other\ndata: {\"x\":1}\n\n"
    http = ScriptedHttp.new([ok(":hb\n\n", skipped, ":hb\n", "\n", frame('evt_A'))])
    evs = client(http).realtime.subscribe(TOPIC).first(1)
    assert_equal ['evt_A'], evs.map { |e| e['eventId'] }
  end

  def test_client_error_is_raised_once
    http = ScriptedHttp.new([err(403, 'K9O_FORBIDDEN'), ok(frame('evt_A'))])
    e = assert_raises(K9o::KError) { client(http).realtime.subscribe(TOPIC).first(1) }
    assert_equal 'K9O_FORBIDDEN', e.code
    assert_equal 1, http.reqs.size
  end

  def test_server_error_and_dropped_connection_are_retried_with_backoff
    http = ScriptedHttp.new([err(503), ScriptedHttp::Resp.new('200', [IOError.new('reset')]),
                             ok(frame('evt_A'))])
    evs = client(http).realtime.subscribe(TOPIC).first(1)
    assert_equal ['evt_A'], evs.map { |e| e['eventId'] }
    assert_equal 3, http.reqs.size
    assert_equal [1.0, 2.0], @delays # retry hint defaults to 1000 ms before the first stream; doubles on failure
  end

  def test_backoff_is_capped
    http = ScriptedHttp.new([err(503)])
    n = 0
    K9o::Realtime.sleeper = ->(s) { @delays << s; raise StopIteration if (n += 1) >= 8 }
    begin
      client(http).realtime.subscribe(TOPIC).first(1)
    rescue StopIteration
      nil
    end
    assert_equal 30.0, @delays.max
    assert_equal [1.0, 2.0, 4.0, 8.0, 16.0, 30.0, 30.0, 30.0], @delays
  end

  def test_breaking_out_stops_reconnecting
    http = ScriptedHttp.new([ok(frame('evt_A'), frame('evt_B')), ok(frame('evt_C'))])
    seen = []
    client(http).realtime.subscribe(TOPIC).each do |e|
      seen << e['eventId']
      break
    end
    assert_equal ['evt_A'], seen
    assert_equal 1, http.reqs.size
  end

  def test_server_retry_hint_sets_reconnect_delay
    http = ScriptedHttp.new([ScriptedHttp::Resp.new('200', ["retry: 2500\n\n", frame('evt_A')]), ok(frame('evt_B'))])
    client(http).realtime.subscribe(TOPIC).first(2)
    assert_equal [2.5], @delays.first(1)
  end

  # A real socket that sends headers and then goes quiet: the client abandons it after the idle limit and reconnects.
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
        sleep 0.2 if i == 1 # stay quiet on the first connection; the client must drop it
        s.close if i == 1
      end
    end
    K9o::Realtime.idle_timeout = 0.3
    c = K9o.create_client(base_url: "http://127.0.0.1:#{port}", api_key: 'k', project_slug: 'portal')
    evs = Timeout.timeout(10) { c.realtime.subscribe(TOPIC).first(1) }
    assert_equal ['evt_A'], evs.map { |e| e['eventId'] }
    assert_equal 2, requests.size
  ensure
    th&.kill
    server&.close
  end
end
