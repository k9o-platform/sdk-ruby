# frozen_string_literal: true

module K9o
  # Metadata: k9o.metadata.* filter, search and follow columns you declare on a collection (or on another data
  # surface) through one API, with the same access rules as the data itself.
  #
  #   filter(surfaces:, where:, limit:, cursor:)                    POST  /@<slug>/metadata/query
  #   set(collection, id, columns)                                  PATCH /@<slug>/metadata/collection/<collection>/<id>
  #   search(surface:, field:, q:, limit:)                          POST  /@<slug>/metadata/search
  #   vectors.nearest(surface:, column:, embedding:, k:, ...)       POST  /@<slug>/metadata/vectors/nearest
  #   subscribe(surface, from_sequence:, on_resync:)                GET   /@<slug>/metadata/subscribe?surface=  (SSE)
  #   index.get(collection)                                         GET   /@<slug>/metadata/index/<collection>
  #   index.declare(collection, columns)                            PUT   /@<slug>/metadata/index/<collection>
  #
  # Declare the columns first (+index.declare+). +set+ writes declared columns only; +filter+, +search+ and
  # +vectors.nearest+ read declared columns only. Column names given to +filter+ (+where[].field+), +search+ (+field+)
  # and +vectors.nearest+ (+column+) are sent as +metadata.<name>+; the prefix is added when you leave it out. Rows
  # come back with bare column names under +metadata+.
  #
  # Every method takes its options as keyword arguments or as one Hash (with or without braces); keys may be
  # symbols or strings. A bad argument raises K9o::KError (+K9O_INVALID_FIELD_VALUE+, or +K9O_UNKNOWN_SURFACE+ for a
  # surface) before anything is sent. Gateway answers arrive as K9o::KError with the gateway's code:
  #
  # * 400 +K9O_UNKNOWN_SURFACE+: the surface is not +collection:<name>+, +telemetry:<event>+ or +storage:<bucket>+.
  # * 400 +K9O_METADATA_FIELD_NOT_INDEXED+: the column is not declared (+context["field"]+).
  # * 400 +K9O_ENCRYPTED_COLUMN_OPERATION_UNSUPPORTED+: an encrypted column supports only +eq+ (not null) and +in+.
  # * 400 +K9O_INVALID_FIELD_VALUE+, +K9O_INVALID_CURSOR+: a bad body field or cursor.
  # * 403 +K9O_ACCESS_DENIED+, +K9O_EXTENSION_PERMISSION_DENIED+: no access to the surface.
  # * 404 +K9O_COLLECTION_NOT_FOUND+ (declare on a missing collection), +K9O_NOT_FOUND+ (set on a missing record).
  # * 413 +K9O_QUERY_RESULT_TOO_LARGE+: more than 10000 rows across the surfaces.
  # * 501 +K9O_NOT_IMPLEMENTED+: +storage:+ surfaces are accepted by the SDK, and the gateway answers 501 for them.
  class Metadata
    # A page of rows: an Envelope whose +data+ is the Array of rows and whose +cursor+ is the cursor of the next
    # page, or +nil+ when there is none. Each row is { "surface", "scope", "recordId" (collection) or "eventId"
    # (telemetry), "metadata" }.
    class Page < Envelope
      def cursor
        meta.cursor&.next
      end
    end

    # Shared checks and the request helper.
    module Support
    OPS = %w[eq neq gt gte lt lte contains startsWith endsWith in notIn and or not].freeze
    METRICS = %w[cosine euclidean dot].freeze
    SLICES = %w[collection telemetry storage].freeze
    SCOPE = /\A[A-Za-z0-9][A-Za-z0-9._:-]{0,127}\z/.freeze
    IDENT = /\A[a-zA-Z_][a-zA-Z0-9_]{0,62}\z/.freeze
    PREFIX = 'metadata.'
    MAX_COLUMNS = 64
    MAX_LIMIT = 1000
    # On a telemetry surface these where fields are bare, never prefixed.
    TELEMETRY_FIELDS = %w[createdAt actorId].freeze

      private

      def invalid(message, context = {})
        ApprovalChecks.invalid(message, context)
      end

      def route(tail)
        UrlGrammar.project_path(Studio.require_project_slug(@config, 'metadata'), "metadata/#{tail}")
      end

      def segment(value)
        ::URI.encode_www_form_component(value).gsub('+', '%20')
      end

      def call(method, path, body = nil)
        HttpTransport.request(config: @config, method: method, path: path, body: body)
      end

      def page(envelope)
        Page.new(data: envelope.data, meta: envelope.meta)
      end

      # The options as a Hash with string keys, from keyword arguments, one Hash, or both.
      def options(input, extra, allowed)
        raise invalid('options must be a Hash') unless input.nil? || input.is_a?(Hash)

        opts = {}
        (input || {}).merge(extra).each { |key, value| opts[key.to_s] = value }
        unknown = opts.keys - allowed
        raise invalid("unknown option: #{unknown.join(', ')}", options: unknown) unless unknown.empty?

        opts
      end

      def slice_of(surface)
        surface[0, surface.index(':')]
      end

      def check_surface(surface, name)
        raise invalid("#{name} must be a string such as collection:posts", surface: surface) unless surface.is_a?(String)

        at = surface.index(':')
        slice = at ? surface[0, at] : ''
        scope = at ? surface[(at + 1)..] : ''
        unless SLICES.include?(slice) && SCOPE.match?(scope) && (slice != 'collection' || IDENT.match?(scope))
          raise KError.new(
            code: 'K9O_UNKNOWN_SURFACE',
            message: "#{name} \"#{surface}\" is not a surface: use collection:<name>, telemetry:<event> or storage:<bucket>",
            context: { surface: surface }
          )
        end
        surface
      end

      def check_collection_surface(surface, name)
        check_surface(surface, name)
        raise invalid("#{name} must be a collection surface (collection:<name>)", surface: surface) unless slice_of(surface) == 'collection'

        surface
      end

      def check_limit(value, name)
        return if value.nil?
        return if value.is_a?(Integer) && value >= 1 && value <= MAX_LIMIT

        raise invalid("#{name} must be a whole number from 1 to #{MAX_LIMIT}", name.to_sym => value)
      end

      # The name on the wire: metadata.<name>, adding the prefix when it is missing.
      def prefixed(name, label)
        name = name.to_s if name.is_a?(Symbol)
        raise invalid("#{label} must be a column name", label.to_sym => name) if !name.is_a?(String) || name.empty? || name == PREFIX

        name.start_with?(PREFIX) ? name : "#{PREFIX}#{name}"
      end

      def wire_where(where, telemetry)
        return nil if where.nil?
        raise invalid('where must be an array of { field, op, value }') unless where.is_a?(Array)

        where.each_with_index.map do |clause, index|
          raise invalid("where[#{index}] must be a Hash") unless clause.is_a?(Hash)

          c = clause.each_with_object({}) { |(key, value), out| out[key.to_s] = value }
          c['op'] = c['op'].to_s if c['op'].is_a?(Symbol)
          unless c['op'].is_a?(String) && OPS.include?(c['op'])
            raise invalid("where[#{index}].op must be one of: #{OPS.join(', ')}", op: c['op'])
          end

          field = c['field'].is_a?(Symbol) ? c['field'].to_s : c['field']
          bare = telemetry && field.is_a?(String) && TELEMETRY_FIELDS.include?(field)
          c['field'] = bare ? field : prefixed(field, "where[#{index}].field")
          c
        end
      end

      def collection_name(collection)
        collection = collection.to_s if collection.is_a?(Symbol)
        raise invalid('collection must be a collection name', collection: collection) unless collection.is_a?(String) && IDENT.match?(collection)

        collection
      end

      def finite?(value)
        value.is_a?(Numeric) && !value.is_a?(Complex) && (!value.respond_to?(:finite?) || value.finite?)
      end
    end

    include Support

    attr_reader :vectors, :index

    def initialize(config)
      @config = config
      @vectors = MetadataVectors.new(config)
      @index = MetadataIndex.new(config)
    end

    # Rows of one or more surfaces whose declared columns meet +where+, in request order. +surfaces+ is a non-empty
    # Array of +collection:<name>+, +telemetry:<event-prefix>+ or +storage:<bucket>+. +where+ is an Array of
    # { field:, op:, value: } applied to every surface (+op+ is one of eq, neq, gt, gte, lt, lte, contains, startsWith,
    # endsWith, in, notIn; and, or and not are part of the grammar and refused by the gateway). On a telemetry surface
    # +createdAt+ (gt, gte, lt, lte) and +actorId+ (eq) are sent as they are. +limit+ is 1 to 1000 per surface (the
    # gateway defaults to 100). +cursor+ is the +cursor+ of the previous page and is allowed with exactly one surface.
    # More than 10000 rows in all answers 413 K9O_QUERY_RESULT_TOO_LARGE; a +storage:+ surface answers 501
    # K9O_NOT_IMPLEMENTED. Returns a Page.
    def filter(input = nil, **extra)
      path = route('query')
      opts = options(input, extra, %w[surfaces where limit cursor])
      surfaces = opts['surfaces']
      raise invalid('surfaces must be a non-empty array') unless surfaces.is_a?(Array) && !surfaces.empty?

      surfaces = surfaces.each_with_index.map { |s, i| check_surface(s, "surfaces[#{i}]") }
      check_limit(opts['limit'], 'limit')
      unless opts['cursor'].nil?
        raise invalid('cursor must be the cursor of a previous page') unless opts['cursor'].is_a?(String) && !opts['cursor'].empty?
        raise invalid('cursor is allowed only with exactly one surface', field: 'cursor') unless surfaces.size == 1
      end
      where = wire_where(opts['where'], surfaces.any? { |s| slice_of(s) == 'telemetry' })
      body = { 'surfaces' => surfaces }
      body['where'] = where unless where.nil?
      body['limit'] = opts['limit'] unless opts['limit'].nil?
      body['cursor'] = opts['cursor'] unless opts['cursor'].nil?
      page(call('POST', path, body))
    end

    # Write declared columns of one record: <tt>set("posts", "p2", title: "New", priority: 9)</tt> or with a Hash.
    # Keys are bare column names (a leading +metadata.+ is dropped); a column that is not declared answers 400
    # K9O_METADATA_FIELD_NOT_INDEXED. +data+ is the whole updated record. The write runs through the record API's
    # rules, so a write that needs approval is queued as it is there.
    def set(collection, id, columns = nil, **extra)
      name = collection_name(collection)
      raise invalid('id must be a record id', id: id) unless id.is_a?(String) && !id.empty?
      raise invalid('columns must be a Hash with at least one column') unless columns.nil? || columns.is_a?(Hash)

      merged = (columns || {}).merge(extra)
      raise invalid('columns must be a Hash with at least one column') if merged.empty?

      bare = merged.each_with_object({}) do |(key, value), out|
        key = key.to_s
        out[key.start_with?(PREFIX) ? key[PREFIX.size..] : key] = value
      end
      call('PATCH', route("collection/#{segment(name)}/#{segment(id)}"), 'metadata' => bare)
    end

    # Full-text search over one declared text column of a collection: +surface:+ (+collection:<name>+), +field:+
    # (+body+ or +metadata.body+), +q:+ (the words to look for) and optional +limit:+ (1 to 1000, the gateway
    # defaults to 50). Matching is by word stem, so "finance" does not match "financial". Returns the first page
    # only (there is no cursor input) and no rank. Returns a Page.
    def search(input = nil, **extra)
      path = route('search')
      opts = options(input, extra, %w[surface field q limit])
      surface = check_collection_surface(opts['surface'], 'surface')
      field = prefixed(opts['field'], 'field')
      raise invalid('q must be a non-empty string') unless opts['q'].is_a?(String) && !opts['q'].empty?

      check_limit(opts['limit'], 'limit')
      body = { 'surface' => surface, 'field' => field, 'q' => opts['q'] }
      body['limit'] = opts['limit'] unless opts['limit'].nil?
      page(call('POST', path, body))
    end

    # Follow changes of a +collection:<name>+ surface live. Returns an Enumerator of events whose +eventType+ is
    # +row_inserted+, +row_updated+ or +row_deleted+ and whose +payload+ is { "collection", "id" } only, so read the
    # record by id for its values. It is the reader behind Realtime#subscribe: it reconnects with +Last-Event-ID+,
    # drops events it already delivered and calls +on_resync+ (a callable, may be nil) when the position is lost.
    # +from_sequence+ (a whole number, 0 or more) starts from a known feed position; it applies only to the first
    # connection. Changes to undeclared columns are reported too.
    def subscribe(surface, input = nil, **extra)
      path = route('subscribe')
      opts = {}
      raise invalid('options must be a Hash') unless input.nil? || input.is_a?(Hash)

      (input || {}).merge(extra).each { |key, value| opts[key.to_s] = value }
      from = opts.key?('from_sequence') ? opts['from_sequence'] : opts['fromSequence']
      unknown = opts.keys - %w[from_sequence fromSequence on_resync]
      raise invalid("unknown option: #{unknown.join(', ')}", options: unknown) unless unknown.empty?

      target = check_collection_surface(surface, 'surface')
      unless from.nil? || (from.is_a?(Integer) && from >= 0)
        raise invalid('from_sequence must be a whole number, 0 or more', from_sequence: from)
      end
      Realtime.new(@config).feed(path, { 'surface' => target }, from.nil? ? nil : { 'fromSequence' => from }, opts['on_resync'])
    end
  end

  # client.metadata.vectors
  class MetadataVectors
    include Metadata::Support

    def initialize(config)
      @config = config
    end

    # The rows whose declared vector column is nearest to +embedding+, closest first: +surface:+ (+collection:<name>+),
    # +column:+ (+embedding+ or +metadata.embedding+), +embedding:+ (a non-empty Array of finite numbers), optional
    # +k:+ (1 to 1000, the gateway defaults to 10), +metric:+ (+cosine+ default, +euclidean+, +dot+) and +where:+
    # (conditions in the grammar of Metadata#filter). Rows carry no score. At most 50 rows come back whatever +k+
    # is, until the gateway forwards a larger page size. Returns a Metadata::Page.
    def nearest(input = nil, **extra)
      path = route('vectors/nearest')
      opts = options(input, extra, %w[surface column embedding k metric where])
      surface = check_collection_surface(opts['surface'], 'surface')
      column = prefixed(opts['column'], 'column')
      embedding = opts['embedding']
      raise invalid('embedding must be a non-empty array of numbers') unless embedding.is_a?(Array) && !embedding.empty?
      raise invalid('embedding must contain only finite numbers') unless embedding.all? { |n| finite?(n) }

      check_limit(opts['k'], 'k')
      metric = opts['metric']
      metric = metric.to_s if metric.is_a?(Symbol)
      raise invalid("metric must be one of: #{METRICS.join(', ')}", metric: metric) unless metric.nil? || METRICS.include?(metric)

      where = wire_where(opts['where'], false)
      body = { 'surface' => surface, 'column' => column, 'embedding' => embedding }
      body['k'] = opts['k'] unless opts['k'].nil?
      body['metric'] = metric unless metric.nil?
      body['where'] = where unless where.nil?
      page(call('POST', path, body))
    end
  end

  # client.metadata.index
  class MetadataIndex
    include Metadata::Support

    def initialize(config)
      @config = config
    end

    # The columns declared on a collection, ordered by name. +data+ is { "collection", "columns" => [{ "column",
    # "indexed" }] }.
    def get(collection)
      name = collection_name(collection)
      call('GET', route("index/#{segment(name)}"))
    end

    # Declare the columns of a collection that metadata may use: an Array of { column:, indexed: } (+indexed+
    # defaults to false). The columns must already exist on the collection. The list replaces the previous declaration
    # (an empty list clears it); at most 64 columns, no +id+, no duplicates. Needs the project-admin role and the
    # migrations permission.
    def declare(collection, columns)
      name = collection_name(collection)
      raise invalid('columns must be an array of { column, indexed? }') unless columns.is_a?(Array)
      raise invalid("at most #{MAX_COLUMNS} columns can be declared", count: columns.size) if columns.size > MAX_COLUMNS

      seen = {}
      wire = columns.each_with_index.map do |entry, index|
        raise invalid("columns[#{index}] must be a Hash") unless entry.is_a?(Hash)

        c = entry.each_with_object({}) { |(key, value), out| out[key.to_s] = value }
        column = c['column'].is_a?(Symbol) ? c['column'].to_s : c['column']
        unless column.is_a?(String) && IDENT.match?(column) && column != 'id'
          raise invalid("columns[#{index}].column must be a column name other than id", column: c['column'])
        end
        unless c['indexed'].nil? || c['indexed'] == true || c['indexed'] == false
          raise invalid("columns[#{index}].indexed must be true or false")
        end
        raise invalid("column \"#{column}\" is listed twice", column: column) if seen[column]

        seen[column] = true
        c['column'] = column
        c
      end
      call('PUT', route("index/#{segment(name)}"), 'columns' => wire)
    end
  end
end
