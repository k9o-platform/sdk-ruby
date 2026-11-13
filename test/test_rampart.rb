# frozen_string_literal: true

require 'minitest/autorun'
require 'json'
require 'digest'
require_relative '../lib/k9o'

# Rampart: classify and jwks wire shape, and verify_receipt against receipts signed here with a fresh key.
class RampartTest < Minitest::Test
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

  BASE = 'https://acme.api-staging-de01.k9o.io'
  ISSUER = 'https://api-staging.k9o.io/rampart'
  PROJECT_ID = 'proj_abc'
  NOW = 1_800_000_000
  META = { 'cost' => {}, 'timing' => {}, 'context' => { 'requestId' => 'req_1', 'traceId' => 'req_1', 'projectId' => PROJECT_ID } }.freeze
  INPUT = { 'text' => 'hello', 'n' => 1 }.freeze

  Pure = K9o::Ed25519::Pure

  def b64(bytes)
    [bytes].pack('m0').tr('+/', '-_').delete('=')
  end

  def new_key(seed_byte, kid)
    seed = [seed_byte].pack('C') * 32
    { seed: seed, kid: kid, jwk: { 'kty' => 'OKP', 'crv' => 'Ed25519', 'x' => b64(Pure.public_key(seed)), 'kid' => kid, 'alg' => 'EdDSA', 'use' => 'sig' } }
  end

  def claims(overrides = {})
    {
      'iss' => ISSUER, 'iat' => NOW - 10, 'exp' => NOW + 3590,
      'input_sha256' => Digest::SHA256.hexdigest(K9o::Jcs.canonicalize(INPUT)),
      'classification' => 'suspicious', 'risk_bp' => 6200, 'confidence_bp' => 8100,
      'categories' => %w[prompt_injection], 'project_id' => PROJECT_ID, 'calibration_version' => 'cal-1'
    }.merge(overrides)
  end

  def sign(key, payload = claims, header = {})
    head = { 'alg' => 'EdDSA', 'kid' => key[:kid], 'typ' => K9o::Rampart::RECEIPT_TYP }.merge(header)
    signing_input = "#{b64(JSON.dump(head))}.#{b64(JSON.dump(payload))}"
    "#{signing_input}.#{b64(Pure.sign(key[:seed], signing_input))}"
  end

  def client(*answers)
    @rec = Scripted.new(*answers)
    K9o.create_client(base_url: BASE, api_key: 'k', project_slug: 'portal', http_client: @rec)
  end

  def ok(data)
    [200, JSON.dump('data' => data, 'meta' => META)]
  end

  def feed(*keys)
    feed_with(ISSUER, *keys)
  end

  def feed_with(issuer, *keys)
    body = { 'keys' => keys.map { |k| k[:jwk] }, 'meta' => META }
    body['issuer'] = issuer unless issuer.nil?
    [200, JSON.dump(body)]
  end

  def last
    req = @rec.reqs.last
    [req.method, URI.parse("https://x#{req.path}").path, req.body && JSON.parse(req.body)]
  end

  def verify(receipt, key, input: INPUT, **opts)
    opts = { project_id: PROJECT_ID, issuer: ISSUER }.merge(opts)
    @client.rampart.verify_receipt(receipt, input, key_set: { 'keys' => [key[:jwk]] }, clock: -> { NOW }, **opts)
  end

  def setup
    @key = new_key(7, 'rampart-classify-1')
    @client = client(ok({}))
  end

  def assert_refused(reason, &blk)
    e = assert_raises(K9o::Rampart::ReceiptRefusal, &blk)
    assert_equal reason, e.reason
    assert_includes K9o::Rampart::REASONS, e.reason
    assert_kind_of K9o::KError, e
    e
  end

  # classify and jwks

  def test_classify_wire_and_decoding
    receipt = sign(@key)
    c = client(ok('classification' => 'suspicious', 'riskScore' => 6200, 'confidence' => 8100,
                  'categories' => %w[prompt_injection], 'calibrationVersion' => 'cal-1', 'classificationReceipt' => receipt, 'projectId' => PROJECT_ID))
    r = c.rampart.classify({ 'text' => 'hello' }, label: 'ticket')
    assert_equal ['POST', '/@portal/rampart/classify', { 'input' => { 'text' => 'hello' }, 'label' => 'ticket' }], last
    assert_equal 'suspicious', r.data['classification']
    assert_equal 6200, r.data['riskScore']
    assert_equal 8100, r.data['confidence']
    assert_equal %w[prompt_injection], r.data['categories']
    assert_equal 'cal-1', r.data['calibrationVersion']
    assert_equal receipt, r.data['classificationReceipt']
    assert_equal PROJECT_ID, r.data['projectId']
  end

  def test_classify_without_label_omits_it
    c = client(ok('classification' => 'clear'))
    c.rampart.classify({ 'text' => 'hi' })
    assert_equal({ 'input' => { 'text' => 'hi' } }, last[2])
  end

  def test_classify_503_is_an_error_never_a_verdict
    body = JSON.dump('code' => 'K9O_RAMPART_CLASSIFIER_UNAVAILABLE', 'message' => 'Rampart classifier unavailable', 'context' => {}, 'recommendation' => nil)
    c = client([503, body])
    e = assert_raises(K9o::KError) { c.rampart.classify({ 'text' => 'x' }) }
    assert_equal 'K9O_RAMPART_CLASSIFIER_UNAVAILABLE', e.code
    assert_equal 503, e.status
    assert_equal 1, @rec.reqs.size
  end

  def test_classify_checks_arguments_before_sending
    c = client(ok({}))
    assert_raises(K9o::KError) { c.rampart.classify('text') }
    assert_raises(K9o::KError) { c.rampart.classify({}, label: '') }
    assert_raises(K9o::KError) { c.rampart.classify({}, label: 'x' * 129) }
    assert_empty @rec.reqs
  end

  def test_classify_input_must_be_an_object_and_nothing_is_sent_otherwise
    c = client(ok({}))
    ['text to classify', ['a'], 42, 1.5, true, nil, :sym].each do |bad|
      e = assert_raises(K9o::KError) { c.rampart.classify(bad) }
      assert_equal 'K9O_INVALID_FIELD_VALUE', e.code
    end
    assert_empty @rec.reqs
  end

  def test_classify_needs_a_project
    c = K9o.create_client(base_url: BASE, api_key: 'k', http_client: Scripted.new(ok({})))
    e = assert_raises(K9o::KError) { c.rampart.classify({ 'a' => 1 }) }
    assert_equal 'K9O_MISSING_PROJECT_CONTEXT', e.code
  end

  def test_jwks_wire_and_no_credential
    c = client(feed(@key))
    r = c.rampart.jwks
    req = @rec.reqs.last
    assert_equal 'GET', req.method
    assert_equal '/rampart/jwks', URI.parse("https://x#{req.path}").path
    assert_nil req['authorization']
    assert_equal 'rampart-classify-1', r.data['keys'].first['kid']
    assert_equal ISSUER, r.data['issuer']
    assert_equal 'OKP', r.data['keys'].first['kty']
    assert_equal 'Ed25519', r.data['keys'].first['crv']
  end

  # verify_receipt

  def test_happy_path
    v = verify(sign(@key), @key)
    assert_equal 'suspicious', v.classification
    assert_equal 6200, v.risk_bp
    assert_equal 8100, v.confidence_bp
    assert_equal %w[prompt_injection], v.categories
    assert_equal PROJECT_ID, v.project_id
    assert_equal 'cal-1', v.calibration_version
    assert_equal 'rampart-classify-1', v.kid
    assert_equal NOW + 3590, v.expires_at.to_i
  end

  def test_input_with_symbol_keys_hashes_the_same
    v = @client.rampart.verify_receipt(sign(@key), { n: 1, text: 'hello' }, key_set: [@key[:jwk]], project_id: PROJECT_ID, issuer: ISSUER, clock: NOW)
    assert_equal 'suspicious', v.classification
  end

  def test_clock_may_be_a_time
    v = @client.rampart.verify_receipt(sign(@key), INPUT, key_set: [@key[:jwk]], project_id: PROJECT_ID, issuer: ISSUER, clock: Time.at(NOW))
    assert_equal 'suspicious', v.classification
  end

  def test_wrong_kid
    assert_refused(:key_unknown) { verify(sign(@key, claims, 'kid' => 'other'), @key) }
  end

  def test_key_that_is_not_ed25519
    bad = @key[:jwk].merge('crv' => 'P-256')
    assert_refused(:key_unknown) do
      @client.rampart.verify_receipt(sign(@key), INPUT, key_set: [bad], project_id: PROJECT_ID, issuer: ISSUER, clock: NOW)
    end
  end

  def test_wrong_alg
    assert_refused(:alg) { verify(sign(@key, claims, 'alg' => 'HS256'), @key) }
    assert_refused(:alg) { verify(sign(@key, claims, 'alg' => 'none'), @key) }
  end

  def test_wrong_typ
    assert_refused(:typ) { verify(sign(@key, claims, 'typ' => 'JWT'), @key) }
  end

  def test_wrong_issuer
    assert_refused(:issuer) { verify(sign(@key, claims('iss' => 'https://evil.example/rampart')), @key) }
  end

  def test_issuer_option_overrides_the_feed
    r = sign(@key, claims('iss' => 'https://api.corp.internal/rampart'))
    c = client(feed(@key))
    assert_refused(:issuer) { c.rampart.verify_receipt(r, INPUT, project_id: PROJECT_ID, clock: NOW) }
    v = c.rampart.verify_receipt(r, INPUT, issuer: 'https://api.corp.internal/rampart', project_id: PROJECT_ID, clock: NOW)
    assert_equal 'suspicious', v.classification
  end

  def test_issuer_comes_from_the_feed
    c = client(feed(@key))
    v = c.rampart.verify_receipt(sign(@key), INPUT, project_id: PROJECT_ID, clock: NOW)
    assert_equal 'suspicious', v.classification
    c = client(feed_with('https://other.example/rampart', @key))
    assert_refused(:issuer) { c.rampart.verify_receipt(sign(@key), INPUT, project_id: PROJECT_ID, clock: NOW) }
  end

  def test_issuer_comes_from_a_key_set_hash_that_carries_one
    v = @client.rampart.verify_receipt(sign(@key), INPUT, key_set: { 'keys' => [@key[:jwk]], 'issuer' => ISSUER },
                                                          project_id: PROJECT_ID, clock: NOW)
    assert_equal 'suspicious', v.classification
  end

  def test_no_issuer_advertised_and_none_given_is_refused
    c = client(feed_with(nil, @key))
    e = assert_refused(:issuer) { c.rampart.verify_receipt(sign(@key), INPUT, project_id: PROJECT_ID, clock: NOW) }
    assert_match(/no issuer is advertised/, e.message)
    e = assert_refused(:issuer) do
      @client.rampart.verify_receipt(sign(@key), INPUT, key_set: [@key[:jwk]], project_id: PROJECT_ID, clock: NOW)
    end
    assert_match(/no issuer is advertised/, e.message)
  end

  def test_the_issuer_is_never_derived_from_the_base_url
    refute_respond_to @client.rampart, :expected_issuer_for
    r = sign(@key, claims('iss' => 'https://api-staging.k9o.io/rampart'))
    assert_refused(:issuer) do
      @client.rampart.verify_receipt(r, INPUT, key_set: [@key[:jwk]], project_id: PROJECT_ID, clock: NOW)
    end
  end

  def test_wrong_project
    assert_refused(:project) { verify(sign(@key, claims('project_id' => 'proj_other')), @key) }
  end

  def test_expired_and_skew
    r = sign(@key, claims('exp' => NOW - 30))
    assert_equal 'suspicious', verify(r, @key).classification # inside the 60 s skew
    assert_refused(:expired) { verify(sign(@key, claims('exp' => NOW - 61)), @key) }
    assert_refused(:expired) { verify(r, @key, clock_skew: 10) }
  end

  def test_not_yet_valid
    assert_refused(:not_yet_valid) { verify(sign(@key, claims('iat' => NOW + 61, 'exp' => NOW + 3600)), @key) }
    assert_equal 'suspicious', verify(sign(@key, claims('iat' => NOW + 59, 'exp' => NOW + 3600)), @key).classification
  end

  def test_input_hash_mismatch
    assert_refused(:input_hash) do
      @client.rampart.verify_receipt(sign(@key), { 'text' => 'other', 'n' => 1 }, key_set: [@key[:jwk]], project_id: PROJECT_ID, issuer: ISSUER, clock: NOW)
    end
    assert_refused(:input_hash) do
      @client.rampart.verify_receipt(sign(@key), 'not a hash', key_set: [@key[:jwk]], project_id: PROJECT_ID, issuer: ISSUER, clock: NOW)
    end
  end

  def test_tampered_signature
    receipt = sign(@key)
    head, body, sig = receipt.split('.')
    bytes = sig.unpack('a*').first
    forged = "#{head}.#{body}.#{bytes[0, 4]}#{bytes[4] == 'A' ? 'B' : 'A'}#{bytes[5..]}"
    assert_refused(:signature) { verify(forged, @key) }
  end

  def test_tampered_claims
    head, _body, sig = sign(@key).split('.')
    forged_body = b64(JSON.dump(claims('classification' => 'clear', 'risk_bp' => 0)))
    assert_refused(:signature) { verify("#{head}.#{forged_body}.#{sig}", @key) }
  end

  def test_signed_by_another_key_under_the_same_kid
    impostor = new_key(9, 'rampart-classify-1')
    assert_refused(:signature) { verify(sign(impostor), @key) }
  end

  def test_malformed_receipts
    [nil, 42, '', 'a.b', 'a.b.c.d', '..', '!!!.@@@.###'].each do |bad|
      assert_refused(:malformed) { verify(bad, @key) }
    end
    head = b64(JSON.dump('alg' => 'EdDSA', 'typ' => K9o::Rampart::RECEIPT_TYP))
    assert_refused(:malformed) { verify("#{head}.#{b64('{}')}.#{b64('x' * 64)}", @key) } # no kid
    assert_refused(:malformed) { verify("#{b64('[]')}.#{b64('{}')}.#{b64('x')}", @key) }
    assert_refused(:malformed) { verify("#{b64('not json')}.#{b64('{}')}.#{b64('x')}", @key) }
  end

  def test_signed_claims_that_are_not_a_verdict
    assert_refused(:malformed) { verify(sign(@key, claims('classification' => 'fine')), @key) }
    assert_refused(:malformed) { verify(sign(@key, claims('risk_bp' => 10_001)), @key) }
    assert_refused(:malformed) { verify(sign(@key, claims('categories' => 'x')), @key) }
    assert_refused(:malformed) { verify(sign(@key, claims('exp' => 'soon')), @key) }
  end

  def test_the_verdict_comes_from_signed_claims_not_the_response_body
    receipt = sign(@key)
    c = client(ok('classification' => 'clear', 'riskScore' => 0, 'confidence' => 10_000, 'categories' => [],
                  'calibrationVersion' => 'cal-1', 'classificationReceipt' => receipt, 'projectId' => PROJECT_ID))
    result = c.rampart.classify(INPUT)
    v = c.rampart.verify_receipt(result, INPUT, key_set: [@key[:jwk]], issuer: ISSUER, clock: NOW)
    assert_equal 'suspicious', v.classification # the signed value, not the unsigned 'clear'
  end

  # key feed

  def test_keys_are_fetched_when_none_is_given_and_cached
    c = client(feed(@key))
    2.times do
      v = c.rampart.verify_receipt(sign(@key), INPUT, project_id: PROJECT_ID, issuer: ISSUER, clock: NOW)
      assert_equal 'suspicious', v.classification
    end
    assert_equal 1, @rec.reqs.size
    assert_equal '/rampart/jwks', URI.parse("https://x#{@rec.reqs.first.path}").path
  end

  def test_unknown_kid_refetches_once
    rotated = new_key(8, 'rampart-classify-2')
    c = client(feed(@key), feed(@key, rotated))
    assert_equal 'suspicious', c.rampart.verify_receipt(sign(@key), INPUT, project_id: PROJECT_ID, issuer: ISSUER, clock: NOW).classification
    assert_equal 1, @rec.reqs.size
    assert_equal 'suspicious', c.rampart.verify_receipt(sign(rotated), INPUT, project_id: PROJECT_ID, issuer: ISSUER, clock: NOW).classification
    assert_equal 2, @rec.reqs.size
    c.rampart.verify_receipt(sign(@key), INPUT, project_id: PROJECT_ID, issuer: ISSUER, clock: NOW)
    assert_equal 2, @rec.reqs.size # both kids are cached now
  end

  def test_still_unknown_after_the_one_refetch
    ghost = new_key(5, 'ghost')
    c = client(feed(@key))
    c.rampart.verify_receipt(sign(@key), INPUT, project_id: PROJECT_ID, issuer: ISSUER, clock: NOW)
    assert_equal 1, @rec.reqs.size
    assert_refused(:key_unknown) { c.rampart.verify_receipt(sign(ghost), INPUT, project_id: PROJECT_ID, issuer: ISSUER, clock: NOW) }
    assert_equal 2, @rec.reqs.size # exactly one refetch
    assert_refused(:key_unknown) { c.rampart.verify_receipt(sign(ghost), INPUT, project_id: PROJECT_ID, issuer: ISSUER, clock: NOW) }
    assert_equal 3, @rec.reqs.size # one refetch per call, never a loop
  end

  def test_an_injected_key_set_is_never_refetched
    ghost = new_key(5, 'ghost')
    c = client(feed(ghost))
    assert_refused(:key_unknown) { c.rampart.verify_receipt(sign(ghost), INPUT, key_set: [@key[:jwk]], project_id: PROJECT_ID, issuer: ISSUER, clock: NOW) }
    assert_empty @rec.reqs
  end

  def test_feed_failure_is_an_error_not_a_pass
    c = client([503, JSON.dump('code' => 'K9O_UPSTREAM_UNAVAILABLE', 'message' => 'down', 'context' => {})])
    c.config.instance_variable_set(:@retry_config, K9o::RetryConfig.new(max_retries: 0))
    assert_raises(K9o::KError) { c.rampart.verify_receipt(sign(@key), INPUT, project_id: PROJECT_ID, issuer: ISSUER, clock: NOW) }
  end

  # project id

  def classified(receipt, project: PROJECT_ID)
    data = { 'classification' => 'suspicious', 'classificationReceipt' => receipt }
    data['projectId'] = project unless project.nil?
    K9o::Envelope.new(data: data, meta: K9o::Meta.new)
  end

  def test_a_classify_result_carries_the_project_id
    result = classified(sign(@key))
    v = @client.rampart.verify_receipt(result, INPUT, key_set: [@key[:jwk]], issuer: ISSUER, clock: NOW)
    assert_equal PROJECT_ID, v.project_id
  end

  def test_a_classify_result_straight_from_classify
    receipt = sign(@key)
    c = client(ok('classification' => 'suspicious', 'classificationReceipt' => receipt, 'projectId' => PROJECT_ID), feed(@key))
    result = c.rampart.classify(INPUT)
    v = c.rampart.verify_receipt(result, INPUT, clock: NOW)
    assert_equal 'suspicious', v.classification
  end

  def test_a_bare_receipt_without_a_project_id_is_project_unknown
    assert_refused(:project_unknown) do
      @client.rampart.verify_receipt(sign(@key), INPUT, key_set: [@key[:jwk]], issuer: ISSUER, clock: NOW)
    end
    assert_refused(:project_unknown) do
      @client.rampart.verify_receipt(classified(sign(@key), project: nil), INPUT, key_set: [@key[:jwk]], issuer: ISSUER, clock: NOW)
    end
  end

  def test_the_project_id_option_wins_over_the_classify_result
    result = classified(sign(@key), project: 'proj_other')
    assert_refused(:project) do
      @client.rampart.verify_receipt(result, INPUT, key_set: [@key[:jwk]], issuer: ISSUER, clock: NOW)
    end
    v = @client.rampart.verify_receipt(result, INPUT, key_set: [@key[:jwk]], issuer: ISSUER, project_id: PROJECT_ID, clock: NOW)
    assert_equal PROJECT_ID, v.project_id
  end

  def test_the_project_is_never_looked_up_or_read_from_meta
    c = client(ok({ 'classification' => 'suspicious', 'classificationReceipt' => 'x' }))
    c.rampart.classify(INPUT)
    assert_refused(:project_unknown) do
      c.rampart.verify_receipt(sign(@key), INPUT, key_set: [@key[:jwk]], issuer: ISSUER, clock: NOW)
    end
    assert_equal 1, @rec.reqs.size # no project lookup
  end

  # canonical form of the input

  def test_an_input_that_cannot_be_canonicalised_is_input_hash
    [{ 'x' => 1.5 }, { 'x' => 2**53 }, { 'x' => -(2**53) }, { 'x' => Float::NAN }].each do |bad|
      e = assert_refused(:input_hash) { verify(sign(@key), @key, input: bad) }
      assert_match(/cannot be canonicalised/, e.message)
    end
  end

  def test_classify_sends_an_input_it_would_not_canonicalise
    c = client(ok('classification' => 'clear'))
    c.rampart.classify({ 'x' => 1.5 })
    assert_equal({ 'input' => { 'x' => 1.5 } }, last[2])
  end

  # windows claim and 413

  def test_windows_claim_is_exposed_as_a_number
    assert_equal 1, verify(sign(@key, claims('windows' => 1)), @key).windows
    assert_equal 16, verify(sign(@key, claims('windows' => 16)), @key).windows
  end

  def test_receipt_without_windows_still_verifies
    assert_nil verify(sign(@key), @key).windows
  end

  def test_windows_that_is_not_a_positive_integer_is_not_exposed
    ['3', 2.5, 0, nil, [1]].each do |bad|
      assert_nil verify(sign(@key, claims('windows' => bad)), @key).windows
    end
  end

  def test_unknown_claims_are_tolerated
    v = verify(sign(@key, claims('windows' => 3, 'future_claim' => { 'a' => 1 }, 'another' => 'x')), @key)
    assert_equal ['suspicious', 3], [v.classification, v.windows]
  end

  def test_windows_is_signed_so_changing_it_breaks_the_signature
    parts = sign(@key, claims('windows' => 1)).split('.')
    forged = [parts[0], b64(JSON.dump(claims('windows' => 9))), parts[2]].join('.')
    assert_refused(:signature) { verify(forged, @key) }
  end

  def test_classify_413_input_too_long_is_a_typed_error_never_a_verdict
    body = JSON.dump('code' => 'K9O_RAMPART_INPUT_TOO_LONG', 'message' => 'input too long', 'context' => { 'reason' => 'rampart_input_too_long' },
                     'recommendation' => 'Send a shorter input.')
    c = client([413, body])
    e = assert_raises(K9o::KError) { c.rampart.classify({ 'text' => 'long ' * 5000 }) }
    assert_equal ['K9O_RAMPART_INPUT_TOO_LONG', 413, 'rampart_input_too_long'], [e.code, e.status, e.context['reason']]
    assert_equal 1, @rec.reqs.size # a client error is not retried
    refute_kind_of K9o::Rampart::Verdict, e
  end

  def test_the_two_methods_leave_other_namespaces_alone
    assert_respond_to @client, :vectors
    assert_respond_to @client, :rampart
  end
end
