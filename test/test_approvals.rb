# frozen_string_literal: true

require 'minitest/autorun'
require 'json'
require_relative '../lib/k9o'

# client.approvals, client.approval_policies, client.schema.collections: wire shape and client-side validation.
class ApprovalsTest < Minitest::Test
  Resp = Struct.new(:code, :body)

  class Recorder
    attr_reader :reqs
    attr_accessor :use_ssl, :read_timeout, :body

    def initialize
      @reqs = []
      @body = '{"data":{},"meta":{}}'
    end

    def request(req)
      @reqs << req
      Resp.new('200', @body)
    end
  end

  CRITERIA = { 'eq' => ['change.table', 'orders'] }.freeze
  PREDICATE = { 'gt' => ['change.row.amount', 1000] }.freeze

  def setup
    @rec = Recorder.new
  end

  def client(project_slug: 'portal')
    K9o.create_client(base_url: 'https://acme.api-de01.k9o.io', api_key: 'k', project_slug: project_slug,
                      http_client: @rec)
  end

  # [method, path, query hash, body or nil]
  def last
    req = @rec.reqs.last
    u = URI.parse("https://x#{req.path}")
    json = req['content-type'] == 'application/json' && !req.body.to_s.empty?
    [req.method, u.path, URI.decode_www_form(u.query || '').to_h, json ? JSON.parse(req.body) : nil]
  end

  def assert_invalid(&blk)
    @rec = Recorder.new
    e = assert_raises(K9o::KError, &blk)
    assert_equal 'K9O_INVALID_FIELD_VALUE', e.code
    assert_empty @rec.reqs
  end

  def test_list_wire
    c = client
    c.approvals.list
    assert_equal ['GET', '/@portal/pending-approvals', {}, nil], last
    c.approvals.list(status: 'pending_approval', limit: 20)
    assert_equal ['GET', '/@portal/pending-approvals', { 'status' => 'pending_approval', 'limit' => '20' }, nil], last
    c.approvals.list(status: :rejected)
    assert_equal({ 'status' => 'rejected' }, last[2])
  end

  class Seq < Recorder
    def initialize(*bodies)
      super()
      @bodies = bodies
    end

    def request(req)
      @reqs << req
      b = @bodies.shift
      code, body = b.is_a?(Array) ? b : ['200', b]
      Resp.new(code, body)
    end
  end

  PAGE1 = '{"data":[{"id":"apr_7FjMvznAaVjl","status":"rejected","collection":"conformance_kv","operation":"insert",' \
          '"makerId":"usr_conformance0001","proposedPayload":{"id":"w2-probe-php-22b5761e","val":"php-probe"},' \
          '"targetRecordId":null,"approverId":"usr_conformance0001","decidedAt":"2026-10-26T18:25:20.573Z",' \
          '"decisionReason":"php sdk probe, not intended","createdAt":"2026-10-26T18:25:19.818Z","expiresAt":null}],' \
          '"meta":{"cursor":{"next":"eyJ2IjoxLCJwIjoi_In0"}}}'
  PAGE2 = '{"data":[{"id":"apr_2"}],"meta":{"cursor":{"next":null}}}'

  def test_list_pages_with_cursor
    @rec = Seq.new(PAGE1, PAGE2, PAGE2)
    c = client
    p1 = c.approvals.list(limit: 1)
    assert_equal ['GET', '/@portal/pending-approvals', { 'limit' => '1' }, nil], last
    assert_equal 'apr_7FjMvznAaVjl', p1.data[0]['id']
    cur = p1.meta.cursor.next
    assert_equal 'eyJ2IjoxLCJwIjoi_In0', cur
    p2 = c.approvals.list(limit: 1, cursor: cur)
    assert_equal ['GET', '/@portal/pending-approvals', { 'limit' => '1', 'cursor' => cur }, nil], last
    assert_equal 'apr_2', p2.data[0]['id']
    assert_nil p2.meta.cursor.next
    c.approvals.list(status: 'approved', limit: 5, cursor: 'abc')
    assert_equal({ 'status' => 'approved', 'limit' => '5', 'cursor' => 'abc' }, last[2])
  end

  def test_list_invalid_cursor_is_kerror
    body = '{"code":"K9O_INVALID_CURSOR","message":"Cursor is malformed; omit it to start from the newest pending change",' \
           '"context":{},"recommendation":null}'
    @rec = Seq.new(['400', body])
    e = assert_raises(K9o::KError) { client.approvals.list(cursor: 'abc!') }
    assert_equal 'K9O_INVALID_CURSOR', e.code
    assert_equal({ 'cursor' => 'abc!' }, last[2])
  end

  BULK_FAILED = '{"data":{"attestationId":"apr_Vf23zMoj7m0u","action":"approve","affectedCount":1,"affectedIds":["apr_A"],' \
                '"failed":[{"id":"apr_B","code":"K9O_STATE_CONFLICT","reason":"Pending change \'apr_B\' was decided concurrently"}],' \
                '"reason":null},"meta":{}}'
  BULK_EMPTY = '{"data":{"attestationId":"apr_Vf23zMoj7m0u","action":"reject","affectedCount":0,"affectedIds":[],' \
               '"failed":[],"reason":"probe: matches nothing"},"meta":{}}'
  BULK_NO_FAILED = '{"data":{"attestationId":"apr_x","action":"approve","affectedCount":0,"affectedIds":[],"reason":null},"meta":{}}'

  def test_bulk_failed_rows
    @rec = Seq.new(BULK_FAILED, BULK_EMPTY, BULK_NO_FAILED)
    c = client
    r = c.approvals.bulk(action: 'approve', criteria: CRITERIA)
    assert_equal ['POST', '/@portal/pending-approvals/bulk', {}, { 'action' => 'approve', 'criteria' => CRITERIA }], last
    assert_equal ['apr_A'], r.data['affectedIds']
    assert_equal [{ 'id' => 'apr_B', 'code' => 'K9O_STATE_CONFLICT',
                    'reason' => "Pending change 'apr_B' was decided concurrently" }], r.data['failed']
    r = c.approvals.bulk(action: 'reject', criteria: CRITERIA, reason: 'probe: matches nothing')
    assert_equal [], r.data['failed']
    assert_equal({ 'action' => 'reject', 'criteria' => CRITERIA, 'reason' => 'probe: matches nothing' }, last[3])
    r = c.approvals.bulk(action: 'approve', criteria: CRITERIA)
    assert_equal [], r.data['failed']
    assert_equal 0, r.data['affectedCount']
  end

  def test_get_wire_and_path_encoding
    c = client
    c.approvals.get('apr_1')
    assert_equal ['GET', '/@portal/pending-approvals/apr_1', {}, nil], last
    c.approvals.get('a/b c')
    assert_equal '/@portal/pending-approvals/a%2Fb%20c', @rec.reqs.last.path
  end

  def test_approve_wire
    c = client
    c.approvals.approve('apr_1')
    assert_equal ['POST', '/@portal/pending-approvals/apr_1/approve', {}, {}], last
    c.approvals.approve('apr_1', reason: 'ok')
    assert_equal ['POST', '/@portal/pending-approvals/apr_1/approve', {}, { 'reason' => 'ok' }], last
  end

  def test_reject_wire
    client.approvals.reject('apr_1', reason: 'duplicate')
    assert_equal ['POST', '/@portal/pending-approvals/apr_1/reject', {}, { 'reason' => 'duplicate' }], last
  end

  def test_bulk_wire
    c = client
    c.approvals.bulk(action: 'approve', criteria: CRITERIA)
    assert_equal ['POST', '/@portal/pending-approvals/bulk', {}, { 'action' => 'approve', 'criteria' => CRITERIA }], last
    c.approvals.bulk(action: :approve, criteria: CRITERIA, reason: 'fine')
    assert_equal({ 'action' => 'approve', 'criteria' => CRITERIA, 'reason' => 'fine' }, last[3])
    c.approvals.bulk(action: 'reject', criteria: CRITERIA, reason: 'stale')
    assert_equal({ 'action' => 'reject', 'criteria' => CRITERIA, 'reason' => 'stale' }, last[3])
  end

  def test_policies_wire
    c = client
    c.approval_policies.list
    assert_equal ['GET', '/@portal/approval-policies', {}, nil], last
    c.approval_policies.create(collection: 'orders', operation: 'update', action: 'queue', predicate: PREDICATE)
    assert_equal ['POST', '/@portal/approval-policies', {},
                  { 'collection' => 'orders', 'operation' => 'update', 'action' => 'queue', 'predicate' => PREDICATE }], last
    c.approval_policies.delete('apo_1')
    assert_equal ['DELETE', '/@portal/approval-policies/apo_1', {}, nil], last
  end

  def test_schema_collections_wire
    c = client
    c.schema.collections.list
    assert_equal ['GET', '/@portal/schema/collections', {}, nil], last
    c.schema.collections.list(limit: 2, cursor: 'dGFza3M')
    assert_equal ['GET', '/@portal/schema/collections', { 'limit' => '2', 'cursor' => 'dGFza3M' }, nil], last
  end

  def test_schema_page_exposes_cursor
    @rec.body = '{"data":[{"name":"orders","rowCount":1}],"meta":{"cursor":{"next":"b3JkZXJz","totalCount":null}}}'
    res = client.schema.collections.list(limit: 1)
    assert_equal 'orders', res.data[0]['name']
    assert_equal 'b3JkZXJz', res.meta.cursor.next
  end

  def test_approve_keeps_pending_status
    @rec.body = '{"data":{"id":"apr_1","status":"pending_approval"},"meta":{}}'
    assert_equal 'pending_approval', client.approvals.approve('apr_1').data['status']
  end

  def test_bad_limits
    [0, 201, -1, 1.5, '10', true].each do |limit|
      c = client
      assert_invalid { c.approvals.list(limit: limit) }
      assert_invalid { c.schema.collections.list(limit: limit) }
    end
    [1, 200].each { |limit| client.approvals.list(limit: limit) }
  end

  def test_bad_cursor
    c = client
    assert_invalid { c.schema.collections.list(cursor: 5) }
  end

  def test_reject_needs_reason
    c = client
    [nil, '', '   ', 5].each { |r| assert_invalid { c.approvals.reject('apr_1', reason: r) } }
  end

  def test_ids_must_be_non_empty_strings
    c = client
    ['', nil, 5].each do |bad|
      assert_invalid { c.approvals.get(bad) }
      assert_invalid { c.approvals.approve(bad) }
      assert_invalid { c.approvals.reject(bad, reason: 'x') }
      assert_invalid { c.approval_policies.delete(bad) }
    end
  end

  def test_bulk_validation
    c = client
    ['', 'delete', nil, 'APPROVE'].each do |a|
      assert_invalid { c.approvals.bulk(action: a, criteria: CRITERIA, reason: 'x') }
    end
    [nil, [], [CRITERIA], 'eq', 5].each { |cr| assert_invalid { c.approvals.bulk(action: 'approve', criteria: cr) } }
    [nil, '', '  '].each { |r| assert_invalid { c.approvals.bulk(action: 'reject', criteria: CRITERIA, reason: r) } }
  end

  def test_policy_validation
    c = client
    ['', '1orders', 'or-ders', 'a b', 'x' * 64, nil, 5].each do |col|
      assert_invalid { c.approval_policies.create(collection: col, operation: 'update', action: 'queue', predicate: PREDICATE) }
    end
    ['', 'upsert', nil, 'UPDATE'].each do |op|
      assert_invalid { c.approval_policies.create(collection: 'orders', operation: op, action: 'queue', predicate: PREDICATE) }
    end
    ['', 'approve', nil].each do |act|
      assert_invalid { c.approval_policies.create(collection: 'orders', operation: 'update', action: act, predicate: PREDICATE) }
    end
    [nil, [], [PREDICATE], 'gt', 5, true].each do |pred|
      assert_invalid { c.approval_policies.create(collection: 'orders', operation: 'update', action: 'queue', predicate: pred) }
    end
  end

  def test_policy_collection_bounds_accepted
    c = client
    %w[_orders Orders1].push('x' * 63).each do |col|
      c.approval_policies.create(collection: col, operation: 'insert', action: 'queue', predicate: PREDICATE)
      assert_equal col, last[3]['collection']
    end
  end

  COMMENT = '{"id":"acm_01j9x3","caseId":"apr_1","authorId":"usr_1","visibility":"everyone","body":"Check the total.",' \
            '"createdAt":"2026-11-13T10:00:00.000Z"}'
  META = '{"cost":{},"timing":{"gatewayMs":3,"totalMs":5},"context":{"requestId":"req_1","traceId":"t_1"}}'

  def test_comments_add_wire_and_parse
    created = ['201', "{\"data\":#{COMMENT},\"meta\":#{META}}"]
    @rec = Seq.new(created, created)
    r = client.approvals.comments.add('apr_1', body: 'Check the total.', visibility: 'everyone')
    assert_equal ['POST', '/@portal/pending-approvals/apr_1/comments', {},
                  { 'body' => 'Check the total.', 'visibility' => 'everyone' }], last
    assert_equal 'acm_01j9x3', r.data['id']
    assert_equal 'apr_1', r.data['caseId']
    assert_equal 'req_1', r.meta.context.request_id
    client.approvals.comments.add('a/b c', body: 'x' * 4000, visibility: :approvers_only)
    assert_equal '/@portal/pending-approvals/a%2Fb%20c/comments', @rec.reqs.last.path
    assert_equal 'approvers_only', last[3]['visibility']
    assert_equal 4000, last[3]['body'].length
  end

  def test_comments_add_validation
    c = client
    ['', nil, 5].each { |bad| assert_invalid { c.approvals.comments.add(bad, body: 'x', visibility: 'everyone') } }
    ['', nil, 5, 'x' * 4001].each { |bad| assert_invalid { c.approvals.comments.add('apr_1', body: bad, visibility: 'everyone') } }
    [nil, '', 'private', 'Everyone', 5].each { |bad| assert_invalid { c.approvals.comments.add('apr_1', body: 'x', visibility: bad) } }
    assert_raises(ArgumentError) { c.approvals.comments.add('apr_1', body: 'x') }
  end

  def test_comments_list_wire_and_paging
    page1 = "{\"data\":[#{COMMENT}],\"nextCursor\":\"cur_1\",\"meta\":#{META}}"
    page2 = "{\"data\":[],\"nextCursor\":null,\"meta\":#{META}}"
    @rec = Seq.new(page1, page2)
    c = client
    p1 = c.approvals.comments.list('apr_1', limit: 1)
    assert_equal ['GET', '/@portal/pending-approvals/apr_1/comments', { 'limit' => '1' }, nil], last
    assert_equal ['acm_01j9x3'], p1.data.map { |m| m['id'] }
    assert_equal 'Check the total.', p1.data[0]['body']
    assert_equal 'cur_1', p1.next_cursor
    p2 = c.approvals.comments.list('apr_1', cursor: p1.next_cursor)
    assert_equal({ 'cursor' => 'cur_1' }, last[2])
    assert_equal [], p2.data
    assert_nil p2.next_cursor
  end

  def test_comments_list_default_has_no_query
    @rec = Seq.new("{\"data\":[],\"nextCursor\":null,\"meta\":{}}")
    client.approvals.comments.list('apr_1')
    assert_equal ['GET', '/@portal/pending-approvals/apr_1/comments', {}, nil], last
  end

  def test_comments_list_validation
    c = client
    assert_invalid { c.approvals.comments.list('') }
    [0, 201, '5', 1.5].each { |bad| assert_invalid { c.approvals.comments.list('apr_1', limit: bad) } }
  end

  def test_comments_errors_map_to_kerror
    {
      ['403', 'K9O_APPROVAL_COMMENT_NOT_ELIGIBLE'] => nil, ['409', 'K9O_APPROVAL_COMMENT_CLOSED'] => nil,
      ['400', 'K9O_INVALID_FIELD_VALUE'] => nil, ['404', 'K9O_NOT_FOUND'] => nil, ['403', 'K9O_RBAC_DENY'] => nil
    }.each_key do |status, code|
      @rec = Seq.new([status, JSON.dump('code' => code, 'message' => 'm', 'context' => {}, 'recommendation' => nil)])
      e = assert_raises(K9o::KError) { client.approvals.comments.add('apr_1', body: 'x', visibility: 'everyone') }
      assert_equal code, e.code
      assert_equal status.to_i, e.status
    end
  end

  def test_comments_requires_project_slug
    e = assert_raises(K9o::KError) { client(project_slug: nil).approvals.comments.list('apr_1') }
    assert_equal 'K9O_MISSING_PROJECT_CONTEXT', e.code
  end

  def test_missing_keyword_is_argument_error
    assert_raises(ArgumentError) { client.approval_policies.create(collection: 'orders') }
    assert_raises(ArgumentError) { client.approvals.reject('apr_1') }
  end

  def test_requires_project_slug
    c = client(project_slug: nil)
    [-> { c.approvals.list }, -> { c.approval_policies.list }, -> { c.schema.collections.list }].each do |call|
      e = assert_raises(K9o::KError, &call)
      assert_equal 'K9O_MISSING_PROJECT_CONTEXT', e.code
    end
    assert_empty @rec.reqs
  end

  def test_every_public_method_is_covered
    assert_equal %i[approve bulk comments get list reject], K9o::Approvals.public_instance_methods(false).sort
    assert_equal %i[add list], K9o::ApprovalComments.public_instance_methods(false).sort
    assert_equal %i[create delete list], K9o::ApprovalPolicies.public_instance_methods(false).sort
    assert_equal %i[list], K9o::SchemaCollections.public_instance_methods(false).sort
  end
end
