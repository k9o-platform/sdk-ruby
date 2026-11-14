# frozen_string_literal: true

require 'minitest/autorun'
require 'json'
require_relative '../lib/k9o'

# Datasets (analytics, analytics.rollups, analytics.schedules) and top-level rollups: method, path, query, body and
# response decoding against a stubbed transport, plus the error paths named in the OpenAPI.
class DatasetsTest < Minitest::Test
  class Stub
    attr_reader :reqs
    attr_accessor :use_ssl, :read_timeout

    Resp = Struct.new(:code, :body, :headers, :chunks) do
      def [](name)
        (headers || {})[name.downcase]
      end

      def read_body(&blk)
        (chunks || [body]).each { |c| c.is_a?(Exception) ? raise(c) : blk.call(c) }
      end
    end

    def initialize(*answers)
      @answers = answers
      @reqs = []
    end

    def request(req)
      @reqs << req
      a = @answers.size > 1 ? @answers.shift : @answers.first
      resp = Resp.new(a[0].to_s, a[1], a[2] || {}, a[3])
      block_given? ? yield(resp) : resp
    end
  end

  def env(data, meta = {})
    JSON.dump('data' => data, 'meta' => meta)
  end

  def client(*answers)
    @http = Stub.new(*(answers.empty? ? [[200, env({})]] : answers))
    K9o.create_client(base_url: 'https://acme.api-de01.k9o.io', api_key: 'k', project_slug: 'portal', http_client: @http)
  end

  def sent
    req = @http.reqs.last
    u = URI.parse("https://x#{req.path}")
    json = req['content-type'] == 'application/json' && !req.body.to_s.empty?
    [req.method, u.path, URI.decode_www_form(u.query || '').to_h, json ? JSON.parse(req.body) : nil, req]
  end

  def assert_sent(method, path, query: {}, body: nil)
    m, p, q, b, = sent
    assert_equal [method, path], [m, p]
    assert_equal query, q
    body.nil? ? assert_nil(b) : assert_equal(body, b)
  end

  def err(status, code, message = 'no', context = {}, headers = {})
    [status, JSON.dump('code' => code, 'message' => message, 'context' => context), headers]
  end

  # datasets -------------------------------------------------------------------------------------------------------

  def test_list_and_get_and_delete
    c = client([200, env([{ 'slug' => 'orders' }])])
    assert_equal [{ 'slug' => 'orders' }], c.analytics.list.data
    assert_sent('GET', '/@portal/analytics')
    c.analytics.get('orders')
    assert_sent('GET', '/@portal/analytics/orders')
    c.analytics.delete('orders')
    assert_sent('DELETE', '/@portal/analytics/orders')
  end

  def test_create_body
    c = client([200, env({ 'slug' => 'orders' })])
    c.analytics.create('orders', display_name: 'Orders', residency_class: :shared,
                                 columns: [{ name: 'id', type: 'string' }, { 'name' => 'at', 'type' => 'timestamp' }],
                                 partition_by: ['at:day'], storage_target: { kind: 'byos', bindingId: 'bind_1' })
    assert_sent('POST', '/@portal/analytics/orders',
                body: { 'displayName' => 'Orders', 'residencyClass' => 'shared',
                        'columns' => [{ 'name' => 'id', 'type' => 'string' }, { 'name' => 'at', 'type' => 'timestamp' }],
                        'partitionBy' => ['at:day'], 'storageTarget' => { 'kind' => 'byos', 'bindingId' => 'bind_1' } })
  end

  def test_create_validates_before_sending
    c = client
    assert_raises(K9o::KError) { c.analytics.create('o', display_name: 'O', columns: [], residency_class: 'shared') }
    assert_raises(K9o::KError) { c.analytics.create('o', display_name: 'O', columns: [{ name: 'a', type: 'int32' }], residency_class: 'other') }
    assert_empty @http.reqs
  end

  def test_create_error_paths
    [[409, 'K9O_STATE_CONFLICT'], [429, 'K9O_DATASET_LIMIT_EXCEEDED'], [400, 'K9O_INVALID_REQUEST_SHAPE']].each do |status, code|
      c = client(err(status, code))
      e = assert_raises(K9o::KError) do
        c.analytics.create('o', display_name: 'O', columns: [{ name: 'a', type: 'int32' }], residency_class: 'shared')
      end
      assert_equal [code, status], [e.code, e.status]
    end
  end

  def test_query_body_and_validation
    c = client([200, env([{ 'n' => 3 }])])
    assert_equal [{ 'n' => 3 }], c.analytics.query('SELECT count(*) AS n FROM dataset.orders', ['orders']).data
    assert_sent('POST', '/@portal/analytics/query', body: { 'sql' => 'SELECT count(*) AS n FROM dataset.orders', 'datasets' => ['orders'] })
    assert_raises(K9o::KError) { c.analytics.query('', ['orders']) }
    assert_raises(K9o::KError) { c.analytics.query('SELECT 1', []) }
    assert_raises(K9o::KError) { c.analytics.query('x' * 100_001, ['orders']) }
  end

  def test_query_error_paths
    { 400 => 'K9O_QUERY_INVALID', 404 => 'K9O_DATASET_NOT_FOUND', 500 => 'K9O_QUERY_EXECUTION_FAILED',
      503 => 'K9O_ANALYTICS_UNAVAILABLE' }.each do |status, code|
      e = assert_raises(K9o::KError) { client(err(status, code)).analytics.query('SELECT 1', ['orders']) }
      assert_equal [code, status], [e.code, e.status]
    end
  end

  def test_materialize_exactly_one_source
    c = client
    c.analytics.materialize('orders', from_collection: 'orders_raw')
    assert_sent('POST', '/@portal/analytics/orders/materialize', body: { 'fromCollection' => 'orders_raw' })
    c.analytics.materialize('orders', from_query: 'q_1')
    assert_sent('POST', '/@portal/analytics/orders/materialize', body: { 'fromQuery' => 'q_1' })
    assert_raises(K9o::KError) { c.analytics.materialize('orders') }
    assert_raises(K9o::KError) { c.analytics.materialize('orders', from_collection: 'a', from_query: 'b') }
  end

  def test_read_pages_with_the_cursor
    c = client([200, env([{ '_k9o_row_id' => 'r1' }], 'cursor' => { 'next' => 'cur_2' })],
               [200, env([{ '_k9o_row_id' => 'r2' }], {})])
    first = c.analytics.read('orders', partition_filter: { region: 'de01' }, limit: 1)
    assert_sent('POST', '/@portal/analytics/orders/read', body: { 'partitionFilter' => { 'region' => 'de01' }, 'limit' => 1 })
    assert_equal 'cur_2', first.meta.cursor.next
    second = c.analytics.read('orders', cursor: first.meta.cursor.next, limit: 1)
    assert_sent('POST', '/@portal/analytics/orders/read', body: { 'cursor' => 'cur_2', 'limit' => 1 })
    assert_nil second.meta.cursor
  end

  def test_write_array_ndjson_and_on_error
    c = client([200, env({ 'ingested' => 2, 'skipped' => 0 })])
    assert_equal 2, c.analytics.write('orders', [{ id: 'a' }, { id: 'b' }], on_error: 'reject').data['ingested']
    assert_sent('POST', '/@portal/analytics/orders/write', query: { 'onError' => 'reject' }, body: [{ 'id' => 'a' }, { 'id' => 'b' }])
    c.analytics.write('orders', %({"id":"a"}\n{"id":"b"}\n))
    _, _, q, _, req = sent
    assert_equal({}, q)
    assert_equal 'application/x-ndjson', req['content-type']
    assert_equal %({"id":"a"}\n{"id":"b"}\n), req.body
    assert_raises(K9o::KError) { c.analytics.write('orders', 'x', on_error: 'maybe') }
    assert_raises(K9o::KError) { c.analytics.write('orders', 5) }
  end

  def test_write_error_paths
    e = assert_raises(K9o::KError) { client(err(400, 'K9O_INGEST_SCHEMA_MISMATCH')).analytics.write('o', [{}], on_error: 'reject') }
    assert_equal 'K9O_INGEST_SCHEMA_MISMATCH', e.code
    e = assert_raises(K9o::KError) { client(err(503, 'K9O_ANALYTICS_UNAVAILABLE')).analytics.write('o', [{}]) }
    assert_equal 503, e.status
  end

  def test_upload_raw_csv_with_options
    c = client([200, env({ 'ingested' => 1 })])
    c.analytics.upload('orders', "id,qty\na,1\n", format: :csv, dry_run: true, on_error: 'skip', delimiter: ';',
                                                    encoding: 'utf-8', has_header: true)
    _, path, q, _, req = sent
    assert_equal '/@portal/analytics/orders/upload', path
    assert_equal({ 'format' => 'csv', 'dryRun' => 'true', 'onError' => 'skip', 'delimiter' => ';', 'encoding' => 'utf-8',
                   'hasHeader' => 'true' }, q)
    assert_equal 'text/csv', req['content-type']
    assert_equal "id,qty\na,1\n", req.body
  end

  def test_upload_json_and_io
    c = client
    c.analytics.upload('orders', StringIO.new('[{"id":"a"}]'), format: 'json')
    _, _, q, _, req = sent
    assert_equal({ 'format' => 'json' }, q)
    assert_equal 'application/json', req['content-type']
    assert_equal '[{"id":"a"}]', req.body
  end

  def test_upload_with_manifest_is_multipart
    c = client
    manifest = { displayName: 'Orders', residencyClass: 'shared', columns: [{ name: 'id', type: 'string' }] }
    c.analytics.upload('orders', "id\na\n", format: 'csv', filename: 'orders.csv', manifest: manifest)
    _, _, q, _, req = sent
    assert_equal({ 'format' => 'csv' }, q)
    assert_match(%r{\Amultipart/form-data; boundary=}, req['content-type'])
    assert_includes req.body, 'name="file"; filename="orders.csv"'
    assert_includes req.body, 'name="manifest"'
    assert_includes req.body, '"residencyClass":"shared"'
  end

  def test_upload_validation
    c = client
    assert_raises(K9o::KError) { c.analytics.upload('o', 'x', format: 'xml') }
    assert_raises(K9o::KError) { c.analytics.upload('o', 'x' * (25 * 1024 * 1024 + 1), format: 'csv') }
    assert_raises(K9o::KError) { c.analytics.upload('o', 12, format: 'csv') }
    assert_empty @http.reqs
  end

  def test_upload_throttled_carries_retry_after
    c = client(err(429, 'K9O_RATE_LIMITED', 'slow down', {}, 'retry-after' => '12'))
    e = assert_raises(K9o::KError) { c.analytics.upload('o', 'a', format: 'csv') }
    assert_equal 12, e.retry_after_sec
  end

  def test_download_original_returns_bytes_and_type
    bytes = "id,qty\n\xC3\xA9,1\n".b
    c = client([200, bytes, { 'content-type' => 'text/csv' }])
    dl = c.analytics.download_original('orders')
    assert_sent('GET', '/@portal/analytics/orders/upload/original')
    assert_kind_of K9o::Download, dl
    assert_equal bytes, dl.body
    assert_equal Encoding::BINARY, dl.body.encoding
    assert_equal 'text/csv', dl.content_type
  end

  def test_download_original_not_found_is_an_error_envelope
    e = assert_raises(K9o::KError) { client(err(404, 'K9O_NOT_FOUND')).analytics.download_original('orders') }
    assert_equal 404, e.status
  end

  # rollups and schedules ------------------------------------------------------------------------------------------

  def test_rollup_create_non_personal
    c = client
    c.analytics.rollups.create('orders', slug: 'daily', source: 'orders_stream', window_seconds: 3600,
                                         measures: [{ name: 'n', agg: 'count' }, { name: 'total', agg: 'sum', column: 'qty' }],
                                         dimensions: ['city'], non_personal: true, reattest_interval_days: 30)
    assert_sent('POST', '/@portal/analytics/orders/rollups',
                body: { 'slug' => 'daily', 'source' => 'orders_stream', 'windowSeconds' => 3600,
                        'measures' => [{ 'name' => 'n', 'agg' => 'count' }, { 'name' => 'total', 'agg' => 'sum', 'column' => 'qty' }],
                        'dimensions' => ['city'], 'nonPersonal' => true, 'reattestIntervalDays' => 30 })
  end

  def test_rollup_create_subject_field_and_validation
    c = client
    c.analytics.rollups.create('orders', slug: 'daily', source: 's', window_seconds: 60, measures: [{ name: 'n', agg: 'count' }],
                                         subject_field: 'user_id')
    assert_sent('POST', '/@portal/analytics/orders/rollups',
                body: { 'slug' => 'daily', 'source' => 's', 'windowSeconds' => 60, 'measures' => [{ 'name' => 'n', 'agg' => 'count' }],
                        'subjectField' => 'user_id' })
    base = { slug: 'daily', source: 's', window_seconds: 60, measures: [{ name: 'n', agg: 'count' }] }
    assert_raises(K9o::KError) { c.analytics.rollups.create('orders', **base) }
    assert_raises(K9o::KError) { c.analytics.rollups.create('orders', **base, subject_field: 'u', non_personal: true) }
    assert_raises(K9o::KError) { c.analytics.rollups.create('orders', **base.merge(window_seconds: 59), non_personal: true) }
    assert_raises(K9o::KError) { c.analytics.rollups.create('orders', **base, non_personal: true, reattest_interval_days: 10) }
  end

  def test_rollup_create_conflict
    e = assert_raises(K9o::KError) do
      client(err(409, 'K9O_ALREADY_EXISTS')).analytics.rollups.create('o', slug: 'd', source: 's', window_seconds: 60,
                                                                           measures: [{ name: 'n', agg: 'count' }], non_personal: true)
    end
    assert_equal 'K9O_ALREADY_EXISTS', e.code
  end

  def test_rollup_list_delete_reattest
    c = client([200, env([{ 'id' => 'roll_1', 'attestationStatus' => 'expiring_soon' }])])
    assert_equal 'expiring_soon', c.analytics.rollups.list('orders').data.first['attestationStatus']
    assert_sent('GET', '/@portal/analytics/orders/rollups')
    c.analytics.rollups.delete('orders', 'roll_1')
    assert_sent('DELETE', '/@portal/analytics/orders/rollups/roll_1')
    c.analytics.rollups.reattest('orders', 'roll_1', reattest_interval_days: 365)
    assert_sent('POST', '/@portal/analytics/orders/rollups/roll_1/reattest', body: { 'reattestIntervalDays' => 365 })
    c.analytics.rollups.reattest('orders', 'roll_1')
    assert_sent('POST', '/@portal/analytics/orders/rollups/roll_1/reattest', body: {})
  end

  def test_reattest_is_refused_for_non_person_tokens_and_not_special_cased
    e = assert_raises(K9o::KError) do
      client(err(403, 'K9O_RBAC_DENY', 'denied', { 'reason' => 'human_only' })).analytics.rollups.reattest('orders', 'roll_1')
    end
    assert_equal ['K9O_RBAC_DENY', 403, 'human_only'], [e.code, e.status, e.context['reason']]
    e = assert_raises(K9o::KError) do
      client(err(403, 'K9O_RBAC_DENY', 'denied', { 'reason' => 'human_only' })).analytics.schedules.reattest('orders', 's_1')
    end
    assert_equal 'human_only', e.context['reason']
  end

  def test_schedules_routes
    c = client([200, env({ 'id' => 's_1' })])
    c.analytics.schedules.create('orders', from_collection: 'orders_raw', interval_seconds: 3600, reattest_interval_days: 7)
    assert_sent('POST', '/@portal/analytics/orders/schedules',
                body: { 'fromCollection' => 'orders_raw', 'intervalSeconds' => 3600, 'reattestIntervalDays' => 7 })
    c.analytics.schedules.list('orders')
    assert_sent('GET', '/@portal/analytics/orders/schedules')
    c.analytics.schedules.reattest('orders', 's_1', reattest_interval_days: 90)
    assert_sent('POST', '/@portal/analytics/orders/schedules/s_1/reattest', body: { 'reattestIntervalDays' => 90 })
    c.analytics.schedules.delete('orders', 's_1')
    assert_sent('DELETE', '/@portal/analytics/orders/schedules/s_1')
    assert_raises(K9o::KError) { c.analytics.schedules.create('orders', from_collection: 'x', interval_seconds: 59) }
    e = assert_raises(K9o::KError) do
      client(err(409, 'K9O_PENDING_CHANGE_ALREADY_EXISTS')).analytics.schedules.create('orders', from_collection: 'x', interval_seconds: 60)
    end
    assert_equal 409, e.status
  end

  def test_dataset_slug_is_escaped_in_the_path
    c = client
    c.analytics.get('a/b')
    assert_equal '/@portal/analytics/a%2Fb', sent[1]
  end

  def test_project_slug_is_required
    c = K9o.create_client(base_url: 'https://acme.api-de01.k9o.io', api_key: 'k', http_client: Stub.new([200, env({})]))
    assert_equal 'K9O_MISSING_PROJECT_CONTEXT', assert_raises(K9o::KError) { c.analytics.list }.code
    assert_equal 'K9O_MISSING_PROJECT_CONTEXT', assert_raises(K9o::KError) { c.rollups.list }.code
  end

  # top-level rollups ----------------------------------------------------------------------------------------------

  def test_rollups_list_and_read
    c = client([200, env([{ 'slug' => 'daily', 'read' => '/@portal/rollups/daily/read' }])])
    assert_equal 'daily', c.rollups.list.data.first['slug']
    assert_sent('GET', '/@portal/rollups')
    c.rollups.read('daily', from: '2026-10-01T00:00:00Z', to: Time.utc(2026, 10, 2), dims: %w[city store])
    assert_sent('GET', '/@portal/rollups/daily/read',
                query: { 'from' => '2026-10-01T00:00:00Z', 'to' => '2026-10-02T00:00:00Z', 'dims' => 'city,store' })
    c.rollups.read('daily')
    assert_sent('GET', '/@portal/rollups/daily/read')
  end

  def test_rollups_read_error_paths
    { 400 => 'K9O_INVALID_FIELD_VALUE', 404 => 'K9O_NOT_FOUND', 409 => 'K9O_STATE_CONFLICT', 500 => 'K9O_QUERY_EXECUTION_FAILED',
      503 => 'K9O_ANALYTICS_UNAVAILABLE' }.each do |status, code|
      c = client(err(status, code))
      c.config.instance_variable_set(:@retry_config, K9o::RetryConfig.new(max_retries: 0))
      e = assert_raises(K9o::KError) { c.rollups.read('daily') }
      assert_equal [code, status], [e.code, e.status]
    end
  end

  # rollups.subscribe: cell events, Last-Event-ID resume, fromSequence, resync, errors ------------------------------

  # A cell frame as the gateway sends it: the cell is the payload, the SSE id is the resume cursor.
  def cell(id, n = 1, cursor: nil)
    data = { 'topic' => 'rollups.daily', 'eventType' => 'cell',
             'payload' => { 'cellKey' => "c#{n}", 'bucket' => '2026-10-27T10:00:00Z', 'dims' => { 'city' => 'Berlin' },
                            'final' => true, 'measures' => { 'n' => n } },
             'occurredAt' => '2026-10-27T10:00:05Z', 'eventId' => id }
    "id: #{cursor || "9#{id}"}\nevent: cell\ndata: #{JSON.generate(data)}\n\n"
  end

  def suppressed_cell(id)
    data = { 'topic' => 'rollups.daily', 'eventType' => 'cell',
             'payload' => { 'cellKey' => 'c9', 'bucket' => '2026-10-27T10:00:00Z', 'status' => 'suppressed', 'reason' => 'cohort_below_k' },
             'occurredAt' => '2026-10-27T10:00:05Z', 'eventId' => id }
    "id: 9#{id}\nevent: cell\ndata: #{JSON.generate(data)}\n\n"
  end

  def sse(*chunks)
    [200, nil, {}, ["retry: 0\n:ok\n\n"] + chunks]
  end

  def with_instant_sleep
    saved = K9o::Realtime.sleeper
    K9o::Realtime.sleeper = ->(_s) {}
    yield
  ensure
    K9o::Realtime.sleeper = saved
  end

  def test_subscribe_yields_cells_resumes_and_dedupes
    with_instant_sleep do
      c = client(sse(cell('evt_1'), cell('evt_2')), sse(cell('evt_2'), cell('evt_3', 7)))
      cells = c.rollups.subscribe('daily', from_sequence: 40).first(3)
      assert_equal [1, 1, 7], cells.map { |e| e['measures']['n'] }
      assert_equal %w[evt_1 evt_2 evt_3], cells.map { |e| e['eventId'] }
      assert_equal [true, 'c1', { 'city' => 'Berlin' }, false], cells.first.values_at('final', 'cellKey', 'dims', 'suppressed')
      first, second = @http.reqs
      assert_equal '/@portal/rollups/daily/subscribe', URI.parse("https://x#{first.path}").path
      assert_equal({ 'fromSequence' => '40' }, URI.decode_www_form(URI.parse("https://x#{first.path}").query).to_h)
      assert_nil first['last-event-id']
      assert_equal '9evt_2', second['last-event-id'] # the SSE id, not the eventId
      assert_nil URI.parse("https://x#{second.path}").query # fromSequence applies to the first connection only
    end
  end

  def test_subscribe_suppressed_cell_is_a_typed_field
    with_instant_sleep do
      c = client(sse(suppressed_cell('evt_5'), cell('evt_6')))
      sup, ok = c.rollups.subscribe('daily').first(2)
      assert_equal [true, 'suppressed', 'cohort_below_k', 'evt_5'], sup.values_at('suppressed', 'status', 'reason', 'eventId')
      refute sup.key?('measures')
      assert_equal false, ok['suppressed']
    end
  end

  def test_subscribe_dedupes_a_resumed_window_on_event_id
    with_instant_sleep do
      c = client(sse(cell('evt_1'), cell('evt_2')), sse(cell('evt_1', 1, cursor: '9new'), cell('evt_2'), cell('evt_3')))
      assert_equal %w[evt_1 evt_2 evt_3], c.rollups.subscribe('daily').first(3).map { |e| e['eventId'] }
    end
  end

  def test_subscribe_resync_calls_handler_and_reconnects_fresh
    with_instant_sleep do
      resync = "event: resync\ndata: {\"reason\":\"cursor-unknown\",\"action\":\"reread-source\"}\n\n"
      c = client(sse(cell('evt_1'), resync), sse(cell('evt_9')))
      calls = []
      cells = c.rollups.subscribe('daily', on_resync: ->(i) { calls << i }).first(2)
      assert_equal 2, cells.size
      assert_equal [{ 'reason' => 'cursor-unknown', 'action' => 'reread-source' }], calls
      assert_nil @http.reqs[1]['last-event-id']
    end
  end

  def test_subscribe_error_paths_are_raised_once
    { 403 => 'K9O_ACCESS_DENIED', 404 => 'K9O_NOT_FOUND', 409 => 'K9O_STATE_CONFLICT', 429 => 'K9O_SUBSCRIPTION_LIMIT_EXCEEDED' }.each do |status, code|
      c = client(err(status, code))
      e = assert_raises(K9o::KError) { c.rollups.subscribe('daily').first(1) }
      assert_equal [code, status], [e.code, e.status]
      assert_equal 1, @http.reqs.size
    end
    assert_raises(K9o::KError) { client.rollups.subscribe('daily', from_sequence: -1) }
  end
end
