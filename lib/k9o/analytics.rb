# frozen_string_literal: true

require 'json'
require 'time'
require 'stringio'

module K9o
  # Shared plumbing for the dataset namespaces.
  module DatasetSupport
    REATTEST_DAYS = [7, 30, 90, 365].freeze
    ON_ERROR = %w[skip reject].freeze
    UPLOAD_FORMATS = %w[csv json].freeze
    MAX_UPLOAD_BYTES = 25 * 1024 * 1024
    RESIDENCY = %w[per-subject shared].freeze

    private

    def invalid(message, context = {})
      ApprovalChecks.invalid(message, context)
    end

    def seg(value, what)
      ApprovalChecks.id_segment(value, what)
    end

    def project
      Studio.require_project_slug(@config, 'datasets')
    end

    def route(tail)
      UrlGrammar.project_path(project, tail)
    end

    def call(method, tail, body: nil, query: nil, **extra)
      HttpTransport.request(config: @config, method: method, path: route(tail), body: body, query: query, **extra)
    end

    def stringify(value)
      case value
      when Hash then value.each_with_object({}) { |(k, v), out| out[k.to_s] = stringify(v) }
      when Array then value.map { |v| stringify(v) }
      when Symbol then value.to_s
      else value
      end
    end

    def reattest_days!(value)
      return nil if value.nil?
      return value if REATTEST_DAYS.include?(value)

      raise invalid("reattest_interval_days must be one of #{REATTEST_DAYS.join(', ')}", reattest_interval_days: value)
    end
  end

  # client.analytics: datasets. Routes under /@<slug>/analytics.
  #
  #   list                                          GET    analytics
  #   query(sql, datasets)                          POST   analytics/query
  #   create(slug, display_name:, columns:, residency_class:, ...)   POST   analytics/<slug>
  #   get(slug) / delete(slug)                      GET / DELETE analytics/<slug>
  #   materialize(slug, from_collection:|from_query:) POST   analytics/<slug>/materialize
  #   read(slug, partition_filter:, cursor:, limit:) POST   analytics/<slug>/read
  #   write(slug, rows, on_error:)                  POST   analytics/<slug>/write
  #   upload(slug, data, format:, ...)              POST   analytics/<slug>/upload
  #   download_original(slug)                       GET    analytics/<slug>/upload/original (bytes)
  #   rollups / schedules                           see AnalyticsRollups and AnalyticsSchedules
  #
  # Every call needs project membership with the matching datasets permission; service, workload and extension
  # tokens are refused. While the region's analytics storage is not provisioned, queries and writes answer 503
  # K9O_ANALYTICS_UNAVAILABLE (raised as K9o::KError).
  class Analytics
    include DatasetSupport

    attr_reader :rollups, :schedules

    def initialize(config)
      @config = config
      @rollups = AnalyticsRollups.new(config)
      @schedules = AnalyticsSchedules.new(config)
    end

    # The project's active datasets, newest first.
    def list
      call('GET', 'analytics')
    end

    # Run one read-only SQL SELECT over datasets. Reference each as +dataset.<slug>+ and name it in +datasets+ (1 to
    # 64 slugs). +sql+ is at most 100,000 characters. +data+ holds the rows.
    def query(sql, datasets)
      raise invalid('sql must be a non-empty String') unless sql.is_a?(String) && !sql.strip.empty?
      raise invalid('sql must be at most 100000 characters', length: sql.length) if sql.length > 100_000
      unless datasets.is_a?(Array) && !datasets.empty? && datasets.size <= 64 &&
             datasets.all? { |d| d.is_a?(String) && !d.empty? }
        raise invalid('datasets must be an Array of 1 to 64 dataset slugs')
      end

      call('POST', 'analytics/query', body: { 'sql' => sql, 'datasets' => datasets })
    end

    # Create a dataset at +slug+. +columns+ is an Array of { name:, type: } (1 to 512; types string, int32, int64,
    # float64, bool, date, timestamp, json, bytes, decimal(p,s)). +residency_class+ is "per-subject" or "shared".
    # Optional +partition_by+ (up to 16 keys; a timestamp key needs a transform such as "created_at:day") and
    # +storage_target+ ({ kind: "managed" } or { kind: "byos", binding_id: ... } spelled { kind:, bindingId: }).
    def create(slug, display_name:, columns:, residency_class:, partition_by: nil, storage_target: nil)
      unless display_name.is_a?(String) && !display_name.empty? && display_name.length <= 200
        raise invalid('display_name must be a String of 1 to 200 characters')
      end
      unless columns.is_a?(Array) && !columns.empty? && columns.size <= 512 && columns.all? { |c| c.is_a?(Hash) }
        raise invalid('columns must be an Array of 1 to 512 { name:, type: } Hashes')
      end

      cls = residency_class.to_s
      raise invalid("residency_class must be one of #{RESIDENCY.join(', ')}", residency_class: residency_class) unless RESIDENCY.include?(cls)

      body = { 'displayName' => display_name, 'columns' => stringify(columns), 'residencyClass' => cls }
      unless partition_by.nil?
        raise invalid('partition_by must be an Array of at most 16 strings') unless partition_by.is_a?(Array) && partition_by.size <= 16

        body['partitionBy'] = partition_by
      end
      body['storageTarget'] = stringify(storage_target) unless storage_target.nil?
      call('POST', "analytics/#{seg(slug, 'dataset')}", body: body)
    end

    def get(slug)
      call('GET', "analytics/#{seg(slug, 'dataset')}")
    end

    # Retire the dataset: it reads as absent from then on and its slug is never reissued.
    def delete(slug)
      call('DELETE', "analytics/#{seg(slug, 'dataset')}")
    end

    # Copy rows in from exactly one source: +from_collection+ (a collection name) or +from_query+ (a saved Studio
    # query id that reads one collection). +data+ has rowsRead, ingested and rejected.
    def materialize(slug, from_collection: nil, from_query: nil)
      if from_collection.nil? == from_query.nil?
        raise invalid('give exactly one of from_collection or from_query')
      end

      body = {}
      body['fromCollection'] = from_collection unless from_collection.nil?
      body['fromQuery'] = from_query unless from_query.nil?
      call('POST', "analytics/#{seg(slug, 'dataset')}/materialize", body: body)
    end

    # One page of rows. Each row has a stable +_k9o_row_id+; +meta.cursor.next+ is the +cursor:+ of the next page and
    # nil on the last. The first page carries +meta.schema+.
    def read(slug, partition_filter: nil, cursor: nil, limit: nil)
      body = {}
      body['partitionFilter'] = stringify(partition_filter) unless partition_filter.nil?
      body['cursor'] = cursor unless cursor.nil?
      unless limit.nil?
        raise invalid('limit must be a whole number of 1 or more', limit: limit) unless limit.is_a?(Integer) && limit >= 1

        body['limit'] = limit
      end
      call('POST', "analytics/#{seg(slug, 'dataset')}/read", body: body)
    end

    # Append rows. +rows+ is an Array of Hashes (sent as a JSON array) or a String of newline-delimited JSON. A bad
    # row is skipped and reported (+on_error: "skip"+, the default) or refuses the whole write ("reject").
    # +data+ has ingested, skipped, skippedDetails, the partitions touched and the bytes written.
    def write(slug, rows, on_error: nil)
      query = on_error_query(on_error)
      path = "analytics/#{seg(slug, 'dataset')}/write"
      if rows.is_a?(String)
        call('POST', path, query: query, raw_body: rows, headers: { 'content-type' => 'application/x-ndjson' })
      elsif rows.is_a?(Array) && rows.all? { |r| r.is_a?(Hash) }
        call('POST', path, query: query, body: stringify(rows))
      else
        raise invalid('rows must be an Array of Hashes or a String of newline-delimited JSON')
      end
    end

    # Upload a CSV or JSON file (a String of bytes or an IO; up to 25 MiB). +format+ is "csv" or "json" (required).
    # +dry_run: true+ returns the detected columns and a 50-row preview without writing. +manifest+ (a Hash, same
    # fields as #create) on a slug that does not exist yet creates the dataset and loads the file in one call; the
    # file then goes as multipart with +filename+. CSV options: +delimiter+, +encoding+, +has_header+.
    def upload(slug, data, format:, filename: 'upload', manifest: nil, dry_run: nil, on_error: nil, delimiter: nil,
               encoding: nil, has_header: nil)
      fmt = format.to_s
      raise invalid("format must be one of #{UPLOAD_FORMATS.join(', ')}", format: format) unless UPLOAD_FORMATS.include?(fmt)

      bytes = data.respond_to?(:read) ? data.read : data
      raise invalid('data must be a String or an IO') unless bytes.is_a?(String)
      raise invalid("the file is over #{MAX_UPLOAD_BYTES} bytes", size: bytes.bytesize) if bytes.bytesize > MAX_UPLOAD_BYTES

      query = { 'format' => fmt }
      query['dryRun'] = dry_run.to_s unless dry_run.nil?
      query.merge!(on_error_query(on_error))
      query['delimiter'] = delimiter unless delimiter.nil?
      query['encoding'] = encoding unless encoding.nil?
      query['hasHeader'] = has_header.to_s unless has_header.nil?
      path = "analytics/#{seg(slug, 'dataset')}/upload"
      mime = fmt == 'csv' ? 'text/csv' : 'application/json'
      if manifest.nil?
        call('POST', path, query: query, raw_body: bytes, headers: { 'content-type' => mime })
      else
        raise invalid('manifest must be a Hash') unless manifest.is_a?(Hash)

        parts = [{ name: 'file', value: bytes, filename: filename, content_type: mime },
                 { name: 'manifest', value: JSON.dump(stringify(manifest)), content_type: 'application/json' }]
        call('POST', path, query: query, multipart: parts)
      end
    end

    # The original file of the dataset's stored upload. Answers a K9o::Download (+body+ bytes, +content_type+),
    # not an Envelope; 404 when none is stored.
    def download_original(slug)
      call('GET', "analytics/#{seg(slug, 'dataset')}/upload/original", binary: true)
    end

    private

    def on_error_query(on_error)
      return {} if on_error.nil?

      { 'onError' => ApprovalChecks.enum!(on_error, ON_ERROR, 'on_error') }
    end
  end

  # client.analytics.rollups: continuous rollups that fold a stream into a dataset over fixed windows.
  #
  # A rollup keeps running only while a person re-attests it within +reattest_interval_days+ (7, 30, 90 or 365;
  # 90 by default). Without #reattest it pauses when the interval ends (it is paused, not deleted).
  class AnalyticsRollups
    include DatasetSupport

    AGGS = %w[count last sum avg min max count_distinct p50 p95 p99].freeze

    def initialize(config)
      @config = config
    end

    # Create a rollup on +dataset_slug+. +slug+ names it, +source+ is the stream it folds, +measures+ is an Array of
    # { name:, agg:, column: } (up to 64; +agg+ is count, last, sum, avg, min, max, count_distinct, p50, p95 or p99;
    # +column+ is not used by count), +dimensions+ up to 16 column names, +window_seconds+ at least 60. Give exactly
    # one of +subject_field+ (per-subject data, suppressed below the cohort threshold) or +non_personal: true+.
    def create(dataset_slug, slug:, source:, measures:, window_seconds:, dimensions: nil, subject_field: nil,
               non_personal: nil, reattest_interval_days: nil)
      raise invalid('slug must be a String of 1 to 63 characters') unless slug.is_a?(String) && !slug.empty? && slug.length <= 63
      raise invalid('source must be a non-empty String') unless source.is_a?(String) && !source.empty?
      unless measures.is_a?(Array) && !measures.empty? && measures.size <= 64 && measures.all? { |m| m.is_a?(Hash) }
        raise invalid('measures must be an Array of 1 to 64 { name:, agg:, column: } Hashes')
      end
      unless window_seconds.is_a?(Integer) && window_seconds >= 60
        raise invalid('window_seconds must be a whole number of 60 or more', window_seconds: window_seconds)
      end
      if dimensions && !(dimensions.is_a?(Array) && dimensions.size <= 16)
        raise invalid('dimensions must be an Array of at most 16 column names')
      end
      if subject_field.nil? == (non_personal != true)
        raise invalid('give exactly one of subject_field or non_personal: true')
      end

      body = { 'slug' => slug, 'source' => source, 'measures' => stringify(measures), 'windowSeconds' => window_seconds }
      body['dimensions'] = dimensions unless dimensions.nil?
      body['subjectField'] = subject_field unless subject_field.nil?
      body['nonPersonal'] = true if non_personal == true
      days = reattest_days!(reattest_interval_days)
      body['reattestIntervalDays'] = days unless days.nil?
      call('POST', "analytics/#{seg(dataset_slug, 'dataset')}/rollups", body: body)
    end

    # The dataset's rollups with attestation state: +attestedAt+, +expiresAt+ and +attestationStatus+ ("active",
    # "expiring_soon" or "expired").
    def list(dataset_slug)
      call('GET', "analytics/#{seg(dataset_slug, 'dataset')}/rollups")
    end

    def delete(dataset_slug, rollup_id)
      call('DELETE', "analytics/#{seg(dataset_slug, 'dataset')}/rollups/#{seg(rollup_id, 'rollup')}")
    end

    # Confirm the rollup is still wanted: resets its attestation to now, optionally with a new interval, and resumes
    # an expired rollup. Only a person can do this: a service, workload or extension token gets 403 K9O_RBAC_DENY
    # with context reason "human_only" (raised as K9o::KError); a personal access token acts as its person.
    def reattest(dataset_slug, rollup_id, reattest_interval_days: nil)
      body = {}
      days = reattest_days!(reattest_interval_days)
      body['reattestIntervalDays'] = days unless days.nil?
      call('POST', "analytics/#{seg(dataset_slug, 'dataset')}/rollups/#{seg(rollup_id, 'rollup')}/reattest", body: body)
    end
  end

  # client.analytics.schedules: recurring materialization from a collection into a dataset. A schedule keeps running
  # only while a person re-attests it within +reattest_interval_days+; see #reattest.
  class AnalyticsSchedules
    include DatasetSupport

    def initialize(config)
      @config = config
    end

    # +interval_seconds+ is at least 60. Each run reads the collection with its creator's current access.
    def create(dataset_slug, from_collection:, interval_seconds:, reattest_interval_days: nil)
      unless from_collection.is_a?(String) && !from_collection.empty?
        raise invalid('from_collection must be a non-empty String')
      end
      unless interval_seconds.is_a?(Integer) && interval_seconds >= 60
        raise invalid('interval_seconds must be a whole number of 60 or more', interval_seconds: interval_seconds)
      end

      body = { 'fromCollection' => from_collection, 'intervalSeconds' => interval_seconds }
      days = reattest_days!(reattest_interval_days)
      body['reattestIntervalDays'] = days unless days.nil?
      call('POST', "analytics/#{seg(dataset_slug, 'dataset')}/schedules", body: body)
    end

    # The dataset's schedules with +lastRunAt+, +lastRunStatus+, +nextRunAt+ and attestation state.
    def list(dataset_slug)
      call('GET', "analytics/#{seg(dataset_slug, 'dataset')}/schedules")
    end

    def delete(dataset_slug, schedule_id)
      call('DELETE', "analytics/#{seg(dataset_slug, 'dataset')}/schedules/#{seg(schedule_id, 'schedule')}")
    end

    # Confirm the schedule is still wanted (a paused schedule resumes). Only a person can do this: a service,
    # workload or extension token gets 403 K9O_RBAC_DENY with context reason "human_only" (raised as K9o::KError).
    def reattest(dataset_slug, schedule_id, reattest_interval_days: nil)
      body = {}
      days = reattest_days!(reattest_interval_days)
      body['reattestIntervalDays'] = days unless days.nil?
      call('POST', "analytics/#{seg(dataset_slug, 'dataset')}/schedules/#{seg(schedule_id, 'schedule')}/reattest", body: body)
    end
  end

  # client.rollups: read the project's rollups.
  #
  #   list                                          GET /@<slug>/rollups
  #   read(rollup_slug, from:, to:, dims:)          GET /@<slug>/rollups/<slug>/read
  #   subscribe(rollup_slug, from_sequence:, on_resync:)  GET .../subscribe (server-sent events)
  class Rollups
    include DatasetSupport

    def initialize(config)
      @config = config
    end

    # Every rollup in the project whose dataset you can read, with its read and subscribe endpoints.
    def list
      call('GET', 'rollups')
    end

    # The rollup's cells for a time range. +from+ and +to+ are ISO 8601 strings or Times (the gateway defaults to the
    # last 24 hours; at most 50,000 cells). +dims+ is an Array or comma-separated String projecting dimensions (only
    # count, sum, min and max measures combine). A cell below the cohort threshold is { "status" => "suppressed",
    # "reason" => "cohort_below_k" }; +coverage+ says whether the range is complete.
    def read(rollup_slug, from: nil, to: nil, dims: nil)
      query = {}
      query['from'] = time_text(from) unless from.nil?
      query['to'] = time_text(to) unless to.nil?
      query['dims'] = dims.is_a?(Array) ? dims.join(',') : dims unless dims.nil?
      call('GET', "rollups/#{seg(rollup_slug, 'rollup')}/read", query: query)
    end

    # An Enumerator of closed cells, one per +cell+ frame. A frame wraps the cell as its +payload+; each cell
    # yielded is { "cellKey", "bucket", "dims", "final", "measures", "suppressed", "eventId" }. A cell below the cohort
    # threshold has no values: it is { "cellKey", "bucket", "status" => "suppressed", "reason" => "cohort_below_k",
    # "suppressed" => true }; for every other cell +suppressed+ is false. +eventId+ is the publisher's id for the frame.
    #
    # It reconnects with +Last-Event-ID+ (the frame's SSE +id+, the resume cursor), drops cells it already delivered
    # by +eventId+ (a resume re-sends the last 5 seconds), ignores the +:hb+ heartbeat (every 15 seconds) and reopens
    # when the gateway ends the connection (after at most 300 seconds). On +event: resync+ (action +reread-source+:
    # the position is lost, so re-read the rollup with #read) it calls +on_resync+ with { "reason", "action" } and
    # continues from a fresh connection. +from_sequence+ starts from a known position on the first connection. The
    # stream ends when the access token expires (the next connection is then refused 401). Stop with +break+ or
    # +first(n)+.
    def subscribe(rollup_slug, from_sequence: nil, on_resync: nil)
      unless from_sequence.nil? || (from_sequence.is_a?(Integer) && from_sequence >= 0)
        raise invalid('from_sequence must be a whole number, 0 or more', from_sequence: from_sequence)
      end

      path = route("rollups/#{seg(rollup_slug, 'rollup')}/subscribe")
      decode = lambda do |data, frame|
        next nil unless data.is_a?(Hash) && data['payload'].is_a?(Hash)
        next nil unless frame[:event].nil? || frame[:event] == 'cell' || data['eventType'] == 'cell'

        cell = data['payload'].dup
        cell['suppressed'] = cell['status'] == 'suppressed'
        cell['eventId'] = data['eventId'] if data['eventId'].is_a?(String)
        cell
      end
      keys = lambda do |cell, frame|
        id = cell['eventId'].is_a?(String) ? cell['eventId'] : (frame && frame[:id])
        id ? [id] : []
      end
      cursor = lambda do |cell, frame|
        (frame && frame[:id]) || cell['eventId']
      end
      Realtime.new(@config).feed(path, {}, from_sequence.nil? ? nil : { 'fromSequence' => from_sequence }, on_resync,
                                 decode: decode, keys: keys, cursor: cursor)
    end

    private

    def time_text(value)
      value.respond_to?(:iso8601) ? value.iso8601 : value.to_s
    end
  end
end
