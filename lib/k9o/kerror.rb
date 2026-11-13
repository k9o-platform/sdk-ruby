# frozen_string_literal: true

module K9o
  # KError — the closed-taxonomy error raised by every k9o surface
  # on non-2xx gateway responses or SDK-side validation failures.
  #
  # Ruby idiomatic shape: raise K9o::KError.
  # Code-narrowing: callers rescue K9o::KError and switch on e.code.
  class KError < StandardError
    attr_reader :code, :context, :recommendation, :status, :request_id
    # Seconds the gateway asks the caller to wait before retrying, or nil.
    # Informational: the SDK's own retry behaviour does not read it.
    attr_reader :retry_after_sec

    def initialize(code:, message:, context: {}, recommendation: nil, status: nil, request_id: nil,
                   retry_after_sec: nil)
      super(message)
      @code = code
      @message_text = message  # avoid infinite recursion in to_s (Exception#message calls to_s)
      @context = context.freeze
      @recommendation = recommendation
      @status = status
      @request_id = request_id
      @retry_after_sec = retry_after_sec
    end

    # The step-up challenge a 401 K9O_STEP_UP_REQUIRED carries (context.stepUp) as a K9o::Keys::StepUpChallenge
    # (+scope_set_root+, +nonce+, +min_tier+, +methods+, +max_age_sec+, +single_use+, +rp_id+), or nil.
    def step_up
      Keys::StepUp.challenge_from(@context)
    end

    def with_recommendation(rec)
      KError.new(
        code: @code, message: @message_text,
        context: @context, recommendation: rec,
        status: @status, request_id: @request_id,
        retry_after_sec: @retry_after_sec
      )
    end

    # Override message to return the raw text (Exception's default calls to_s
    # which causes infinite recursion since we override to_s).
    def message
      @message_text
    end

    def to_s
      @status ? "[#{@code}] #{@message_text} (status=#{@status})" : "[#{@code}] #{@message_text}"
    end

    # Rehydrate a wire KError payload into a typed K9o::KError.
    # +retry_after_header+ is the response's Retry-After header (whole seconds); it is used when the body's
    # recommendation carries no +retryAfterSec+. +request_id_header+ is the response's x-k9o-request-id header;
    # it is used when the body carries no request id.
    def self.from_wire(wire, status, retry_after_header: nil, request_id_header: nil)
      KError.new(
        code: wire['code'] || 'K9O_INTERNAL_ERROR',
        message: wire['message'] || '',
        context: wire['context'] || {},
        recommendation: recommendation_text(wire['recommendation']),
        status: status,
        request_id: wire['requestId'] || wire['request_id'] || request_id_from_header(request_id_header),
        retry_after_sec: retry_after(wire['recommendation']) || retry_after_from_header(retry_after_header)
      )
    end

    # The gateway's request id from the x-k9o-request-id header value, or nil when absent or blank.
    def self.request_id_from_header(value)
      return nil unless value.is_a?(String) && !value.strip.empty?

      value.strip
    end

    # Whole seconds from a Retry-After header value; an HTTP date or anything else gives nil.
    def self.retry_after_from_header(value)
      return nil unless value.is_a?(String) && value.strip.match?(/\A\d+\z/)

      value.strip.to_i
    end

    # The gateway sends `recommendation` as null, a string, or an object such
    # as {"action": "..."} or {"retryAfterSec": 30, "note": "..."}. A string is
    # kept; an object gives its `action`, else its `note`, when a string;
    # anything else gives nil.
    def self.recommendation_text(raw)
      return raw if raw.is_a?(String)
      return nil unless raw.is_a?(Hash)

      [raw['action'], raw['note']].find { |v| v.is_a?(String) }
    end

    # `retryAfterSec` from an object recommendation when a finite number >= 0.
    def self.retry_after(raw)
      return nil unless raw.is_a?(Hash)

      n = raw['retryAfterSec']
      return nil unless n.is_a?(Numeric) && !n.is_a?(Complex) && n >= 0
      return nil if n.respond_to?(:finite?) && !n.finite?

      n
    end
  end
end
