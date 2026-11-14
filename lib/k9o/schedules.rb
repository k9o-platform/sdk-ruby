# frozen_string_literal: true

module K9o
  # Schedules: k9o.schedules.* run a function on a timetable (cron). They need the project admin role to change.
  #
  #   list(status:, function_name:, limit:, cursor:)    GET    /@<slug>/forge/schedules
  #   get(id)                                           GET    /@<slug>/forge/schedules/<id>
  #   create(function_name:, schedule_expression:, ...) POST   /@<slug>/forge/schedules
  #   update(id, **fields)                              PATCH  /@<slug>/forge/schedules/<id>
  #   delete(id)                                        DELETE /@<slug>/forge/schedules/<id>   (204, no body)
  #   runs(id, limit:, cursor:)                         GET    /@<slug>/forge/schedules/<id>/runs
  #   run_now(id)                                       POST   /@<slug>/forge/schedules/<id>/run-now   (202)
  #
  # Lists are cursor-paginated, newest first: pass +meta.cursor.next+ of one page as +cursor:+ of the next, until it
  # is nil. A schedule interval under 5 minutes is rejected with 400 K9O_INVALID_FIELD_VALUE (field schedule_expression), on every plan.
  class Schedules
    CATCHUP_POLICIES = %w[skip run_once run_all].freeze
    STATUSES = %w[active paused].freeze
    UPDATE_FIELDS = %i[schedule_expression schedule_timezone catchup_policy status enabled log_ok_invocations].freeze

    def initialize(config)
      @config = config
    end

    # Schedules, newest first. +status+ is active or paused; +function_name+ keeps one function's schedules;
    # +limit+ is 1 to 200 (the gateway defaults to 50).
    def list(status: nil, function_name: nil, limit: nil, cursor: nil)
      ApprovalChecks.check_limit(limit)
      query = {}
      query['status'] = ApprovalChecks.enum!(status, STATUSES, 'status') unless status.nil?
      query['function_name'] = function_name unless function_name.nil?
      query['limit'] = limit unless limit.nil?
      query['cursor'] = cursor unless cursor.nil?
      call('GET', path, query: query)
    end

    def get(id)
      call('GET', path(one(id)))
    end

    # Create a schedule; answers 201 with the schedule. +schedule_expression+ is a five-field cron or one of @yearly,
    # @annually, @monthly, @weekly, @daily, @midnight, @hourly (stored and returned expanded). +schedule_timezone+
    # defaults to UTC; +catchup_policy+ to skip.
    def create(function_name:, schedule_expression:, schedule_timezone: nil, catchup_policy: nil, collection: nil,
               enabled: nil, log_ok_invocations: nil)
      body = { 'functionName' => function_name, 'scheduleExpression' => schedule_expression }
      body['scheduleTimezone'] = schedule_timezone unless schedule_timezone.nil?
      body['catchupPolicy'] = ApprovalChecks.enum!(catchup_policy, CATCHUP_POLICIES, 'catchup_policy') unless catchup_policy.nil?
      body['collection'] = collection unless collection.nil?
      body['enabled'] = enabled unless enabled.nil?
      body['logOkInvocations'] = log_ok_invocations unless log_ok_invocations.nil?
      call('POST', path, body: body)
    end

    # Change a schedule; send at least one of +schedule_expression+, +schedule_timezone+, +catchup_policy+,
    # +status+ ('paused' stops it, 'active' resumes it), +enabled+, +log_ok_invocations+. The function cannot change.
    def update(id, **fields)
      unknown = fields.keys - UPDATE_FIELDS
      raise ApprovalChecks.invalid("unknown field: #{unknown.join(', ')}") unless unknown.empty?
      raise ApprovalChecks.invalid("patch needs at least one of: #{UPDATE_FIELDS.join(', ')}") if fields.empty?

      seg = one(id)
      body = {}
      body['scheduleExpression'] = fields[:schedule_expression] if fields.key?(:schedule_expression)
      body['scheduleTimezone'] = fields[:schedule_timezone] if fields.key?(:schedule_timezone)
      if fields.key?(:catchup_policy)
        body['catchupPolicy'] = ApprovalChecks.enum!(fields[:catchup_policy], CATCHUP_POLICIES, 'catchup_policy')
      end
      body['status'] = ApprovalChecks.enum!(fields[:status], STATUSES, 'status') if fields.key?(:status)
      body['enabled'] = fields[:enabled] if fields.key?(:enabled)
      body['logOkInvocations'] = fields[:log_ok_invocations] if fields.key?(:log_ok_invocations)
      call('PATCH', path(seg), body: body)
    end

    # Delete a schedule. Answers 204, so +data+ is nil.
    def delete(id)
      call('DELETE', path(one(id)))
    end

    # The schedule's runs, newest first, one page at a time.
    def runs(id, limit: nil, cursor: nil)
      ApprovalChecks.check_limit(limit)
      seg = one(id)
      query = {}
      query['limit'] = limit unless limit.nil?
      query['cursor'] = cursor unless cursor.nil?
      call('GET', path("#{seg}/runs"), query: query)
    end

    # Start one run now, outside the timetable. Answers 202; +data+ is the body exactly as the gateway sent it.
    def run_now(id)
      call('POST', path("#{one(id)}/run-now"))
    end

    private

    def one(id)
      "/#{ApprovalChecks.id_segment(id, 'schedule')}"
    end

    def call(method, route, body: nil, query: nil)
      HttpTransport.request(config: @config, method: method, path: route, body: body, query: query)
    end

    def path(tail = '')
      UrlGrammar.project_path(Studio.require_project_slug(@config, 'schedules'), "forge/schedules#{tail}")
    end
  end
end
