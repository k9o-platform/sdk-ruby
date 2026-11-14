# frozen_string_literal: true

require 'json'
require 'digest'
require_relative 'jcs'
require_relative 'ed25519'

module K9o
  # Rampart: hosted classification of content. Advisory: it returns a verdict and a signed receipt and blocks
  # nothing. Your code decides what to do with the verdict.
  #
  #   classify(input, label: nil)                  POST /@<slug>/rampart/classify
  #   jwks                                          GET  /rampart/jwks  (public, no project prefix, no credential)
  #   verify_receipt(receipt, input, **options)     checks the receipt locally and returns the verified verdict
  #
  # +classify+ answers an Envelope whose +data+ is { 'classification' => "clear" | "suspicious" | "malicious",
  # 'riskScore', 'confidence' (both whole basis points, 0 to 10000), 'categories', 'calibrationVersion',
  # 'classificationReceipt', 'projectId' }; the receipt is the string exactly as received. When the classifier is down the
  # gateway answers 503 K9O_RAMPART_CLASSIFIER_UNAVAILABLE, raised as K9o::KError: there is no verdict and never a
  # default pass. A long input is scored in overlapping windows (the highest injection score decides); past 16
  # windows (about 6,000 tokens) the gateway answers 413 K9O_RAMPART_INPUT_TOO_LONG (context reason
  # "rampart_input_too_long"), also raised as K9o::KError, with no verdict.
  class Rampart
    RECEIPT_TYP = 'k9o.rampart.classify.v1'
    CLASSIFICATIONS = %w[clear suspicious malicious].freeze
    DEFAULT_CLOCK_SKEW = 60
    # The closed set of reasons verify_receipt refuses with, in the order it checks them.
    REASONS = %i[malformed key_unknown alg typ signature issuer project_unknown project expired not_yet_valid
                input_hash].freeze

    # Raised by verify_receipt for every failure. +reason+ is one of REASONS; no verdict is returned with it.
    # It is a K9o::KError, so +rescue K9o::KError+ catches it too.
    class ReceiptRefusal < KError
      attr_reader :reason

      def initialize(reason, detail)
        @reason = reason
        super(code: 'K9O_RAMPART_RECEIPT_REFUSED', message: "#{reason}: #{detail}", context: { reason: reason.to_s })
      end
    end

    # The claims of a receipt that passed every check. +windows+ is the number of windows the classifier scored (1 when
    # the input fits one window), or nil when the receipt carries no such claim. Claims this SDK does not know are
    # ignored.
    Verdict = Struct.new(:classification, :risk_bp, :confidence_bp, :categories, :project_id, :calibration_version,
                         :input_sha256, :issued_at, :expires_at, :kid, :windows, keyword_init: true)

    def initialize(config)
      @config = config
      @lock = Mutex.new
      @keys = nil
      @feed_issuer = nil
    end

    # Classify +input+ (a Hash). +label+ is optional context for the classifier, 1 to 128 characters.
    def classify(input, label: nil)
      raise invalid('input must be a Hash') unless input.is_a?(Hash)
      unless label.nil? || (label.is_a?(String) && label.length >= 1 && label.length <= 128)
        raise invalid('label must be a String of 1 to 128 characters')
      end

      slug = Studio.require_project_slug(@config, 'rampart')
      body = { 'input' => input }
      body['label'] = label unless label.nil?
      envelope = HttpTransport.request(config: @config, method: 'POST',
                                       path: UrlGrammar.project_path(slug, 'rampart/classify'), body: body)
      envelope
    end

    # The receipt key feed. +data+ is { 'keys' => [ { 'kid', 'kty', 'crv', 'x', ... } ], 'issuer' => "<issuer>/rampart" }.
    # Public: sends no credential.
    def jwks
      HttpTransport.request(config: @config, method: 'GET', path: UrlGrammar.platform_path('rampart/jwks'),
                            authenticated: false, bare: true)
    end

    # Verify a receipt against +input+ (the same Hash passed to classify) and return a Verdict read from the signed
    # claims. +receipt+ is either the Envelope classify returned (it carries the receipt and its +projectId+) or the
    # bare receipt String. Any failure raises ReceiptRefusal; there is never a partial verdict.
    #
    # Options:
    #   key_set:    a key set you already fetched (the Hash from +jwks.data+, or its Array of keys). Without it the keys
    #               are fetched from the feed, kept for the life of the client, and fetched once more on an unknown kid.
    #   issuer:     the expected +iss+. Default: the +issuer+ the key feed advertises. With neither, the receipt is
    #               refused with reason +issuer+.
    #   project_id: the expected +project_id+. Default: the +projectId+ carried by the classify result passed in. A
    #               bare receipt String with neither is refused with reason +project_unknown+.
    #   clock_skew: seconds of tolerance on +iat+ and +exp+ (default 60).
    #   clock:      a Time, a number of Unix seconds, or an object whose +call+ returns either. Default: the current time.
    def verify_receipt(receipt, input, key_set: nil, issuer: nil, project_id: nil, clock_skew: DEFAULT_CLOCK_SKEW,
                       clock: nil)
      receipt, carried_project = unpack_result(receipt)
      parts = split_receipt(receipt)
      header = decode_json(parts[0], 'header')
      claims = decode_json(parts[1], 'claims')
      signature = decode_b64(parts[2], 'signature')

      kid = header['kid']
      raise refuse(:malformed, 'header has no kid') unless kid.is_a?(String) && !kid.empty?

      jwk, feed_issuer = find_key(kid, key_set)
      raise refuse(:alg, "alg must be EdDSA, got #{header['alg'].inspect}") unless header['alg'] == 'EdDSA'
      raise refuse(:typ, "typ must be #{RECEIPT_TYP}, got #{header['typ'].inspect}") unless header['typ'] == RECEIPT_TYP

      public_key = decode_b64(jwk['x'].to_s, 'key')
      unless Ed25519.verify(public_key, "#{parts[0]}.#{parts[1]}", signature)
        raise refuse(:signature, 'the signature does not match the receipt')
      end

      expected_issuer = issuer || feed_issuer
      if expected_issuer.nil?
        raise refuse(:issuer, 'no issuer is advertised by the key feed and none was given; pass issuer:')
      end
      unless claims['iss'] == expected_issuer
        raise refuse(:issuer, "iss is #{claims['iss'].inspect}, expected #{expected_issuer}")
      end

      expected_project = project_id || carried_project
      if expected_project.nil?
        raise refuse(:project_unknown, 'no project id to compare with; pass the classify result or project_id:')
      end
      unless claims['project_id'].is_a?(String) && claims['project_id'] == expected_project
        raise refuse(:project, 'the receipt was issued for a different project')
      end

      check_times(claims, clock_skew, clock)
      unless claims['input_sha256'] == input_digest(input)
        raise refuse(:input_hash, 'the receipt does not attest this input')
      end

      build_verdict(claims, kid)
    end

    # SHA-256 of the canonical form (see Jcs) of +input+, as lowercase hex.
    def input_digest(input)
      raise ReceiptRefusal.new(:input_hash, 'input must be a Hash') unless input.is_a?(Hash)

      Digest::SHA256.hexdigest(Jcs.canonical_bytes(input))
    rescue Jcs::Error => e
      raise ReceiptRefusal.new(:input_hash, "the input cannot be canonicalised: #{e.message}")
    end

    private

    def invalid(message)
      ApprovalChecks.invalid(message, {})
    end

    def refuse(reason, detail)
      ReceiptRefusal.new(reason, detail)
    end

    # [receipt String, projectId carried by a classify result or nil].
    def unpack_result(value)
      data = value.respond_to?(:data) ? value.data : value
      return [value, nil] unless data.is_a?(Hash)

      carried = data['projectId']
      [data['classificationReceipt'], carried.is_a?(String) && !carried.empty? ? carried : nil]
    end

    def split_receipt(receipt)
      raise refuse(:malformed, 'receipt must be a String') unless receipt.is_a?(String)

      parts = receipt.split('.', -1)
      raise refuse(:malformed, 'receipt must have three dot-separated parts') unless parts.size == 3 && parts.none?(&:empty?)

      parts
    end

    def decode_b64(text, what)
      raise refuse(:malformed, "#{what} is not base64url") unless text.match?(/\A[A-Za-z0-9_-]+\z/)

      padded = text.tr('-_', '+/')
      padded += '=' * ((4 - (padded.length % 4)) % 4)
      padded.unpack1('m0')
    rescue ArgumentError
      raise refuse(:malformed, "#{what} is not base64url")
    end

    def decode_json(text, what)
      parsed = JSON.parse(decode_b64(text, what).force_encoding(Encoding::UTF_8))
      raise refuse(:malformed, "#{what} is not a JSON object") unless parsed.is_a?(Hash)

      parsed
    rescue JSON::ParserError, EncodingError
      raise refuse(:malformed, "#{what} is not JSON")
    end

    def normalise_keys(key_set)
      list = key_set.is_a?(Hash) ? (key_set['keys'] || key_set[:keys]) : key_set
      raise refuse(:key_unknown, 'the key set has no keys') unless list.is_a?(Array)

      list.each_with_object({}) do |jwk, out|
        next unless jwk.is_a?(Hash)

        jwk = jwk.transform_keys(&:to_s)
        out[jwk['kid']] = jwk if jwk['kid'].is_a?(String)
      end
    end

    # [the key for +kid+, the issuer the feed advertises or nil].
    def find_key(kid, key_set)
      keys, advertised = if key_set.nil?
                           cached_feed(kid)
                         else
                           [normalise_keys(key_set), feed_issuer_of(key_set)]
                         end
      jwk = keys[kid]
      raise refuse(:key_unknown, "no key with kid #{kid.inspect} in the key feed") if jwk.nil?
      unless jwk['kty'] == 'OKP' && jwk['crv'] == 'Ed25519' && jwk['x'].is_a?(String)
        raise refuse(:key_unknown, "key #{kid.inspect} is not an Ed25519 key")
      end

      [jwk, advertised]
    end

    def feed_issuer_of(feed)
      return nil unless feed.is_a?(Hash)

      value = feed['issuer'] || feed[:issuer]
      value.is_a?(String) && !value.empty? ? value : nil
    end

    # Keys and issuer kept for the client's life; one refetch when the kid is not among the keys.
    def cached_feed(kid)
      @lock.synchronize do
        if @keys.nil? || !@keys.key?(kid)
          feed = jwks.data
          @keys = normalise_keys(feed)
          @feed_issuer = feed_issuer_of(feed)
        end
        [@keys, @feed_issuer]
      end
    end

    def now_seconds(clock)
      value = clock.respond_to?(:call) ? clock.call : clock
      value = Time.now if value.nil?
      value.to_f
    end

    def check_times(claims, skew, clock)
      iat = claims['iat']
      exp = claims['exp']
      unless iat.is_a?(Numeric) && exp.is_a?(Numeric)
        raise refuse(:malformed, 'iat and exp must be numbers')
      end

      now = now_seconds(clock)
      raise refuse(:expired, 'the receipt has expired') if now > exp + skew
      raise refuse(:not_yet_valid, 'the receipt is issued in the future') if iat > now + skew
    end

    def build_verdict(claims, kid)
      cls = claims['classification']
      risk = claims['risk_bp']
      conf = claims['confidence_bp']
      cats = claims['categories']
      ok = CLASSIFICATIONS.include?(cls) &&
           [risk, conf].all? { |n| n.is_a?(Integer) && n >= 0 && n <= 10_000 } &&
           cats.is_a?(Array) && cats.all?(String) &&
           claims['calibration_version'].is_a?(String) && claims['input_sha256'].is_a?(String)
      raise refuse(:malformed, 'the signed claims are not a verdict') unless ok

      Verdict.new(classification: cls, risk_bp: risk, confidence_bp: conf, categories: cats.dup.freeze,
                  project_id: claims['project_id'], calibration_version: claims['calibration_version'],
                  input_sha256: claims['input_sha256'], issued_at: Time.at(claims['iat']).utc,
                  expires_at: Time.at(claims['exp']).utc, kid: kid,
                  windows: claims['windows'].is_a?(Integer) && claims['windows'] >= 1 ? claims['windows'] : nil)
    end
  end
end
