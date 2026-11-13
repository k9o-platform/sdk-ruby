# frozen_string_literal: true

module K9o
  # End users: k9o.end_users.*, the people who sign in to the project's own apps.
  #
  #   list(status:, q:, limit:, cursor:)       GET /@<slug>/end-users
  #   get(id)                                  GET /@<slug>/end-users/<id>
  #   role_grants.list(end_user_id:)           GET    /@<slug>/end-user-role-grants
  #   role_grants.grant(end_user_id:, role:)   POST   /@<slug>/end-user-role-grants
  #   role_grants.revoke(grant_id)             DELETE /@<slug>/end-user-role-grants/<grant_id>
  #
  # Listing and reading end users needs the project admin role. Role grants are created and revoked by project
  # admins; reading them is open to a wider set of project roles.
  class EndUsers
    STATUSES = %w[active locked deleted all].freeze

    attr_reader :role_grants

    def initialize(config)
      @config = config
      @role_grants = EndUserRoleGrants.new(config)
    end

    # End users, newest first, one page at a time. +status+ is active, locked, deleted or all (default: active and
    # locked); +q+ is an email prefix; +limit+ is 1 to 200 (default 50).
    def list(status: nil, q: nil, limit: nil, cursor: nil)
      ApprovalChecks.check_limit(limit)
      query = {}
      query['status'] = ApprovalChecks.enum!(status, STATUSES, 'status') unless status.nil?
      query['q'] = q unless q.nil?
      query['limit'] = limit unless limit.nil?
      query['cursor'] = cursor unless cursor.nil?
      HttpTransport.request(config: @config, method: 'GET', path: path('end-users'), query: query)
    end

    # One end user. An unknown id is a 404 K9O_END_USER_NOT_FOUND.
    def get(id)
      HttpTransport.request(config: @config, method: 'GET',
                            path: path("end-users/#{ApprovalChecks.id_segment(id, 'end user')}"))
    end

    private

    def path(tail)
      UrlGrammar.project_path(Studio.require_project_slug(@config, 'end_users'), tail)
    end
  end

  # A role is a free string (1 to 128 characters), not a fixed list.
  class EndUserRoleGrants
    def initialize(config)
      @config = config
    end

    # The active grants, oldest first. Not paginated. +data+ is the array of grants (the gateway wraps it in
    # { 'grants' => [...] }). An unknown +end_user_id+ answers an empty list.
    def list(end_user_id: nil)
      query = {}
      query['endUserId'] = end_user_id unless end_user_id.nil?
      unwrap(HttpTransport.request(config: @config, method: 'GET', path: path, query: query), 'grants')
    end

    # Give an end user a role; +data+ is the grant. Granting a role the user already holds is a 400
    # K9O_INVALID_FIELD_VALUE; an unknown end user is a 404 K9O_NOT_FOUND. A revoked role can be granted again.
    def grant(end_user_id:, role:)
      body = { 'endUserId' => text!(end_user_id, 'end_user_id', 64), 'role' => text!(role, 'role', 128) }
      unwrap(HttpTransport.request(config: @config, method: 'POST', path: path, body: body), 'grant')
    end

    # Revoke a grant (it is kept, marked revoked). +data+ is { 'revoked' => true|false, 'revokedAt' => ... }; an
    # unknown or already revoked id is not an error, it answers revoked false and revokedAt nil.
    def revoke(grant_id)
      HttpTransport.request(config: @config, method: 'DELETE',
                            path: path("/#{ApprovalChecks.id_segment(grant_id, 'grant')}"))
    end

    private

    def unwrap(envelope, key)
      Envelope.new(data: envelope.data.is_a?(Hash) ? envelope.data[key] : envelope.data, meta: envelope.meta)
    end

    def text!(value, what, max)
      return value if value.is_a?(String) && !value.empty? && value.length <= max

      raise ApprovalChecks.invalid("#{what} must be a string of 1 to #{max} characters")
    end

    def path(tail = '')
      UrlGrammar.project_path(Studio.require_project_slug(@config, 'end_users'), "end-user-role-grants#{tail}")
    end
  end
end
