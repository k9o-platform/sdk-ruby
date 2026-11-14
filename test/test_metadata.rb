# frozen_string_literal: true

require 'minitest/autorun'
require 'json'
require 'timeout'
require_relative '../lib/k9o'

# client.metadata: wire shape (method, path, query, body), the metadata. prefix, answer decoding, client-side
# validation that sends nothing, gateway error decoding, and the reconnecting change feed.
class MetadataTest < Minitest::Test
  Resp = Struct.new(:code, :body)

  class Scripted
    attr_reader :reqs
    attr_accessor :use_ssl, :read_timeout

    def initialize(*answers)
      @answers = answers
      @reqs = []
    end

    def request(req)
      @reqs << req
      status, body = @answers.size > 1 ? @answers.shift : @answers.first
      Resp.new(status.to_s, body)
    end
  end

  # Streaming responses for subscribe: each connection gets the next canned response.
  class ScriptedSse
    attr_accessor :use_ssl, :read_timeout
    attr_reader :reqs

    SResp = Struct.new(:code, :chunks) do
      def read_body(&blk)
        chunks.each { |c| blk.call(c) }
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

  BASE = '/@portal/metadata'
  P1 = { 'surface' => 'collection:posts', 'scope' => 'posts', 'recordId' => 'p1',
         'metadata' => { 'title' => 'Quarterly report', 'body' => 'Finance review', 'tags' => %w[pinned finance], 'priority' => 3,
                         'embedding' => '[1,0,0]' } }.freeze
  TELEMETRY = { 'surface' => 'telemetry:collection.metadata_index_declared', 'scope' => 'collection.metadata_index_declared',
                'eventId' => 'aud_1', 'metadata' => { 'id' => 'aud_1', 'actorId' => 'usr_1', 'occurredAt' => '2026-10-26T20:00:00.000Z' } }.freeze

  def client(*answers)
    @rec = Scripted.new(*answers)
    K9o.create_client(base_url: 'https://acme.api-de01.k9o.io', api_key: 'k', project_slug: 'portal', http_client: @rec)
  end

  def ok(data, cursor: nil, status: 200)
    meta = { 'requestId' => 'req_1', 'traceId' => 'req_1', 'cursor' => { 'next' => cursor } }
    [status, JSON.dump('data' => data, 'meta' => meta)]
  end

  def fail_with(status, code, context = {})
    [status, JSON.dump('code' => code, 'message' => 'no', 'context' => context)]
  end

  def last
    req = @rec.reqs.last
    uri = URI.parse("https://x#{req.path}")
    [req.method, uri.path, uri.query, req.body && JSON.parse(req.body)]
  end

  def assert_invalid(code = 'K9O_INVALID_FIELD_VALUE', &blk)
    before = @rec.reqs.size
    e = assert_raises(K9o::KError, &blk)
    assert_equal code, e.code
    assert_equal before, @rec.reqs.size
  end

  # filter

  def test_filter_posts_prefixed_fields_and_returns_rows_with_cursor
    c = client(ok([P1], cursor: 'cur_2'))
    page = c.metadata.filter(surfaces: ['collection:posts'], where: [{ field: 'priority', op: :gte, value: 2 }, { 'field' => 'metadata.title', 'op' => 'eq', 'value' => 'x' }], limit: 50)
    assert_equal ['POST', "#{BASE}/query", nil,
                  { 'surfaces' => ['collection:posts'],
                    'where' => [{ 'field' => 'metadata.priority', 'op' => 'gte', 'value' => 2 },
                                { 'field' => 'metadata.title', 'op' => 'eq', 'value' => 'x' }],
                    'limit' => 50 }], last
    assert_equal 'p1', page.data[0]['recordId']
    assert_equal 'Quarterly report', page.data[0]['metadata']['title']
    assert_equal 'cur_2', page.cursor
    assert_equal 'cur_2', page.meta.cursor.next
    assert_kind_of K9o::Envelope, page
  end

  def test_filter_accepts_a_hash_with_or_without_braces
    c = client(ok([P1]))
    c.metadata.filter({ surfaces: ['collection:posts'], cursor: 'abc' })
    assert_equal({ 'surfaces' => ['collection:posts'], 'cursor' => 'abc' }, last[3])
    c.metadata.filter('surfaces' => ['collection:posts'])
    assert_equal({ 'surfaces' => ['collection:posts'] }, last[3])
  end

  def test_filter_sends_only_surfaces_by_default_and_reports_nil_cursor
    c = client(ok([P1]))
    page = c.metadata.filter(surfaces: ['collection:posts'])
    assert_equal({ 'surfaces' => ['collection:posts'] }, last[3])
    assert_nil page.cursor
  end

  def test_filter_keeps_createdat_and_actorid_bare_on_telemetry
    c = client(ok([TELEMETRY]))
    page = c.metadata.filter(surfaces: ['telemetry:collection.metadata_index_declared'],
                             where: [{ field: 'createdAt', op: 'gte', value: '2026-10-01T00:00:00Z' }, { field: 'actorId', op: 'eq', value: 'usr_1' },
                                     { field: 'other', op: 'eq', value: 1 }])
    assert_equal [{ 'field' => 'createdAt', 'op' => 'gte', 'value' => '2026-10-01T00:00:00Z' },
                  { 'field' => 'actorId', 'op' => 'eq', 'value' => 'usr_1' },
                  { 'field' => 'metadata.other', 'op' => 'eq', 'value' => 1 }], last[3]['where']
    assert_equal 'aud_1', page.data[0]['eventId']
    # collection surface: createdAt is a column and is prefixed
    c.metadata.filter(surfaces: ['collection:posts'], where: [{ field: 'createdAt', op: 'eq', value: 1 }])
    assert_equal 'metadata.createdAt', last[3]['where'][0]['field']
  end

  def test_filter_passes_storage_surface_and_decodes_501
    c = client(fail_with(501, 'K9O_NOT_IMPLEMENTED', 'surface' => 'storage:docs'))
    e = assert_raises(K9o::KError) { c.metadata.filter(surfaces: ['storage:docs']) }
    assert_equal 'K9O_NOT_IMPLEMENTED', e.code
    assert_equal 501, e.status
    assert_equal ['storage:docs'], last[3]['surfaces']
  end

  def test_filter_decodes_413_and_400
    c = client(fail_with(413, 'K9O_QUERY_RESULT_TOO_LARGE', 'cap' => 10_000, 'surfaces' => %w[a b]))
    e = assert_raises(K9o::KError) { c.metadata.filter(surfaces: ['collection:posts']) }
    assert_equal ['K9O_QUERY_RESULT_TOO_LARGE', 413], [e.code, e.status]
    assert_equal 10_000, e.context['cap'] || e.context[:cap]
    c = client(fail_with(400, 'K9O_METADATA_FIELD_NOT_INDEXED', 'field' => 'metadata.nope'))
    e = assert_raises(K9o::KError) { c.metadata.filter(surfaces: ['collection:posts'], where: [{ field: 'nope', op: 'eq', value: 1 }]) }
    assert_equal ['K9O_METADATA_FIELD_NOT_INDEXED', 400], [e.code, e.status]
    c = client(fail_with(400, 'K9O_ENCRYPTED_COLUMN_OPERATION_UNSUPPORTED'))
    assert_equal 'K9O_ENCRYPTED_COLUMN_OPERATION_UNSUPPORTED', assert_raises(K9o::KError) { c.metadata.filter(surfaces: ['collection:posts']) }.code
    c = client(fail_with(403, 'K9O_EXTENSION_PERMISSION_DENIED'))
    assert_equal 403, assert_raises(K9o::KError) { c.metadata.filter(surfaces: ['collection:posts']) }.status
  end

  def test_filter_validation_sends_nothing
    c = client(ok([]))
    p1 = ['collection:posts']
    assert_invalid { c.metadata.filter }
    assert_invalid { c.metadata.filter(surfaces: []) }
    assert_invalid { c.metadata.filter(surfaces: 'collection:posts') }
    assert_invalid('K9O_UNKNOWN_SURFACE') { c.metadata.filter(surfaces: ['posts']) }
    assert_invalid('K9O_UNKNOWN_SURFACE') { c.metadata.filter(surfaces: ['table:posts']) }
    assert_invalid('K9O_UNKNOWN_SURFACE') { c.metadata.filter(surfaces: ['collection:']) }
    assert_invalid('K9O_UNKNOWN_SURFACE') { c.metadata.filter(surfaces: ['collection:a.b']) }
    assert_invalid { c.metadata.filter(surfaces: [:'collection:posts']) }
    assert_invalid { c.metadata.filter(surfaces: p1, limit: 0) }
    assert_invalid { c.metadata.filter(surfaces: p1, limit: 1001) }
    assert_invalid { c.metadata.filter(surfaces: p1, limit: 1.5) }
    assert_invalid { c.metadata.filter(surfaces: p1, cursor: '') }
    assert_invalid { c.metadata.filter(surfaces: p1, cursor: 5) }
    assert_invalid { c.metadata.filter(surfaces: %w[collection:a collection:b], cursor: 'x') }
    assert_invalid { c.metadata.filter(surfaces: p1, where: 'x') }
    assert_invalid { c.metadata.filter(surfaces: p1, where: ['x']) }
    assert_invalid { c.metadata.filter(surfaces: p1, where: [{ field: 'a', op: 'like', value: 1 }]) }
    assert_invalid { c.metadata.filter(surfaces: p1, where: [{ field: 'a', value: 1 }]) }
    assert_invalid { c.metadata.filter(surfaces: p1, where: [{ field: '', op: 'eq' }]) }
    assert_invalid { c.metadata.filter(surfaces: p1, where: [{ field: 'metadata.', op: 'eq' }]) }
    assert_invalid { c.metadata.filter(surfaces: p1, where: [{ op: 'eq' }]) }
    assert_invalid { c.metadata.filter(surfaces: p1, limt: 5) }
    assert_equal 0, @rec.reqs.size
  end

  def test_filter_accepts_every_operator_and_the_limit_bounds
    c = client(ok([]))
    K9o::Metadata::OPS.each { |op| c.metadata.filter(surfaces: ['collection:posts'], where: [{ field: 'a', op: op }], limit: 1000) }
    assert_equal 14, @rec.reqs.size
    assert_equal({ 'field' => 'metadata.a', 'op' => 'not' }, last[3]['where'][0])
  end

  def test_requires_project_slug
    c = K9o.create_client(base_url: 'https://acme.api-de01.k9o.io', api_key: 'k', http_client: Scripted.new(ok([])))
    e = assert_raises(K9o::KError) { c.metadata.filter(surfaces: ['collection:posts']) }
    assert_equal 'K9O_MISSING_PROJECT_CONTEXT', e.code
  end

  # set

  def test_set_patches_bare_columns_and_returns_the_record
    c = client(ok({ 'id' => 'p2', 'title' => 'New', 'priority' => 9, 'secret' => 's2' }))
    r = c.metadata.set('posts', 'p2', { title: 'New', 'metadata.priority' => 9 })
    assert_equal ['PATCH', "#{BASE}/collection/posts/p2", nil, { 'metadata' => { 'title' => 'New', 'priority' => 9 } }], last
    assert_equal 'New', r.data['title']
    assert_equal 's2', r.data['secret']
    c.metadata.set('posts', 'p/2 x', title: 'T')
    assert_equal "#{BASE}/collection/posts/p%2F2%20x", last[1]
    assert_equal({ 'metadata' => { 'title' => 'T' } }, last[3])
  end

  def test_set_decodes_not_indexed_and_not_found
    c = client(fail_with(400, 'K9O_METADATA_FIELD_NOT_INDEXED', 'field' => 'metadata.secret'))
    assert_equal 'K9O_METADATA_FIELD_NOT_INDEXED', assert_raises(K9o::KError) { c.metadata.set('posts', 'p2', secret: 'x') }.code
    c = client(fail_with(404, 'K9O_NOT_FOUND'))
    assert_equal 404, assert_raises(K9o::KError) { c.metadata.set('posts', 'zz', title: 'x') }.status
  end

  def test_set_validation_sends_nothing
    c = client(ok({}))
    assert_invalid { c.metadata.set('posts', 'p1', {}) }
    assert_invalid { c.metadata.set('posts', 'p1') }
    assert_invalid { c.metadata.set('posts', 'p1', [1]) }
    assert_invalid { c.metadata.set('posts', '', title: 'x') }
    assert_invalid { c.metadata.set('posts', nil, title: 'x') }
    assert_invalid { c.metadata.set('bad name', 'p1', title: 'x') }
    assert_invalid { c.metadata.set(nil, 'p1', title: 'x') }
    assert_equal 0, @rec.reqs.size
  end

  # search

  def test_search_posts_surface_prefixed_field_q_and_limit
    c = client(ok([P1]))
    page = c.metadata.search(surface: 'collection:posts', field: 'body', q: 'finance', limit: 20)
    assert_equal ['POST', "#{BASE}/search", nil, { 'surface' => 'collection:posts', 'field' => 'metadata.body', 'q' => 'finance', 'limit' => 20 }], last
    assert_equal ['p1'], page.data.map { |r| r['recordId'] }
    assert_nil page.cursor
  end

  def test_search_keeps_prefix_and_omits_limit
    c = client(ok([]))
    c.metadata.search({ surface: 'collection:posts', field: 'metadata.body', q: 'x' })
    assert_equal({ 'surface' => 'collection:posts', 'field' => 'metadata.body', 'q' => 'x' }, last[3])
  end

  def test_search_validation_sends_nothing
    c = client(ok([]))
    ok_args = { surface: 'collection:posts', field: 'body', q: 'x' }
    assert_invalid { c.metadata.search }
    assert_invalid { c.metadata.search(ok_args.merge(surface: 'telemetry:a')) }
    assert_invalid { c.metadata.search(ok_args.merge(surface: 'storage:a')) }
    assert_invalid('K9O_UNKNOWN_SURFACE') { c.metadata.search(ok_args.merge(surface: 'nope')) }
    assert_invalid { c.metadata.search(ok_args.merge(field: '')) }
    assert_invalid { c.metadata.search(ok_args.merge(field: nil)) }
    assert_invalid { c.metadata.search(ok_args.merge(q: '')) }
    assert_invalid { c.metadata.search(ok_args.merge(q: 5)) }
    assert_invalid { c.metadata.search(ok_args.merge(limit: 0)) }
    assert_invalid { c.metadata.search(ok_args.merge(cursor: 'x')) }
    assert_equal 0, @rec.reqs.size
  end

  def test_search_decodes_encrypted_column_answer
    c = client(fail_with(400, 'K9O_ENCRYPTED_COLUMN_OPERATION_UNSUPPORTED', 'op' => 'textSearch'))
    assert_equal 'K9O_ENCRYPTED_COLUMN_OPERATION_UNSUPPORTED',
                 assert_raises(K9o::KError) { c.metadata.search(surface: 'collection:posts', field: 'secret', q: 'x') }.code
  end

  # vectors.nearest

  def test_nearest_posts_prefixed_column_embedding_and_options
    c = client(ok([P1]))
    page = c.metadata.vectors.nearest(surface: 'collection:posts', column: 'embedding', embedding: [1, 0, 0.5], k: 3, metric: :dot,
                                      where: [{ field: 'priority', op: 'gte', value: 2 }])
    assert_equal ['POST', "#{BASE}/vectors/nearest", nil,
                  { 'surface' => 'collection:posts', 'column' => 'metadata.embedding', 'embedding' => [1, 0, 0.5], 'k' => 3,
                    'metric' => 'dot', 'where' => [{ 'field' => 'metadata.priority', 'op' => 'gte', 'value' => 2 }] }], last
    assert_equal ['p1'], page.data.map { |r| r['recordId'] }
    refute page.data[0].key?('score')
    assert_nil page.cursor
  end

  def test_nearest_sends_only_required_fields_by_default
    c = client(ok([]))
    c.metadata.vectors.nearest(surface: 'collection:posts', column: 'metadata.embedding', embedding: [1])
    assert_equal({ 'surface' => 'collection:posts', 'column' => 'metadata.embedding', 'embedding' => [1] }, last[3])
  end

  def test_nearest_never_leaves_createdat_bare
    c = client(ok([]))
    c.metadata.vectors.nearest(surface: 'collection:posts', column: 'e', embedding: [1], where: [{ field: 'createdAt', op: 'gt', value: 1 }])
    assert_equal 'metadata.createdAt', last[3]['where'][0]['field']
  end

  def test_nearest_validation_sends_nothing
    c = client(ok([]))
    base = { surface: 'collection:posts', column: 'embedding', embedding: [1, 0] }
    assert_invalid { c.metadata.vectors.nearest }
    assert_invalid { c.metadata.vectors.nearest(base.merge(surface: 'telemetry:a')) }
    assert_invalid { c.metadata.vectors.nearest(base.merge(column: '')) }
    assert_invalid { c.metadata.vectors.nearest(base.merge(embedding: [])) }
    assert_invalid { c.metadata.vectors.nearest(base.merge(embedding: nil)) }
    assert_invalid { c.metadata.vectors.nearest(base.merge(embedding: [1, Float::NAN])) }
    assert_invalid { c.metadata.vectors.nearest(base.merge(embedding: [1, Float::INFINITY])) }
    assert_invalid { c.metadata.vectors.nearest(base.merge(embedding: [1, '2'])) }
    assert_invalid { c.metadata.vectors.nearest(base.merge(k: 0)) }
    assert_invalid { c.metadata.vectors.nearest(base.merge(k: 1001)) }
    assert_invalid { c.metadata.vectors.nearest(base.merge(metric: 'manhattan')) }
    assert_invalid { c.metadata.vectors.nearest(base.merge(where: [{ field: 'a', op: 'bad' }])) }
    assert_equal 0, @rec.reqs.size
  end

  # index

  def test_index_get
    c = client(ok({ 'collection' => 'posts', 'columns' => [{ 'column' => 'body', 'indexed' => false }, { 'column' => 'tags', 'indexed' => true }] }))
    r = c.metadata.index.get('posts')
    assert_equal ['GET', "#{BASE}/index/posts", nil, nil], last
    assert_equal %w[body tags], r.data['columns'].map { |x| x['column'] }
    assert_invalid { c.metadata.index.get('bad name') }
  end

  def test_index_declare_puts_columns
    c = client(ok({ 'collection' => 'posts', 'columns' => [{ 'column' => 'body', 'indexed' => false }, { 'column' => 'title', 'indexed' => false }] }))
    r = c.metadata.index.declare('posts', [{ column: 'title' }, { 'column' => 'tags', 'indexed' => true }, { column: :body, indexed: false }])
    assert_equal ['PUT', "#{BASE}/index/posts", nil,
                  { 'columns' => [{ 'column' => 'title' }, { 'column' => 'tags', 'indexed' => true }, { 'column' => 'body', 'indexed' => false }] }], last
    assert_equal 'posts', r.data['collection']
  end

  def test_index_declare_clears_with_empty_list_and_accepts_64
    c = client(ok({ 'collection' => 'posts', 'columns' => [] }))
    c.metadata.index.declare('posts', [])
    assert_equal({ 'columns' => [] }, last[3])
    c.metadata.index.declare('posts', Array.new(64) { |i| { column: "c#{i}" } })
    assert_equal 64, last[3]['columns'].size
  end

  def test_index_declare_validation_sends_nothing
    c = client(ok({}))
    assert_invalid { c.metadata.index.declare('posts', Array.new(65) { |i| { column: "c#{i}" } }) }
    assert_invalid { c.metadata.index.declare('posts', [{ column: 'id' }]) }
    assert_invalid { c.metadata.index.declare('posts', [{ column: 'a' }, { column: 'a' }]) }
    assert_invalid { c.metadata.index.declare('posts', [{ column: '1a' }]) }
    assert_invalid { c.metadata.index.declare('posts', [{ column: 'a-b' }]) }
    assert_invalid { c.metadata.index.declare('posts', [{ column: 'a', indexed: 'yes' }]) }
    assert_invalid { c.metadata.index.declare('posts', ['a']) }
    assert_invalid { c.metadata.index.declare('posts', nil) }
    assert_invalid { c.metadata.index.declare('bad name', []) }
    assert_equal 0, @rec.reqs.size
  end

  def test_index_declare_decodes_missing_collection_and_refused_role
    c = client(fail_with(404, 'K9O_COLLECTION_NOT_FOUND'))
    assert_equal 404, assert_raises(K9o::KError) { c.metadata.index.declare('nope', []) }.status
    c = client(fail_with(403, 'K9O_ACCESS_DENIED'))
    assert_equal 'K9O_ACCESS_DENIED', assert_raises(K9o::KError) { c.metadata.index.declare('posts', []) }.code
  end

  # subscribe

  def frame(id, rec = id, type = 'row_updated')
    ev = { 'topic' => "collections.posts.#{type}", 'eventType' => type, 'payload' => { 'collection' => 'posts', 'id' => rec },
           'occurredAt' => '2026-10-27T10:20:38.969Z' }
    "id: #{id}\nevent: #{type}\ndata: #{JSON.generate(ev)}\n\n"
  end

  def sse_ok(*chunks)
    ScriptedSse::SResp.new('200', ["retry: 0\n:ok\n\n"] + chunks)
  end

  def feed_client(http)
    K9o.create_client(base_url: 'https://acme.api-de01.k9o.io', api_key: 'k', project_slug: 'portal', http_client: http)
  end

  def query_of(req)
    URI.decode_www_form(URI.parse("https://x#{req.path}").query).to_h
  end

  def with_no_sleep
    saved = K9o::Realtime.sleeper
    K9o::Realtime.sleeper = ->(_s) {}
    yield
  ensure
    K9o::Realtime.sleeper = saved
  end

  def test_subscribe_opens_the_feed_with_surface_and_from_sequence
    with_no_sleep do
      http = ScriptedSse.new([sse_ok(frame('1-5', 'p2'))])
      evs = feed_client(http).metadata.subscribe('collection:posts', from_sequence: 12).first(1)
      assert_equal 'row_updated', evs[0]['eventType']
      assert_equal({ 'collection' => 'posts', 'id' => 'p2' }, evs[0]['payload'])
      assert_equal '/@portal/metadata/subscribe', URI.parse("https://x#{http.reqs[0].path}").path
      assert_equal({ 'surface' => 'collection:posts', 'fromSequence' => '12' }, query_of(http.reqs[0]))
    end
  end

  def test_subscribe_omits_from_sequence_when_not_given_and_accepts_a_hash
    with_no_sleep do
      http = ScriptedSse.new([sse_ok(frame('a'))])
      feed_client(http).metadata.subscribe('collection:posts', { on_resync: nil }).first(1)
      assert_equal({ 'surface' => 'collection:posts' }, query_of(http.reqs[0]))
    end
  end

  def test_subscribe_reconnects_with_last_event_id_instead_of_from_sequence_and_drops_resent_frames
    with_no_sleep do
      http = ScriptedSse.new([sse_ok(frame('1-1'), frame('1-2')), sse_ok(frame('1-2'), frame('1-3', 'p9', 'row_deleted'))])
      evs = feed_client(http).metadata.subscribe('collection:posts', from_sequence: 3).first(3)
      assert_equal %w[p9], evs.last(1).map { |e| e['payload']['id'] }
      assert_equal %w[row_updated row_updated row_deleted], evs.map { |e| e['eventType'] }
      assert_equal 2, http.reqs.size
      assert_equal '3', query_of(http.reqs[0])['fromSequence']
      assert_nil query_of(http.reqs[1])['fromSequence']
      assert_equal '1-2', http.reqs[1]['last-event-id']
    end
  end

  def test_subscribe_resync_calls_handler_and_next_connection_has_no_last_event_id_or_from_sequence
    with_no_sleep do
      resync = "event: resync\ndata: {\"reason\":\"cursor-evicted\",\"action\":\"reread-source\"}\n\n"
      http = ScriptedSse.new([sse_ok(resync), sse_ok(frame('2-1'))])
      calls = []
      evs = feed_client(http).metadata.subscribe('collection:posts', from_sequence: 7, on_resync: ->(i) { calls << i }).first(1)
      assert_equal 1, evs.size
      assert_equal [{ 'reason' => 'cursor-evicted', 'action' => 'reread-source' }], calls
      assert_equal '7', query_of(http.reqs[0])['fromSequence']
      assert_nil query_of(http.reqs[1])['fromSequence']
      assert_nil http.reqs[1]['last-event-id']
    end
  end

  def test_subscribe_opening_resync_is_informational_and_events_follow_on_the_same_connection
    with_no_sleep do
      resync = "event: resync\ndata: {\"reason\":\"cursor-evicted\",\"head\":42,\"action\":\"reread-source\"}\n\n"
      http = ScriptedSse.new([sse_ok(resync, frame('3-1'))])
      calls = []
      evs = Timeout.timeout(5) { feed_client(http).metadata.subscribe('collection:posts', on_resync: ->(i) { calls << i }).first(1) }
      assert_equal ['row_updated'], evs.map { |e| e['eventType'] }
      assert_empty calls
      assert_equal 1, http.reqs.size
    end
  end

  def test_subscribe_opening_resync_on_a_connection_sent_with_from_sequence_is_a_real_resync
    with_no_sleep do
      resync = "event: resync\ndata: {\"reason\":\"cursor-evicted\",\"head\":42,\"action\":\"reread-source\"}\n\n"
      http = ScriptedSse.new([sse_ok(resync, frame('9-9')), sse_ok(frame('3-1'))])
      calls = []
      evs = Timeout.timeout(5) do
        feed_client(http).metadata.subscribe('collection:posts', from_sequence: 7, on_resync: ->(i) { calls << i }).first(1)
      end
      assert_equal 1, calls.size
      assert_equal 'cursor-evicted', calls[0]['reason']
      assert_equal 1, evs.size
      assert_equal 2, http.reqs.size
      assert_equal '7', query_of(http.reqs[0])['fromSequence']
      assert_nil query_of(http.reqs[1])['fromSequence']
      assert_nil http.reqs[1]['last-event-id']
    end
  end

  def test_subscribe_validation_raises_before_connecting
    http = ScriptedSse.new([sse_ok])
    c = feed_client(http)
    assert_raises(K9o::KError) { c.metadata.subscribe('telemetry:a') }
    assert_raises(K9o::KError) { c.metadata.subscribe('storage:a') }
    assert_equal 'K9O_UNKNOWN_SURFACE', assert_raises(K9o::KError) { c.metadata.subscribe('nope') }.code
    assert_equal 'K9O_INVALID_FIELD_VALUE', assert_raises(K9o::KError) { c.metadata.subscribe('collection:posts', from_sequence: -1) }.code
    assert_equal 'K9O_INVALID_FIELD_VALUE', assert_raises(K9o::KError) { c.metadata.subscribe('collection:posts', from_sequence: 1.5) }.code
    assert_equal 'K9O_INVALID_FIELD_VALUE', assert_raises(K9o::KError) { c.metadata.subscribe('collection:posts', bogus: 1) }.code
    assert_equal 0, http.reqs.size
  end

  def test_subscribe_client_error_is_raised_once
    http = ScriptedSse.new([ScriptedSse::SResp.new('403', [JSON.generate('code' => 'K9O_EXTENSION_PERMISSION_DENIED', 'message' => 'no', 'context' => {})])])
    e = assert_raises(K9o::KError) { feed_client(http).metadata.subscribe('collection:posts').first(1) }
    assert_equal 'K9O_EXTENSION_PERMISSION_DENIED', e.code
    assert_equal 1, http.reqs.size
  end
end
