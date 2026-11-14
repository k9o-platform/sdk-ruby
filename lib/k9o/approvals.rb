# frozen_string_literal: true

module K9o
  # Shared argument checks for the approvals, approval policy and schema namespaces. A bad value raises
  # K9o::KError K9O_INVALID_FIELD_VALUE before any request is sent.
  module ApprovalChecks
    module_function

    def invalid(message, context = {})
      KError.new(code: 'K9O_INVALID_FIELD_VALUE', message: message, context: context)
    end

    def check_limit(limit)
      return if limit.nil?
      return if limit.is_a?(Integer) && limit >= 1 && limit <= 200

      raise invalid('limit must be a whole number from 1 to 200', limit: limit)
    end

    def id_segment(value, what)
      raise invalid("#{what} id must be a non-empty string") unless value.is_a?(String) && !value.empty?

      ::URI.encode_www_form_component(value).gsub('+', '%20')
    end

    def reason!(reason)
      raise invalid('reason is required and must be a non-empty string') unless reason.is_a?(String) && !reason.strip.empty?

      reason
    end

    def predicate!(value, field)
      raise invalid("#{field} must be a predicate object") unless value.is_a?(Hash)

      value
    end

    def enum!(value, allowed, field)
      text = value.is_a?(Symbol) ? value.to_s : value
      return text if allowed.include?(text)

      raise invalid("#{field} must be #{allowed.map { |a| "\"#{a}\"" }.join(', ')}", field.to_sym => value)
    end
  end

  # True when a single-record write sent with +require_approval+ was queued for approval (HTTP 202) instead of
  # applied. The queued answer carries +data+ = { 'id' => 'apr_...', 'status' => 'pending_approval', 'collection',
  # 'operation', 'makerId', 'proposedPayload', 'targetRecordId' } and +meta.approval+ = { 'status' =>
  # 'pending_approval' }; an +auto_approve+ policy applies the write and answers the plain row instead.
  # Read the queued change in full with +approvals.get(id)+.
  def self.queued_write?(result)
    return false unless result.respond_to?(:data) && result.respond_to?(:meta)

    approval = result.meta.respond_to?(:approval) ? result.meta.approval : nil
    data = result.data
    approval.is_a?(Hash) && approval['status'] == 'pending_approval' &&
      data.is_a?(Hash) && data['status'] == 'pending_approval'
  end

  # Pending-change queue: k9o.approvals.*
  #
  #   list(status:, limit:, cursor:)       GET  /@<slug>/pending-approvals
  #   get(id)                              GET  /@<slug>/pending-approvals/<id>
  #   approve(id, reason:)                 POST /@<slug>/pending-approvals/<id>/approve
  #   reject(id, reason:)                  POST /@<slug>/pending-approvals/<id>/reject
  #   bulk(action:, criteria:, reason:)    POST /@<slug>/pending-approvals/bulk
  #
  # +list+ returns one page, newest first: +limit+ changes (1 to 200, default 50). While more remain,
  # +meta.cursor.next+ is a string to pass back as +cursor:+; on the last page it is +nil+. +approve+ can answer 200
  # with +status+ still +pending_approval+: the approval is recorded and more approvers are needed. +bulk+ answers
  # HTTP 200 even when rows fail; read +failed+ and compare +affectedIds+ with what you intended.
  class Approvals
    # The comment thread on a pending change: +approvals.comments+.
    attr_reader :comments

    def initialize(config)
      @config = config
      @comments = ApprovalComments.new(config)
    end

    # One page of pending changes, newest first. +status+ is one of pending_approval, approved, rejected, expired or
    # redeemed (omitted: all). Pass +meta.cursor.next+ from the previous page as +cursor+, with the same +status+
    # and +limit+; an invalid cursor raises K9o::KError K9O_INVALID_CURSOR.
    def list(status: nil, limit: nil, cursor: nil)
      ApprovalChecks.check_limit(limit)
      query = {}
      query['status'] = status.to_s unless status.nil?
      query['limit'] = limit unless limit.nil?
      query['cursor'] = cursor.to_s unless cursor.nil?
      call('GET', path, query: query)
    end

    # One pending change. Members who are not queue admins can read only their own.
    def get(id)
      call('GET', path("/#{ApprovalChecks.id_segment(id, 'approval')}"))
    end

    # Approve a pending change. Read +status+ on the answer: +pending_approval+ means more approvers are needed.
    def approve(id, reason: nil)
      seg = ApprovalChecks.id_segment(id, 'approval')
      call('POST', path("/#{seg}/approve"), body: reason.nil? ? {} : { 'reason' => reason })
    end

    # Reject a pending change. +reason+ is required and must not be empty.
    def reject(id, reason:)
      seg = ApprovalChecks.id_segment(id, 'approval')
      call('POST', path("/#{seg}/reject"), body: { 'reason' => ApprovalChecks.reason!(reason) })
    end

    # Approve or reject every pending change matching +criteria+ (a predicate Hash). +reason+ is required to reject.
    # The answer is HTTP 200 even when rows fail. +data+ holds +affectedIds+, +affectedCount+, +attestationId+,
    # +action+, +reason+ and +failed+, a list of { 'id', 'code', 'reason' } (empty when none failed): compare
    # +affectedIds+ with what you intended.
    def bulk(action:, criteria:, reason: nil)
      act = ApprovalChecks.enum!(action, %w[approve reject], 'action')
      body = { 'action' => act, 'criteria' => ApprovalChecks.predicate!(criteria, 'criteria') }
      if act == 'reject'
        body['reason'] = ApprovalChecks.reason!(reason)
      elsif !reason.nil?
        body['reason'] = reason
      end
      res = call('POST', path('/bulk'), body: body)
      res.data['failed'] = [] if res.data.is_a?(Hash) && !res.data['failed'].is_a?(Array)
      res
    end

    private

    def call(method, route, body: nil, query: nil)
      HttpTransport.request(config: @config, method: method, path: route, body: body, query: query)
    end

    def path(tail = '')
      UrlGrammar.project_path(Studio.require_project_slug(@config, 'approvals'), "pending-approvals#{tail}")
    end
  end

  # Comments on a pending change: k9o.approvals.comments.*
  #
  #   add(pending_id, body:, visibility:)   POST /@<slug>/pending-approvals/<pending_id>/comments
  #   list(pending_id, limit:, cursor:)     GET  /@<slug>/pending-approvals/<pending_id>/comments
  #
  # A comment is never a decision: it changes no status and counts toward no approval rule. It cannot be edited or
  # deleted, so a correction is a new comment. Posting needs a session: a personal access token alone, or a service,
  # workload or extension token, is refused with K9o::KError K9O_RBAC_DENY. Other errors: K9O_APPROVAL_COMMENT_NOT_ELIGIBLE
  # (403, the caller may not post this comment), K9O_APPROVAL_COMMENT_CLOSED (409, the change is decided, expired or
  # cancelled), K9O_INVALID_FIELD_VALUE (400) and K9O_NOT_FOUND (404, no such pending change).
  class ApprovalComments
    VISIBILITIES = %w[everyone approvers_only].freeze
    BODY_MAX = 4000

    # One page of comments: an Envelope whose +data+ is the Array of comments, oldest first, and whose +next_cursor+
    # is the +cursor:+ of the next page, or +nil+ on the last page.
    class Page < Envelope
      attr_reader :next_cursor

      def initialize(data:, meta:, next_cursor: nil)
        super(data: data, meta: meta)
        @next_cursor = next_cursor
      end
    end

    def initialize(config)
      @config = config
    end

    # Post a comment. +body+ is plain text of 1 to 4000 characters. +visibility+ is required and fixed once posted:
    # "everyone" reaches everyone who can read the change; "approvers_only" reaches only people eligible to decide it.
    # Answers HTTP 201; +data+ is { 'id' (acm_...), 'caseId', 'authorId', 'visibility', 'body', 'createdAt' }.
    def add(pending_id, body:, visibility:)
      seg = ApprovalChecks.id_segment(pending_id, 'pending approval')
      unless body.is_a?(String) && body.length >= 1 && body.length <= BODY_MAX
        raise ApprovalChecks.invalid("body must be a string of 1 to #{BODY_MAX} characters")
      end

      payload = { 'body' => body, 'visibility' => ApprovalChecks.enum!(visibility, VISIBILITIES, 'visibility') }
      call('POST', path(seg), body: payload)
    end

    # One page of the comments the caller may see, oldest first (+limit+ 1 to 200, default 50). While more remain,
    # +next_cursor+ is a string to pass back as +cursor:+; on the last page it is +nil+. An invalid cursor raises
    # K9o::KError K9O_INVALID_CURSOR.
    def list(pending_id, limit: nil, cursor: nil)
      seg = ApprovalChecks.id_segment(pending_id, 'pending approval')
      ApprovalChecks.check_limit(limit)
      query = {}
      query['limit'] = limit unless limit.nil?
      query['cursor'] = cursor.to_s unless cursor.nil?
      envelope = call('GET', path(seg), query: query, bare: true)
      raw = envelope.data
      data = raw.is_a?(Hash) && raw['data'].is_a?(Array) ? raw['data'] : []
      Page.new(data: data, meta: envelope.meta, next_cursor: raw.is_a?(Hash) ? raw['nextCursor'] : nil)
    end

    private

    def call(method, route, body: nil, query: nil, bare: false)
      HttpTransport.request(config: @config, method: method, path: route, body: body, query: query, bare: bare)
    end

    def path(seg)
      UrlGrammar.project_path(Studio.require_project_slug(@config, 'approvals'), "pending-approvals/#{seg}/comments")
    end
  end

  # Approval policies: k9o.approval_policies.*
  #
  #   list                                              GET    /@<slug>/approval-policies
  #   create(collection:, operation:, action:, predicate:)  POST   /@<slug>/approval-policies
  #   delete(id)                                        DELETE /@<slug>/approval-policies/<id>
  class ApprovalPolicies
    COLLECTION_RE = /\A[a-zA-Z_][a-zA-Z0-9_]{0,62}\z/.freeze

    def initialize(config)
      @config = config
    end

    # All policies, oldest first. The first matching policy for a write decides.
    def list
      call('GET', path)
    end

    # Create a policy. Identical policies are not de-duplicated.
    def create(collection:, operation:, action:, predicate:)
      unless collection.is_a?(String) && COLLECTION_RE.match?(collection)
        raise ApprovalChecks.invalid('collection must match ^[a-zA-Z_][a-zA-Z0-9_]{0,62}$', collection: collection)
      end

      body = {
        'collection' => collection,
        'operation' => ApprovalChecks.enum!(operation, %w[insert update delete], 'operation'),
        'action' => ApprovalChecks.enum!(action, %w[auto_approve queue], 'action'),
        'predicate' => ApprovalChecks.predicate!(predicate, 'predicate')
      }
      call('POST', path, body: body)
    end

    # Delete a policy; the answer is { 'id' => ... }.
    def delete(id)
      call('DELETE', path("/#{ApprovalChecks.id_segment(id, 'policy')}"))
    end

    private

    def call(method, route, body: nil)
      HttpTransport.request(config: @config, method: method, path: route, body: body)
    end

    def path(tail = '')
      UrlGrammar.project_path(Studio.require_project_slug(@config, 'approval_policies'), "approval-policies#{tail}")
    end
  end
end
