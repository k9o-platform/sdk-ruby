# frozen_string_literal: true

require 'minitest/autorun'
require 'json'
require_relative '../lib/k9o'

# Write approval (require_approval), function triggers, schedules and end-user role grants:
# wire shape (method, path, query, body), answer unwrapping and client-side validation.
class WorkloadTest < Minitest::Test
  Resp = Struct.new(:code, :body)

  # Answers each request with the next canned [status, body]; the last one repeats.
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

  META = { 'cost' => {}, 'timing' => {}, 'context' => { 'requestId' => 'req_1', 'traceId' => 'req_1', 'projectId' => 'proj_1' } }.freeze

  QUEUED = {
    'data' => {
      'id' => 'apr_5oLshD2MVT27', 'status' => 'pending_approval', 'collection' => 'conformance_kv',
      'operation' => 'insert', 'makerId' => 'usr_conformance0001',
      'proposedPayload' => { 'id' => 'contract2-probe-0001', 'val' => 'contract2-probe' }, 'targetRecordId' => nil
    },
    'meta' => META.merge('approval' => { 'status' => 'pending_approval' })
  }.freeze

  ROW = { 'data' => { 'id' => 'contract2-probe-0001', 'val' => 'contract2-probe' }, 'meta' => META }.freeze

  def ok(data, extra = {})
    [200, JSON.dump('data' => data, 'meta' => META.merge(extra))]
  end

  def client(*answers)
    @rec = Scripted.new(*answers)
    K9o.create_client(base_url: 'https://acme.api-de01.k9o.io', api_key: 'k', project_slug: 'portal', http_client: @rec)
  end

  # [method, path, query hash, body or nil]
  def last
    req = @rec.reqs.last
    u = URI.parse("https://x#{req.path}")
    json = req['content-type'] == 'application/json' && !req.body.to_s.empty?
    [req.method, u.path, URI.decode_www_form(u.query || '').to_h, json ? JSON.parse(req.body) : nil]
  end

  def assert_invalid(&blk)
    before = @rec.reqs.size
    e = assert_raises(K9o::KError, &blk)
    assert_equal 'K9O_INVALID_FIELD_VALUE', e.code
    assert_equal before, @rec.reqs.size
  end

  # --- require_approval -------------------------------------------------------------------------------------------

  def test_insert_without_flag_sends_no_query
    c = client([201, JSON.dump(ROW)])
    r = c.from('conformance_kv').insert('id' => 'x')
    assert_equal ['POST', '/@portal/data/conformance_kv', {}, { 'id' => 'x' }], last
    refute K9o.queued_write?(r)
  end

  def test_insert_braced_hash_without_flag_sends_no_query
    c = client([201, JSON.dump(ROW)])
    c.from('conformance_kv').insert({ 'id' => 'x' })
    assert_equal ['POST', '/@portal/data/conformance_kv', {}, { 'id' => 'x' }], last
  end

  def test_insert_require_approval_queued_202
    c = client([202, JSON.dump(QUEUED)])
    r = c.from('conformance_kv').insert({ 'id' => 'w2-probe-ruby-1', 'val' => 'v' }, require_approval: true)
    assert_equal ['POST', '/@portal/data/conformance_kv', { 'requireApproval' => 'true' },
                  { 'id' => 'w2-probe-ruby-1', 'val' => 'v' }], last
    assert K9o.queued_write?(r)
    assert_equal 'apr_5oLshD2MVT27', r.data['id']
    assert_equal 'pending_approval', r.meta.approval['status']
    assert_nil r.data['targetRecordId']
  end

  def test_insert_require_approval_auto_approved_is_not_queued
    c = client([201, JSON.dump(ROW)])
    r = c.from('conformance_kv').insert({ 'id' => 'contract2-probe-0001' }, require_approval: true)
    assert_equal({ 'requireApproval' => 'true' }, last[2])
    refute K9o.queued_write?(r)
    assert_equal 'contract2-probe-0001', r.data['id']
    assert_nil r.meta.approval
  end

  def test_update_require_approval
    queued = QUEUED.merge('data' => QUEUED['data'].merge('operation' => 'update', 'targetRecordId' => 'rec_1'))
    c = client([202, JSON.dump(queued)])
    r = c.from('tasks').update('done' => true).eq('id', 'rec_1').require_approval.execute
    assert_equal ['PATCH', '/@portal/data/tasks/rec_1', { 'requireApproval' => 'true' }, { 'done' => true }], last
    assert K9o.queued_write?(r)
    assert_equal 'rec_1', r.data['targetRecordId']

    c.from('tasks').update('done' => true).eq('id', 'rec_1').execute
    assert_equal ['PATCH', '/@portal/data/tasks/rec_1', {}, { 'done' => true }], last
  end

  def test_delete_require_approval
    queued = QUEUED.merge('data' => QUEUED['data'].merge('operation' => 'delete', 'proposedPayload' => {},
                                                          'targetRecordId' => 'rec_1'))
    c = client([202, JSON.dump(queued)])
    r = c.from('tasks').delete.eq('id', 'rec_1').require_approval.execute
    assert_equal ['DELETE', '/@portal/data/tasks/rec_1', { 'requireApproval' => 'true' }, nil], last
    assert K9o.queued_write?(r)
    assert_equal({}, r.data['proposedPayload'])

    c.from('tasks').delete.eq('id', 'rec_1').execute
    assert_equal ['DELETE', '/@portal/data/tasks/rec_1', {}, nil], last
  end

  def test_queued_write_requires_both_markers
    c = client([200, JSON.dump('data' => { 'status' => 'pending_approval' }, 'meta' => META)])
    refute K9o.queued_write?(c.from('t').insert({}))
    c = client([200, JSON.dump('data' => { 'id' => 'r' }, 'meta' => META.merge('approval' => { 'status' => 'pending_approval' }))])
    refute K9o.queued_write?(c.from('t').insert({}))
    c = client([200, JSON.dump('data' => nil, 'meta' => META)])
    refute K9o.queued_write?(c.from('t').insert({}))
    refute K9o.queued_write?(nil)
    refute K9o.queued_write?('x')
  end

  # --- triggers ---------------------------------------------------------------------------------------------------

  TRIGGER = {
    'id' => '0b8f6a52-3f0e-4c8e-9a47-5d2b0f1c7e11', 'functionName' => 'w4c-probe', 'collection' => 'orders',
    'events' => %w[insert update], 'filter' => nil, 'enabled' => true, 'logOkInvocations' => false,
    'createdAt' => '2026-10-26T17:59:56.815Z'
  }.freeze

  def test_triggers_list_empty
    c = client(ok([]))
    r = c.functions.triggers.list('w4c-probe')
    assert_equal ['GET', '/@portal/functions/w4c-probe/triggers', {}, nil], last
    assert_equal [], r.data
  end

  def test_triggers_create_wire
    c = client([201, JSON.dump('data' => TRIGGER, 'meta' => META)])
    r = c.functions.triggers.create('w4c-probe', collection: 'orders', events: [:insert, 'update'],
                                                 filter: { 'eq' => ['resource.status', 'paid'] },
                                                 enabled: false, log_ok_invocations: true)
    assert_equal ['POST', '/@portal/functions/w4c-probe/triggers', {},
                  { 'collection' => 'orders', 'events' => %w[insert update],
                    'filter' => { 'eq' => ['resource.status', 'paid'] }, 'enabled' => false,
                    'logOkInvocations' => true }], last
    assert_equal TRIGGER['id'], r.data['id']

    c.functions.triggers.create('w4c-probe', collection: 'orders', events: %w[delete])
    assert_equal({ 'collection' => 'orders', 'events' => %w[delete] }, last[3])
  end

  def test_triggers_update_wire
    c = client(ok(TRIGGER))
    c.functions.triggers.update('w4c-probe', TRIGGER['id'], enabled: false)
    assert_equal ['PATCH', "/@portal/functions/w4c-probe/triggers/#{TRIGGER['id']}", {}, { 'enabled' => false }], last
    c.functions.triggers.update('w4c-probe', TRIGGER['id'], events: ['upsert'], log_ok_invocations: true)
    assert_equal({ 'events' => ['upsert'], 'logOkInvocations' => true }, last[3])
    c.functions.triggers.update('w4c-probe', TRIGGER['id'], filter: nil)
    assert_equal({ 'filter' => nil }, last[3])
    c.functions.triggers.update('w4c-probe', TRIGGER['id'], filter: { 'eq' => %w[a b] })
    assert_equal({ 'filter' => { 'eq' => %w[a b] } }, last[3])
  end

  def test_triggers_delete_204
    c = client([204, nil])
    r = c.functions.triggers.delete('w4c-probe', TRIGGER['id'])
    assert_equal ['DELETE', "/@portal/functions/w4c-probe/triggers/#{TRIGGER['id']}", {}, nil], last
    assert_nil r.data
  end

  def test_triggers_validation
    c = client(ok([]))
    t = c.functions.triggers
    assert_invalid { t.create('f', collection: 'orders', events: []) }
    assert_invalid { t.create('f', collection: 'orders', events: %w[insert update delete upsert insert]) }
    assert_invalid { t.create('f', collection: 'orders', events: ['truncate']) }
    assert_invalid { t.create('f', collection: 'orders', events: 'insert') }
    assert_invalid { t.create('f', collection: '1bad', events: ['insert']) }
    assert_invalid { t.create('f', collection: 'a' * 129, events: ['insert']) }
    assert_invalid { t.update('f', 'id1') }
    assert_invalid { t.update('f', 'id1', collection: 'x') }
    assert_invalid { t.update('f', 'id1', events: []) }
    assert_invalid { t.update('f', '', enabled: true) }
    assert_invalid { t.delete('', 'id1') }
    assert_invalid { t.list('') }
  end

  def test_triggers_need_project_slug
    c = K9o.create_client(base_url: 'https://acme.api-de01.k9o.io', api_key: 'k', http_client: Scripted.new(ok([])))
    e = assert_raises(K9o::KError) { c.functions.triggers.list('f') }
    assert_equal 'K9O_MISSING_PROJECT_CONTEXT', e.code
  end

  # --- schedules --------------------------------------------------------------------------------------------------

  SCHEDULE = {
    'id' => '5b1b1a52-0000-4c8e-9a47-5d2b0f1c7e11', 'functionName' => 'nightly-report',
    'scheduleExpression' => '0 0 * * *', 'scheduleTimezone' => 'UTC', 'catchupPolicy' => 'skip', 'collection' => nil,
    'enabled' => true, 'status' => 'active', 'logOkInvocations' => false, 'createdAt' => '2026-10-26T17:59:56.815Z',
    'lastInvocationAt' => nil, 'nextInvocationAt' => nil
  }.freeze
  SID = SCHEDULE['id']

  def test_schedules_list_empty_and_query
    c = client(ok([], 'cursor' => { 'next' => nil }))
    r = c.schedules.list
    assert_equal ['GET', '/@portal/forge/schedules', {}, nil], last
    assert_equal [], r.data
    assert_nil r.meta.cursor.next
    c.schedules.list(status: :paused, function_name: 'nightly-report', limit: 2, cursor: 'abc')
    assert_equal ['GET', '/@portal/forge/schedules',
                  { 'status' => 'paused', 'function_name' => 'nightly-report', 'limit' => '2', 'cursor' => 'abc' }, nil], last
  end

  def test_schedules_get
    c = client(ok(SCHEDULE))
    r = c.schedules.get(SID)
    assert_equal ['GET', "/@portal/forge/schedules/#{SID}", {}, nil], last
    assert_equal 'active', r.data['status']
  end

  def test_schedules_create_wire
    c = client([201, JSON.dump('data' => SCHEDULE, 'meta' => META)])
    c.schedules.create(function_name: 'nightly-report', schedule_expression: '@daily')
    assert_equal ['POST', '/@portal/forge/schedules', {},
                  { 'functionName' => 'nightly-report', 'scheduleExpression' => '@daily' }], last
    c.schedules.create(function_name: 'nightly-report', schedule_expression: '0 6 * * 1', schedule_timezone: 'Europe/Berlin',
                       catchup_policy: :run_once, collection: 'orders', enabled: false, log_ok_invocations: true)
    assert_equal({ 'functionName' => 'nightly-report', 'scheduleExpression' => '0 6 * * 1',
                   'scheduleTimezone' => 'Europe/Berlin', 'catchupPolicy' => 'run_once', 'collection' => 'orders',
                   'enabled' => false, 'logOkInvocations' => true }, last[3])
  end

  def test_schedules_update_wire
    c = client(ok(SCHEDULE))
    c.schedules.update(SID, status: :paused)
    assert_equal ['PATCH', "/@portal/forge/schedules/#{SID}", {}, { 'status' => 'paused' }], last
    c.schedules.update(SID, schedule_expression: '*/10 * * * *', schedule_timezone: 'UTC', catchup_policy: 'skip',
                            enabled: true, log_ok_invocations: false)
    assert_equal({ 'scheduleExpression' => '*/10 * * * *', 'scheduleTimezone' => 'UTC', 'catchupPolicy' => 'skip',
                   'enabled' => true, 'logOkInvocations' => false }, last[3])
  end

  def test_schedules_delete_204
    c = client([204, nil])
    r = c.schedules.delete(SID)
    assert_equal ['DELETE', "/@portal/forge/schedules/#{SID}", {}, nil], last
    assert_nil r.data
  end

  def test_schedules_runs
    run = { 'id' => 'r1', 'triggerId' => SID, 'functionName' => 'nightly-report', 'status' => 'ok' }
    c = client(ok([run], 'cursor' => { 'next' => 'n2' }))
    r = c.schedules.runs(SID)
    assert_equal ['GET', "/@portal/forge/schedules/#{SID}/runs", {}, nil], last
    assert_equal 'n2', r.meta.cursor.next
    c.schedules.runs(SID, limit: 5, cursor: 'n2')
    assert_equal({ 'limit' => '5', 'cursor' => 'n2' }, last[2])
  end

  def test_schedules_run_now_returns_raw_body
    c = client([202, JSON.dump('data' => { 'runId' => 'abc', 'x' => [1] }, 'meta' => META)])
    r = c.schedules.run_now(SID)
    assert_equal ['POST', "/@portal/forge/schedules/#{SID}/run-now", {}, nil], last
    assert_equal({ 'runId' => 'abc', 'x' => [1] }, r.data)
  end

  def test_schedules_validation
    c = client(ok([]))
    s = c.schedules
    assert_invalid { s.list(limit: 0) }
    assert_invalid { s.list(limit: 201) }
    assert_invalid { s.list(status: 'gone') }
    assert_invalid { s.get('') }
    assert_invalid { s.update(SID) }
    assert_invalid { s.update(SID, function_name: 'x') }
    assert_invalid { s.update(SID, status: 'stopped') }
    assert_invalid { s.create(function_name: 'f', schedule_expression: '@daily', catchup_policy: 'all') }
    assert_invalid { s.runs(SID, limit: 0) }
    assert_invalid { s.run_now('') }
    assert_invalid { s.delete('') }
  end

  # --- end users --------------------------------------------------------------------------------------------------

  EU = { 'id' => 'eu_YmGE3Z6nkv5i', 'email' => 'user@example.com', 'emailVerifiedAt' => nil, 'status' => 'active',
         'createdAt' => '2026-10-09T12:15:13.430Z', 'lastSigninAt' => nil, 'signInMethods' => ['password'],
         'region' => nil }.freeze
  GRANT = { 'id' => 'eurg_AbCdEf123456', 'endUserId' => EU['id'], 'role' => 'billing-manager',
            'grantedAt' => '2026-10-26T17:59:56.815Z', 'grantedBy' => 'usr_conformance0001' }.freeze

  def test_end_users_list_and_get
    c = client(ok([EU], 'cursor' => { 'next' => 'c2' }))
    r = c.end_users.list
    assert_equal ['GET', '/@portal/end-users', {}, nil], last
    assert_equal 'c2', r.meta.cursor.next
    c.end_users.list(status: :locked, q: 'ann', limit: 10, cursor: 'c1')
    assert_equal ['GET', '/@portal/end-users', { 'status' => 'locked', 'q' => 'ann', 'limit' => '10', 'cursor' => 'c1' }, nil],
                 last
    c = client(ok(EU))
    assert_equal EU['id'], c.end_users.get(EU['id']).data['id']
    assert_equal ['GET', "/@portal/end-users/#{EU['id']}", {}, nil], last
  end

  def test_end_users_validation
    c = client(ok([]))
    assert_invalid { c.end_users.list(status: 'bogus') }
    assert_invalid { c.end_users.list(limit: 500) }
    assert_invalid { c.end_users.get('') }
  end

  def test_role_grants_list_unwraps_grants
    c = client(ok('grants' => []))
    r = c.end_users.role_grants.list
    assert_equal ['GET', '/@portal/end-user-role-grants', {}, nil], last
    assert_equal [], r.data
    c = client(ok('grants' => [GRANT]))
    r = c.end_users.role_grants.list(end_user_id: EU['id'])
    assert_equal ['GET', '/@portal/end-user-role-grants', { 'endUserId' => EU['id'] }, nil], last
    assert_equal [GRANT], r.data
  end

  def test_role_grants_grant_unwraps_grant
    c = client(ok('grant' => GRANT))
    r = c.end_users.role_grants.grant(end_user_id: EU['id'], role: 'billing-manager')
    assert_equal ['POST', '/@portal/end-user-role-grants', {},
                  { 'endUserId' => EU['id'], 'role' => 'billing-manager' }], last
    assert_equal GRANT, r.data
    assert_invalid { c.end_users.role_grants.grant(end_user_id: '', role: 'r') }
    assert_invalid { c.end_users.role_grants.grant(end_user_id: 'eu_1', role: '') }
    assert_invalid { c.end_users.role_grants.grant(end_user_id: 'eu_1', role: 'r' * 129) }
    assert_invalid { c.end_users.role_grants.grant(end_user_id: 'e' * 65, role: 'r') }
  end

  def test_role_grants_revoke_true_and_false
    c = client(ok('revoked' => true, 'revokedAt' => '2026-10-26T18:00:00.000Z'))
    r = c.end_users.role_grants.revoke(GRANT['id'])
    assert_equal ['DELETE', "/@portal/end-user-role-grants/#{GRANT['id']}", {}, nil], last
    assert_equal true, r.data['revoked']
    assert_equal '2026-10-26T18:00:00.000Z', r.data['revokedAt']

    c = client(ok('revoked' => false, 'revokedAt' => nil))
    r = c.end_users.role_grants.revoke('eurg_unknown')
    assert_equal false, r.data['revoked']
    assert_nil r.data['revokedAt']
    assert_invalid { c.end_users.role_grants.revoke('') }
  end

  # --- custody ----------------------------------------------------------------------------------------------------

  def test_custody_status_platform_managed
    c = client(ok('mode' => 'PLATFORM_MANAGED', 'attached' => false, 'provider' => nil, 'lastJob' => nil))
    r = c.custody.status
    assert_equal ['GET', '/@portal/custody/status', {}, nil], last
    assert_equal 'PLATFORM_MANAGED', r.data['mode']
    assert_equal false, r.data['attached']
    assert_nil r.data['provider']
    assert_nil r.data['lastJob']
    assert r.data.key?('hsm')
    assert_nil r.data['hsm']
  end

  def test_custody_status_hsm
    hsm = { 'vendor' => 'aws-cloudhsm', 'clusterId' => 'cluster-1234567890abcdef', 'region' => 'de01',
            'attestation' => { 'status' => nil, 'verifiedAt' => nil }, 'keys' => nil }
    c = client(ok('mode' => 'HYOK', 'attached' => true, 'provider' => 'hsm', 'lastJob' => nil, 'hsm' => hsm))
    r = c.custody.status
    assert_equal 'hsm', r.data['provider']
    assert_equal hsm, r.data['hsm']
  end

  def test_custody_status_errors_and_missing_project
    c = client([403, JSON.dump('code' => 'K9O_ACCESS_DENIED', 'message' => 'no', 'context' => {})])
    assert_raises(K9o::KError) { c.custody.status }
    c = K9o.create_client(base_url: 'https://acme.api-de01.k9o.io', api_key: 'k', http_client: Scripted.new(ok({})))
    e = assert_raises(K9o::KError) { c.custody.status }
    assert_equal 'K9O_MISSING_PROJECT_CONTEXT', e.code
  end
end
