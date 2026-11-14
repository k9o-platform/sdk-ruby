# frozen_string_literal: true

require 'minitest/autorun'
require 'json'
require_relative '../lib/k9o'

# Vector collections: wire shape (method, path, body), answer decoding and client-side validation.
class VectorsTest < Minitest::Test
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

  META = { 'cost' => {}, 'timing' => {}, 'context' => { 'requestId' => 'req_1', 'traceId' => 'req_1', 'projectId' => 'proj_1' } }.freeze
  SRC = { 'handle' => 'ruby-probe', 'chunkIndex' => 0 }.freeze
  NEAREST = {
    'results' => [
      { 'id' => 'p1', 'score' => 1, '_source' => SRC, 'contentHash' => nil, 'text' => 'x axis', 'metadata' => {}, 'model' => nil, 'chunk' => 0 },
      { 'id' => 'p2', 'score' => 0.8, '_source' => SRC, 'contentHash' => nil, 'text' => nil, 'metadata' => { 'lang' => 'en' }, 'model' => nil, 'chunk' => nil }
    ],
    'collection' => '_vec_example'
  }.freeze

  def client(*answers)
    @rec = Scripted.new(*answers)
    K9o.create_client(base_url: 'https://acme.api-de01.k9o.io', api_key: 'k', project_slug: 'portal', http_client: @rec)
  end

  def ok(data)
    [200, JSON.dump('data' => data, 'meta' => META)]
  end

  def last
    req = @rec.reqs.last
    [req.method, URI.parse("https://x#{req.path}").path, JSON.parse(req.body)]
  end

  def assert_invalid(&blk)
    before = @rec.reqs.size
    e = assert_raises(K9o::KError, &blk)
    assert_equal 'K9O_INVALID_FIELD_VALUE', e.code
    assert_equal before, @rec.reqs.size
  end

  def test_nearest_minimal
    c = client(ok(NEAREST))
    r = c.vectors.nearest('_vec_example', [1, 0, 0], top_k: 2)
    assert_equal ['POST', '/@portal/vectors/_vec_example/search', { 'queryVector' => [1, 0, 0], 'topK' => 2 }], last
    assert_equal %w[p1 p2], r.data['results'].map { |h| h['id'] }
    assert_equal '_vec_example', r.data['collection']
    assert_nil r.data['results'][0]['contentHash']
    assert_nil r.data['results'][0]['model']
    assert_equal 0.8, r.data['results'][1]['score']
  end

  def test_nearest_all_options
    c = client(ok(NEAREST))
    c.vectors.nearest('_n', [0.5, 0.5], top_k: 5, min_score: 0.2, metric: :dot, filters: { 'metadata.lang' => 'en', id: 'p1' })
    assert_equal ['POST', '/@portal/vectors/_n/search',
                  { 'queryVector' => [0.5, 0.5], 'topK' => 5, 'minScore' => 0.2, 'metric' => 'dot',
                    'filters' => { 'metadata.lang' => 'en', 'id' => 'p1' } }], last
  end

  def test_nearest_braceless_filters_hash_is_not_confused
    c = client(ok(NEAREST))
    c.vectors.nearest('_n', [1.0], filters: { 'source.handle' => 'a' })
    assert_equal({ 'queryVector' => [1.0], 'filters' => { 'source.handle' => 'a' } }, last[2])
  end

  def test_nearest_validation_sends_nothing
    c = client(ok(NEAREST))
    assert_invalid { c.vectors.nearest('notunderscore', [1]) }
    assert_invalid { c.vectors.nearest(nil, [1]) }
    assert_invalid { c.vectors.nearest('_n', []) }
    assert_invalid { c.vectors.nearest('_n', nil) }
    assert_invalid { c.vectors.nearest('_n', Array.new(16_001, 0.1)) }
    assert_invalid { c.vectors.nearest('_n', [1, Float::NAN]) }
    assert_invalid { c.vectors.nearest('_n', [1, Float::INFINITY]) }
    assert_invalid { c.vectors.nearest('_n', [1, '2']) }
    assert_invalid { c.vectors.nearest('_n', [1], top_k: 0) }
    assert_invalid { c.vectors.nearest('_n', [1], top_k: 1001) }
    assert_invalid { c.vectors.nearest('_n', [1], top_k: 1.5) }
    assert_invalid { c.vectors.nearest('_n', [1], min_score: 'x') }
    assert_invalid { c.vectors.nearest('_n', [1], min_score: Float::NAN) }
    assert_invalid { c.vectors.nearest('_n', [1], metric: 'manhattan') }
    assert_invalid { c.vectors.nearest('_n', [1], filters: [1]) }
    assert_equal 0, @rec.reqs.size
  end

  def test_nearest_limits_accepted
    c = client(ok(NEAREST))
    c.vectors.nearest('_n', Array.new(16_000, 0.1), top_k: 1000)
    assert_equal 16_000, last[2]['queryVector'].size
    assert_equal 1000, last[2]['topK']
  end

  def test_upsert_wire_and_answer
    c = client(ok('upserted' => 3, 'collection' => '_vec_example'))
    rows = [
      { id: 'p1', vector: [1, 0, 0], _source: { handle: 'intro', chunkIndex: 0 }, text: 'x', metadata: { lang: 'en' }, subjectIds: ['eu_YmGE3Z6nkv5i'] },
      { 'id' => 'p2', 'vector' => [0, 1, 0], '_source' => { 'handle' => 'intro', 'chunkIndex' => 1 }, 'contentHash' => 'h', 'subjectIds' => ['eu_YmGE3Z6nkv5i'] }
    ]
    r = c.vectors.upsert('_vec_example', rows)
    method, path, body = last
    assert_equal ['POST', '/@portal/vectors/_vec_example/upsert'], [method, path]
    assert_equal 2, body['rows'].size
    assert_equal({ 'id' => 'p1', 'vector' => [1, 0, 0], '_source' => { 'handle' => 'intro', 'chunkIndex' => 0 }, 'text' => 'x',
                   'metadata' => { 'lang' => 'en' }, 'subjectIds' => ['eu_YmGE3Z6nkv5i'] }, body['rows'][0])
    assert_equal 'h', body['rows'][1]['contentHash']
    assert_equal 3, r.data['upserted']
    assert_equal '_vec_example', r.data['collection']
  end

  def test_upsert_snake_case_aliases
    c = client(ok('upserted' => 1, 'collection' => '_n'))
    c.vectors.upsert('_n', [{ vector: [1], _source: { handle: 'h', chunk_index: 2 }, content_hash: 'abc', subject_ids: ['eu_a'] }])
    row = last[2]['rows'][0]
    assert_equal({ 'vector' => [1], '_source' => { 'handle' => 'h', 'chunkIndex' => 2 }, 'contentHash' => 'abc', 'subjectIds' => ['eu_a'] }, row)
  end

  def test_upsert_single_row_with_and_without_braces
    c = client(ok('upserted' => 1, 'collection' => '_n'))
    c.vectors.upsert('_n', { id: 'ruby-1', vector: [0, 0, 1], _source: { handle: 'h', chunkIndex: 0 } })
    assert_equal [{ 'id' => 'ruby-1', 'vector' => [0, 0, 1], '_source' => { 'handle' => 'h', 'chunkIndex' => 0 } }], last[2]['rows']
    c.vectors.upsert('_n', id: 'ruby-2', vector: [0, 0, 1], _source: { handle: 'h', chunkIndex: 0 })
    assert_equal 'ruby-2', last[2]['rows'][0]['id']
    assert_equal 1, last[2]['rows'].size
  end

  def test_upsert_validation_sends_nothing
    c = client(ok('upserted' => 1, 'collection' => '_n'))
    good = { vector: [1], _source: { handle: 'h', chunkIndex: 0 } }
    assert_invalid { c.vectors.upsert('plain', [good]) }
    assert_invalid { c.vectors.upsert('_n', []) }
    assert_invalid { c.vectors.upsert('_n', nil) }
    assert_invalid { c.vectors.upsert('_n', 'x') }
    assert_invalid { c.vectors.upsert('_n', Array.new(1001) { good }) }
    assert_invalid { c.vectors.upsert('_n', [good, 5]) }
    assert_invalid { c.vectors.upsert('_n', [{ _source: { handle: 'h', chunkIndex: 0 } }]) }
    assert_invalid { c.vectors.upsert('_n', [good.merge(vector: [])]) }
    assert_invalid { c.vectors.upsert('_n', [good.merge(vector: [Float::NAN])]) }
    assert_invalid { c.vectors.upsert('_n', [good.merge(vector: Array.new(16_001, 0))]) }
    assert_equal 0, @rec.reqs.size
    c.vectors.upsert('_n', Array.new(1000) { good })
    assert_equal 1000, last[2]['rows'].size
  end

  def test_requires_project_slug
    @rec = Scripted.new(ok({}))
    c = K9o.create_client(base_url: 'https://acme.api-de01.k9o.io', api_key: 'k', http_client: @rec)
    assert_raises(StandardError) { c.vectors.nearest('_n', [1]) }
    assert_equal 0, @rec.reqs.size
  end

  def test_collection_not_found_404
    body = { 'code' => 'K9O_COLLECTION_NOT_FOUND', 'message' => "derived vector collection '_vec_example' does not exist",
             'context' => { 'collection' => '_vec_example' }, 'recommendation' => nil }
    c = client([404, JSON.dump(body)])
    e = assert_raises(K9o::KError) { c.vectors.nearest('_vec_example', [1, 0, 0]) }
    assert_equal 'K9O_COLLECTION_NOT_FOUND', e.code
    assert_equal 404, e.status
    assert_includes e.message, '_vec_example'
  end

  def test_invalid_dimension_400
    body = { 'code' => 'K9O_INVALID_VECTOR_DIMENSION', 'message' => "query vector dimension does not match collection '_vec_example'",
             'context' => { 'collection' => '_vec_example', 'queryDim' => 2 }, 'recommendation' => nil }
    c = client([400, JSON.dump(body)])
    e = assert_raises(K9o::KError) { c.vectors.nearest('_vec_example', [1, 0]) }
    assert_equal 'K9O_INVALID_VECTOR_DIMENSION', e.code
    assert_equal 400, e.status
    assert_equal 2, e.context['queryDim']
  end
end
