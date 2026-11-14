# frozen_string_literal: true

require 'minitest/autorun'
require_relative '../lib/k9o'

class KErrorTest < Minitest::Test
  def test_constructs_with_required_fields
    e = K9o::KError.new(code: 'K9O_INVALID_FIELD_VALUE', message: 'bad')
    assert_equal 'K9O_INVALID_FIELD_VALUE', e.code
    assert_equal 'bad', e.message
    assert_equal({}, e.context)
    assert_nil e.recommendation
    assert_nil e.status
  end

  def test_is_raisable
    assert_raises(K9o::KError) { raise K9o::KError.new(code: 'X', message: 'y') }
  end

  def test_to_s_includes_status
    e = K9o::KError.new(code: 'K9O_TIER_CAP_HIT', message: 'cap', status: 429)
    s = e.to_s
    assert_includes s, 'K9O_TIER_CAP_HIT'
    assert_includes s, '429'
  end

  def test_with_recommendation
    e = K9o::KError.new(code: 'X', message: 'y').with_recommendation('do this')
    assert_equal 'do this', e.recommendation
  end

  def test_from_wire_rehydration
    e = K9o::KError.from_wire({
      'code' => 'K9O_TIER_CAP_HIT',
      'message' => 'cap',
      'context' => { 'dim' => 'mau' },
      'recommendation' => 'upgrade',
      'requestId' => 'req_x'
    }, 429)
    assert_equal 'K9O_TIER_CAP_HIT', e.code
    assert_equal 429, e.status
    assert_equal 'req_x', e.request_id
    assert_equal({ 'dim' => 'mau' }, e.context)
  end
end

