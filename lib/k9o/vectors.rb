# frozen_string_literal: true

module K9o
  # Vector collections: k9o.vectors.* store embeddings you computed yourself, next to the text and metadata they came
  # from, and find the nearest ones.
  #
  #   nearest(collection, query_vector, top_k:, min_score:, metric:, filters:)  POST /@<slug>/vectors/<collection>/search
  #   upsert(collection, rows)                                                  POST /@<slug>/vectors/<collection>/upsert
  #
  # Both send the vector in the request body, so they take real embeddings of any common size (up to 16000 numbers).
  # The collection name must start with +_+. The first upsert creates the collection and fixes its dimension; every
  # later vector must have the same length. Searching a collection that was never upserted answers 404
  # K9O_COLLECTION_NOT_FOUND.
  class Vectors
    METRICS = %w[cosine euclidean dot].freeze
    MAX_VECTOR = 16_000
    MAX_ROWS = 1000
    # Snake_case spellings accepted for the camelCase wire keys of a row and of its +_source+.
    ROW_ALIASES = { 'content_hash' => 'contentHash', 'subject_ids' => 'subjectIds' }.freeze
    SOURCE_ALIASES = { 'chunk_index' => 'chunkIndex' }.freeze

    def initialize(config)
      @config = config
    end

    # The rows nearest to +query_vector+ (1 to 16000 numbers), closest first. +top_k+ is 1 to 1000 (the gateway
    # defaults to 10); +min_score+ drops results scoring below it; +metric+ is cosine (default), euclidean or dot;
    # +filters+ is a Hash of equality checks on +id+, +contentHash+, +source.<key>+ and +metadata.<key>+.
    # +data+ is { 'results' => [...], 'collection' => name }.
    def nearest(collection, query_vector, top_k: nil, min_score: nil, metric: nil, filters: nil)
      route = path(collection, 'search')
      check_vector(query_vector, 'query_vector')
      body = { 'queryVector' => query_vector.to_a }
      unless top_k.nil?
        unless top_k.is_a?(Integer) && top_k >= 1 && top_k <= 1000
          raise invalid('top_k must be a whole number from 1 to 1000', top_k: top_k)
        end

        body['topK'] = top_k
      end
      unless min_score.nil?
        raise invalid('min_score must be a number', min_score: min_score) unless finite?(min_score)

        body['minScore'] = min_score
      end
      body['metric'] = ApprovalChecks.enum!(metric, METRICS, 'metric') unless metric.nil?
      unless filters.nil?
        raise invalid('filters must be a Hash of path to value') unless filters.is_a?(Hash)

        body['filters'] = filters.transform_keys(&:to_s)
      end
      call(route, body)
    end

    # Insert or overwrite 1 to 1000 rows in one request; the first upsert creates the collection. A row is a Hash
    # with +vector+ and +_source+ ({ handle:, chunkIndex: }), and optionally +id+, +contentHash+, +text+, +metadata+
    # and +subjectIds+ (one end-user id, ["eu_..."]; required unless the collection was declared shared). Keys may
    # be strings or symbols, and +content_hash+, +subject_ids+ and +chunk_index+ are accepted for the camelCase
    # names. A single row may be passed on its own, with or without braces. +data+ is { 'upserted' => n,
    # 'collection' => name }.
    def upsert(collection, rows = nil, **row)
      route = path(collection, 'upsert')
      rows = [row] if rows.nil? && !row.empty?
      rows = [rows] if rows.is_a?(Hash)
      unless rows.is_a?(Array) && rows.size >= 1 && rows.size <= MAX_ROWS
        raise invalid("rows must be an array of 1 to #{MAX_ROWS} rows")
      end

      wire = rows.each_with_index.map do |entry, index|
        raise invalid("rows[#{index}] must be a Hash") unless entry.is_a?(Hash)

        normalize_row(entry, index)
      end
      call(route, 'rows' => wire)
    end

    private

    def normalize_row(entry, index)
      row = entry.each_with_object({}) do |(key, value), out|
        name = key.to_s
        out[ROW_ALIASES.fetch(name, name)] = value
      end
      check_vector(row['vector'], "rows[#{index}].vector")
      source = row['_source']
      if source.is_a?(Hash)
        row['_source'] = source.each_with_object({}) do |(key, value), out|
          name = key.to_s
          out[SOURCE_ALIASES.fetch(name, name)] = value
        end
      end
      row['vector'] = row['vector'].to_a
      row
    end

    def check_vector(vector, name)
      unless vector.is_a?(Array) && vector.size >= 1 && vector.size <= MAX_VECTOR
        raise invalid("#{name} must be an array of 1 to #{MAX_VECTOR} numbers")
      end
      return if vector.all? { |n| finite?(n) }

      raise invalid("#{name} must contain only finite numbers")
    end

    def finite?(value)
      value.is_a?(Numeric) && !value.is_a?(Complex) && (!value.respond_to?(:finite?) || value.finite?)
    end

    def invalid(message, context = {})
      ApprovalChecks.invalid(message, context)
    end

    def call(route, body)
      HttpTransport.request(config: @config, method: 'POST', path: route, body: body)
    end

    def path(collection, tail)
      raise invalid('a vector collection name must start with _', collection: collection) unless collection.is_a?(String) && collection.start_with?('_')

      slug = Studio.require_project_slug(@config, 'vectors')
      UrlGrammar.project_path(slug, "vectors/#{::URI.encode_www_form_component(collection).gsub('+', '%20')}/#{tail}")
    end
  end
end
