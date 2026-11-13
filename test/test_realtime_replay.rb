# frozen_string_literal: true

require 'minitest/autorun'
require 'json'
require_relative '../lib/k9o'

# client.realtime.replay: POST /@<slug>/realtime/replay with a scripted transport.
class RealtimeReplayTest < Minitest::Test
  class Scripted
    attr_accessor :use_ssl, :read_timeout
    attr_reader :reqs

    Resp = Struct.new(:code, :body) do
      def [](_name)
        nil
      end

      def read_body
        yield body
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

  TOPIC = 'collections.tasks.*'

  def json(data)
    Scripted::Resp.new('200', JSON.dump('data' => data, 'meta' => {}))
  end

  def err(status, code)
    Scripted::Resp.new(status.to_s, JSON.dump('code' => code, 'message' => 'no', 'context' => { 'reason' => 'x' }))
  end

  def client(*responses, slug: 'portal')
    @http = Scripted.new(responses)
    K9o.create_client(base_url: 'https://acme.api-de01.k9o.io', api_key: 'k', project_slug: slug, http_client: @http)
  end

  def event(id)
    { 'topic' => 'collections.tasks.row_inserted', 'eventType' => 'row_inserted',
      'payload' => { 'collection' => 'tasks', 'id' => id }, 'occurredAt' => '2026-11-13T10:00:00.000Z', 'eventId' => "evt_#{id}" }
  end

  def test_posts_the_topic_only_when_no_options_are_given
    c = client(json('events' => [], 'nextCursor' => nil, 'hasMore' => false))
    c.realtime.replay(TOPIC)
    req = @http.reqs[0]
    assert_equal 'POST', req.method
    assert_equal '/@portal/realtime/replay', req.path
    assert_equal({ 'topic' => TOPIC }, JSON.parse(req.body))
  end

  def test_sends_the_range_and_limit_in_the_gateways_spelling
    c = client(json('events' => []))
    c.realtime.replay(TOPIC, from_sequence: 5, until_sequence: 0, limit: 10_000)
    assert_equal({ 'topic' => TOPIC, 'fromSequence' => 5, 'untilSequence' => 0, 'limit' => 10_000 },
                 JSON.parse(@http.reqs[0].body))
  end

  def test_decodes_events_in_the_subscribe_shape_and_the_page_fields
    c = client(json('topic' => TOPIC, 'events' => [event('a'), 'junk', event('b')], 'nextCursor' => 'evt_b', 'hasMore' => true))
    page = c.realtime.replay(TOPIC).data
    assert_equal %w[evt_a evt_b], page['events'].map { |e| e['eventId'] }
    assert_equal %w[eventType eventId occurredAt payload topic].sort, page['events'][0].keys.sort
    assert_equal 'evt_b', page['nextCursor']
    assert_equal true, page['hasMore']
    refute page.key?('resync')
  end

  def test_carries_the_resync_hint_when_the_topic_keeps_no_history
    c = client(json('topic' => TOPIC, 'events' => [], 'nextCursor' => nil, 'hasMore' => false, 'resync' => 'reread-source'))
    page = c.realtime.replay(TOPIC).data
    assert_equal [], page['events']
    assert_equal 'reread-source', page['resync']
  end

  def test_a_malformed_answer_gives_an_empty_page
    page = client(json(nil)).realtime.replay(TOPIC).data
    assert_equal({ 'events' => [], 'nextCursor' => nil, 'hasMore' => false }, page)
  end

  def test_validates_before_sending
    c = client(json('events' => []))
    [nil, '', 'a' * 201, :topic, 5].each { |t| assert_raises(K9o::KError) { c.realtime.replay(t) } }
    [-1, 1.5, '3'].each do |bad|
      assert_raises(K9o::KError) { c.realtime.replay(TOPIC, from_sequence: bad) }
      assert_raises(K9o::KError) { c.realtime.replay(TOPIC, until_sequence: bad) }
    end
    [0, 10_001, -3, '5'].each do |bad|
      e = assert_raises(K9o::KError) { c.realtime.replay(TOPIC, limit: bad) }
      assert_equal 'K9O_INVALID_FIELD_VALUE', e.code
    end
    assert_empty @http.reqs
  end

  def test_gateway_errors_arrive_as_kerror
    e = assert_raises(K9o::KError) { client(err(400, 'K9O_INVALID_FILTER')).realtime.replay('nope.*') }
    assert_equal 'K9O_INVALID_FILTER', e.code
    e = assert_raises(K9o::KError) { client(err(403, 'K9O_RBAC_DENY')).realtime.replay(TOPIC) }
    assert_equal 'K9O_RBAC_DENY', e.code
  end

  def test_needs_a_project_slug
    c = client(json('events' => []), slug: nil)
    assert_raises(K9o::KError) { c.realtime.replay(TOPIC) }
    assert_empty @http.reqs
  end
end