# Wire decode of the gateway's `recommendation` field, which may be any JSON type.
class KErrorRecommendationTest < Minitest::Test
  ACTION = 'Open Billing and settle the outstanding wallet balance to lift the suspension.'

  def wire(rec)
    { 'code' => 'K9O_READ_ONLY_SUSPENDED', 'message' => 'suspended', 'context' => { 'x' => 1 }, 'recommendation' => rec }
  end

  def check(rec, status, want_rec, want_retry)
    e = K9o::KError.from_wire(wire(rec), status)
    assert_equal 'K9O_READ_ONLY_SUSPENDED', e.code
    assert_equal 'suspended', e.message
    assert_equal status, e.status
    assert_equal({ 'x' => 1 }, e.context)
    want_rec.nil? ? assert_nil(e.recommendation) : assert_equal(want_rec, e.recommendation)
    want_retry.nil? ? assert_nil(e.retry_after_sec) : assert_equal(want_retry, e.retry_after_sec)
    e
  end

  def test_all_shapes
    check({ 'action' => ACTION }, 403, ACTION, nil)
    check({ 'retryAfterSec' => 30, 'note' => 'retry' }, 429, 'retry', 30)
    check(nil, 403, nil, nil)
    check('do this', 403, 'do this', nil)
    check(7, 403, nil, nil)
    check([1, 2], 403, nil, nil)
    check(true, 403, nil, nil)
    check({ 'action' => 5, 'note' => 'n' }, 403, 'n', nil)
    check({ 'action' => 'a', 'note' => 'n' }, 403, 'a', nil)
    check({ 'retryAfterSec' => -1 }, 429, nil, nil)
    check({ 'retryAfterSec' => '30' }, 429, nil, nil)
    check({ 'retryAfterSec' => 0 }, 429, nil, 0)
    check({ 'retryAfterSec' => 1.5 }, 429, nil, 1.5)
    check({ 'retryAfterSec' => Float::INFINITY }, 429, nil, nil)
    check({ 'retryAfterSec' => Float::NAN }, 429, nil, nil)
  end

  def test_with_recommendation_keeps_retry_after
    e = K9o::KError.from_wire(wire({ 'retryAfterSec' => 5 }), 429).with_recommendation('x')
    assert_equal 5, e.retry_after_sec
    assert_equal 'x', e.recommendation
  end

  RespS = Struct.new(:code, :body)
  StreamResp = Struct.new(:code, :chunks) do
    def read_body(&blk)
      chunks.each(&blk)
    end
  end

  def client(http)
    K9o.create_client(base_url: 'https://acme.api-de01.k9o.io', api_key: 'k', project_slug: 'portal', http_client: http)
  end

  def http_with(resp)
    http = Object.new
    http.define_singleton_method(:use_ssl=) { |_| }
    http.define_singleton_method(:read_timeout=) { |_| }
    http.define_singleton_method(:request) { |_req, &blk| blk ? blk.call(resp) : resp }
    http
  end

  # Non-streaming path: raw JSON body through the transport.
  def test_request_path
    [[403, '{"action":"A"}', 'A', nil], [429, '{"retryAfterSec":30,"note":"retry"}', 'retry', 30],
     [403, 'null', nil, nil], [403, '"s"', 's', nil], [403, '12', nil, nil], [403, '[1]', nil, nil]].each do |status, rec, want, retry_after|
      body = %({"code":"K9O_X","message":"m","context":{"x":1},"recommendation":#{rec}})
      http = http_with(RespS.new(status.to_s, body))
      err = assert_raises(K9o::KError) { client(http).streams.publish('s', { 'a' => 1 }, subject: 's') }
      assert_equal 'K9O_X', err.code
      assert_equal status, err.status
      want.nil? ? assert_nil(err.recommendation) : assert_equal(want, err.recommendation)
      retry_after.nil? ? assert_nil(err.retry_after_sec) : assert_equal(retry_after, err.retry_after_sec)
    end
  end

  # Streaming path.
  def test_stream_path
    [[429, '{"retryAfterSec":30,"note":"retry"}', 'retry', 30], [403, '{"action":"A"}', 'A', nil],
     [403, '7', nil, nil], [403, 'null', nil, nil]].each do |status, rec, want, retry_after|
      body = %({"code":"K9O_X","message":"m","context":{"x":1},"recommendation":#{rec}})
      resp = StreamResp.new(status.to_s, [body])
      err = assert_raises(K9o::KError) { client(http_with(resp)).streams.subscribe('s').first(1) }
      assert_equal 'K9O_X', err.code
      assert_equal status, err.status
      want.nil? ? assert_nil(err.recommendation) : assert_equal(want, err.recommendation)
      retry_after.nil? ? assert_nil(err.retry_after_sec) : assert_equal(retry_after, err.retry_after_sec)
    end
  end

  # The gateway's request id header (x-k9o-request-id) fills request_id when the body has none.
  # Like Net::HTTPResponse: header lookup ignores the letter case of the name.
  HeaderResp = Struct.new(:code, :body, :headers) do
    def [](name)
      headers.each { |k, v| return v if k.to_s.downcase == name.to_s.downcase }
      nil
    end

    def read_body
      yield body
    end
  end

  def net_response(status, body, headers = {})
    HeaderResp.new(status.to_s, body, headers)
  end

  def request_id_for(body, headers)
    resp = net_response(404, body, headers)
    err = assert_raises(K9o::KError) { client(http_with(resp)).streams.publish('s', { 'a' => 1 }, subject: 's') }
    assert_equal 404, err.status
    err.request_id
  end

  def test_request_id_from_header
    body = '{"code":"K9O_NOT_FOUND","message":"m","context":{}}'
    assert_equal 'req_abc', request_id_for(body, 'x-k9o-request-id' => 'req_abc')
  end

  def test_request_id_body_wins_over_header
    body = '{"code":"K9O_NOT_FOUND","message":"m","context":{},"requestId":"req_body"}'
    assert_equal 'req_body', request_id_for(body, 'x-k9o-request-id' => 'req_header')
  end

  def test_request_id_nil_without_header_or_body_field
    assert_nil request_id_for('{"code":"K9O_NOT_FOUND","message":"m","context":{}}', {})
  end

  def test_request_id_header_name_is_case_insensitive
    body = '{"code":"K9O_NOT_FOUND","message":"m","context":{}}'
    assert_equal 'req_abc', request_id_for(body, 'X-K9O-Request-Id' => 'req_abc')
  end

  def test_request_id_from_header_on_non_kerror_body
    assert_equal 'req_abc', request_id_for('<html>gone</html>', 'x-k9o-request-id' => 'req_abc')
    assert_equal 'req_abc', request_id_for('{"unexpected":true}', 'x-k9o-request-id' => 'req_abc')
  end

  def test_request_id_from_header_on_stream_open
    resp = net_response(404, '{"code":"K9O_NOT_FOUND","message":"m","context":{}}', 'X-K9O-Request-Id' => 'req_abc')
    err = assert_raises(K9o::KError) { client(http_with(resp)).streams.subscribe('s').first(1) }
    assert_equal 'req_abc', err.request_id
  end

  def test_from_wire_request_id_header
    wire = { 'code' => 'X', 'message' => 'm' }
    assert_equal 'req_h', K9o::KError.from_wire(wire, 404, request_id_header: 'req_h').request_id
    assert_equal 'req_b', K9o::KError.from_wire(wire.merge('requestId' => 'req_b'), 404, request_id_header: 'req_h').request_id
    assert_nil K9o::KError.from_wire(wire, 404).request_id
  end
end
