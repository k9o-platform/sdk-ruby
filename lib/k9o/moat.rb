# frozen_string_literal: true

require 'json'
require 'digest'

module K9o
  # Moat: a local guard around one model call. It runs in your process; it makes no network calls, needs no account
  # and uses no other part of this SDK.
  #
  #   moat = K9o::Moat.new(
  #     prompt: "Summarise the ticket in one sentence.",
  #     input_schema: { "type" => "string", "maxLength" => 4000 },
  #     output_schema: { "type" => "object", "required" => ["summary"], "properties" => { "summary" => { "type" => "string" } } },
  #     filters: { pii: ->(text) { barbican.inspect(text).decision == "deny" } }
  #   )
  #   messages = moat.messages(ticket_text)   # [{ role: "system", ... }, { role: "user", ... }] or raises Refusal
  #   value = moat.check_output(model_text)   # the parsed, validated value or raises Refusal
  #
  # It does four things:
  #
  # 1. Pins the system prompt. Moat builds the message list itself: the prompt is always the +system+ message and the
  #    untrusted input is always a +user+ message. Input that carries a role or system marker is refused. The pin is
  #    structural: it stops injected text from becoming the system prompt. It does not stop that text reaching the
  #    model, so keep +output_schema+ and the checks on what your code does with the answer.
  # 2. Checks the input against +input_schema+ before it goes into a message.
  # 3. Checks the model output against +output_schema+.
  # 4. Runs the optional +pii+ filter over the output.
  #
  # A refusal is an exception: Moat::Refusal, with a +reason+ from the closed set REASONS and a short +detail+ that
  # never repeats the input or the output.
  module Moat
    REASONS = %i[role_marker input_schema output_schema pii].freeze

    # Raised when Moat refuses input or output. +reason+ is one of REASONS.
    class Refusal < StandardError
      attr_reader :reason, :detail

      def initialize(reason, detail)
        @reason = reason
        @detail = detail
        super("#{reason}: #{detail}")
      end
    end

    # Raised at construction for a bad prompt, filter or schema.
    class ConfigError < ArgumentError; end

    # Raised at construction when a schema uses a keyword outside the supported subset.
    class SchemaError < ConfigError; end

    # Build a Guard. See Guard#initialize.
    def self.new(**options)
      Guard.new(**options)
    end

    # The JSON Schema subset Moat understands, and nothing else.
    module Schema
      TYPES = %w[object array string number integer boolean null].freeze
      KEYWORDS = %w[type properties required additionalProperties items enum const minLength maxLength pattern
                    minimum maximum minItems maxItems].freeze

      module_function

      # Raise SchemaError unless +schema+ uses only the supported keywords with well-formed values.
      def check_schema!(schema, path = '$')
        raise SchemaError, "#{path}: a schema must be a Hash" unless schema.is_a?(Hash)

        schema.each_key do |key|
          unless KEYWORDS.include?(key.to_s)
            raise SchemaError, "#{path}: unsupported keyword #{key.to_s.inspect}; supported: #{KEYWORDS.join(', ')}"
          end
        end
        s = stringify(schema)
        check_type!(s['type'], path) if s.key?('type')
        check_properties!(s['properties'], path) if s.key?('properties')
        check_required!(s['required'], path) if s.key?('required')
        if s.key?('additionalProperties') && ![true, false].include?(s['additionalProperties'])
          raise SchemaError, "#{path}.additionalProperties must be true or false"
        end
        check_schema!(s['items'], "#{path}.items") if s.key?('items')
        raise SchemaError, "#{path}.enum must be a non-empty Array" if s.key?('enum') && !(s['enum'].is_a?(Array) && !s['enum'].empty?)

        %w[minLength maxLength minItems maxItems].each do |kw|
          next unless s.key?(kw)

          raise SchemaError, "#{path}.#{kw} must be a whole number >= 0" unless s[kw].is_a?(Integer) && s[kw] >= 0
        end
        %w[minimum maximum].each do |kw|
          next unless s.key?(kw)

          raise SchemaError, "#{path}.#{kw} must be a number" unless s[kw].is_a?(Numeric) && s[kw].to_f.finite?
        end
        check_pattern!(s['pattern'], path) if s.key?('pattern')
        true
      end

      def stringify(schema)
        schema.transform_keys(&:to_s)
      end

      def check_type!(type, path)
        list = type.is_a?(Array) ? type : [type]
        ok = !list.empty? && list.all? { |t| t.is_a?(String) && TYPES.include?(t) }
        raise SchemaError, "#{path}.type must be one of #{TYPES.join(', ')} (or a list of them)" unless ok
      end

      def check_properties!(props, path)
        raise SchemaError, "#{path}.properties must be a Hash of schemas" unless props.is_a?(Hash)

        props.each { |name, sub| check_schema!(sub, "#{path}.properties.#{name}") }
      end

      def check_required!(required, path)
        ok = required.is_a?(Array) && required.all? { |r| r.is_a?(String) || r.is_a?(Symbol) }
        raise SchemaError, "#{path}.required must be an Array of names" unless ok
      end

      def check_pattern!(pattern, path)
        raise SchemaError, "#{path}.pattern must be a String" unless pattern.is_a?(String)

        Regexp.new(pattern)
      rescue RegexpError => e
        raise SchemaError, "#{path}.pattern is not a valid regular expression: #{e.message}"
      end

      # nil when +value+ (JSON data) satisfies +schema+, else a short description of the first failure.
      def violation(schema, value, path = '$')
        s = stringify(schema)
        if s.key?('type') && !type_ok?(s['type'], value)
          return "#{path}: expected #{Array(s['type']).join(' or ')}"
        end
        return "#{path}: not one of the allowed values" if s.key?('enum') && s['enum'].none? { |e| same?(e, value) }
        return "#{path}: not the required constant" if s.key?('const') && !same?(s['const'], value)

        case value
        when String then string_violation(s, value, path)
        when Numeric then number_violation(s, value, path)
        when Array then array_violation(s, value, path)
        when Hash then object_violation(s, value, path)
        end
      end

      def type_ok?(type, value)
        Array(type).any? do |t|
          case t
          when 'object' then value.is_a?(Hash)
          when 'array' then value.is_a?(Array)
          when 'string' then value.is_a?(String)
          when 'number' then value.is_a?(Numeric)
          when 'integer' then value.is_a?(Integer) || (value.is_a?(Float) && value.finite? && value == value.floor)
          when 'boolean' then value == true || value == false
          when 'null' then value.nil?
          end
        end
      end

      def same?(left, right)
        return false unless left.class == right.class || (left.is_a?(Numeric) && right.is_a?(Numeric))

        case left
        when Hash
          left = left.transform_keys(&:to_s)
          left.size == right.size && left.all? { |k, v| right.key?(k) && same?(v, right[k]) }
        when Array
          left.size == right.size && left.each_with_index.all? { |v, i| same?(v, right[i]) }
        else
          left == right
        end
      end

      def string_violation(s, value, path)
        return "#{path}: shorter than minLength" if s['minLength'] && value.length < s['minLength']
        return "#{path}: longer than maxLength" if s['maxLength'] && value.length > s['maxLength']
        return "#{path}: does not match pattern" if s['pattern'] && !Regexp.new(s['pattern']).match?(value)

        nil
      end

      def number_violation(s, value, path)
        return "#{path}: below minimum" if s['minimum'] && value < s['minimum']
        return "#{path}: above maximum" if s['maximum'] && value > s['maximum']

        nil
      end

      def array_violation(s, value, path)
        return "#{path}: fewer than minItems" if s['minItems'] && value.size < s['minItems']
        return "#{path}: more than maxItems" if s['maxItems'] && value.size > s['maxItems']
        return nil unless s['items']

        value.each_with_index do |item, index|
          found = violation(s['items'], item, "#{path}[#{index}]")
          return found if found
        end
        nil
      end

      def object_violation(s, value, path)
        props = (s['properties'] || {}).transform_keys(&:to_s)
        Array(s['required']).map(&:to_s).each do |name|
          return "#{path}.#{name}: required" unless value.key?(name)
        end
        value.each do |name, item|
          if props.key?(name)
            found = violation(props[name], item, "#{path}.#{name}")
            return found if found
          elsif s['additionalProperties'] == false
            return "#{path}.#{name}: not allowed"
          end
        end
        nil
      end
    end

    # Detects role and system markers in untrusted input.
    module Markers
      # Default-ignorable and format code points, removed before matching (one shared table, code point ranges).
      IGNORABLE_RANGES = [
        0x00AD..0x00AD, 0x034F..0x034F, 0x061C..0x061C, 0x115F..0x1160, 0x17B4..0x17B5, 0x180B..0x180F,
        0x200B..0x200F, 0x202A..0x202E, 0x2060..0x206F, 0x3164..0x3164, 0xFE00..0xFE0F, 0xFEFF..0xFEFF,
        0xFFA0..0xFFA0, 0xFFF0..0xFFF8, 0x1BCA0..0x1BCA3, 0x1D173..0x1D17A, 0xE0000..0xE0FFF
      ].freeze
      IGNORABLE = Regexp.new(
        '[' + IGNORABLE_RANGES.map { |r| format('\\u{%X}-\\u{%X}', r.first, r.last) }.join + ']'
      ).freeze
      # Cyrillic and Greek look-alikes of the marker letters -> Latin letter (code point escapes; mirrors
      # test/fixtures/moat-confusables.json, which a test compares against). Not general homoglyph detection.
      CONFUSABLES = {
        "\u{0430}" => 'a',
        "\u{0410}" => 'a',
        "\u{0441}" => 'c',
        "\u{0421}" => 'c',
        "\u{0435}" => 'e',
        "\u{0415}" => 'e',
        "\u{0456}" => 'i',
        "\u{0406}" => 'i',
        "\u{043E}" => 'o',
        "\u{041E}" => 'o',
        "\u{0440}" => 'p',
        "\u{0420}" => 'p',
        "\u{0455}" => 's',
        "\u{0405}" => 's',
        "\u{0443}" => 'y',
        "\u{0423}" => 'y',
        "\u{0501}" => 'd',
        "\u{04CF}" => 'l',
        "\u{04C0}" => 'l',
        "\u{0422}" => 't',
        "\u{041C}" => 'm',
        "\u{041D}" => 'h',
        "\u{0445}" => 'x',
        "\u{0425}" => 'x',
        "\u{0391}" => 'a',
        "\u{03B1}" => 'a',
        "\u{0395}" => 'e',
        "\u{03B5}" => 'e',
        "\u{0399}" => 'i',
        "\u{03B9}" => 'i',
        "\u{039F}" => 'o',
        "\u{03BF}" => 'o',
        "\u{03A1}" => 'p',
        "\u{03C1}" => 'p',
        "\u{03A4}" => 't',
        "\u{03C4}" => 't',
        "\u{03A5}" => 'y',
        "\u{03C5}" => 'u',
        "\u{03BD}" => 'v',
        "\u{039C}" => 'm',
        "\u{039D}" => 'n',
        "\u{03A7}" => 'x',
        "\u{03C7}" => 'x',
        "\u{03F2}" => 'c',
        "\u{03F9}" => 'c',
        "\u{0397}" => 'h',
        "\u{0442}" => 't'
      }.freeze
      CONFUSABLES_RE = Regexp.new("[" + CONFUSABLES.keys.join + "]").freeze
      MARKS = /[\p{Mn}\p{Me}]/.freeze
      HORIZONTAL_SPACE = /[\t\p{Zs}]+/.freeze
      LINE_ROLE = /^[ \t]*(system|assistant|developer|tool|user)[ \t]*:/.freeze
      STRINGS = ['<|system|>', '<|im_start|>', '<|im_end|>', '[inst]', '<<sys>>'].freeze
      HEADINGS = /###[ \t]*(system|instruction)/.freeze
      JSON_ROLE = /"role"\s*:\s*"\s*(system|developer|assistant)\s*"/.freeze
      ROLE_VALUES = %w[system developer assistant].freeze

      module_function

      # The name of the first marker found anywhere in +value+ (JSON data), or nil.
      def find(value)
        case value
        when String then in_text(value)
        when Array then value.lazy.map { |item| find(item) }.find { |found| found }
        when Hash then in_hash(value)
        end
      end

      def in_hash(hash)
        hash.each do |key, item|
          if normalise(key.to_s) == 'role' && item.is_a?(String) && ROLE_VALUES.include?(normalise(item).strip)
            return 'a role object'
          end
          found = find(key.to_s) || find(item)
          return found if found
        end
        nil
      end

      def in_text(text)
        t = normalise(text)
        return 'a role line' if t.match?(LINE_ROLE)
        return 'a chat-template marker' if STRINGS.any? { |m| t.include?(m) }
        return 'a heading marker' if t.match?(HEADINGS)
        return 'a role object' if t.match?(JSON_ROLE)

        nil
      end

      def normalise(text)
        nfkc = text.to_s.dup.force_encoding(Encoding::UTF_8).scrub('').unicode_normalize(:nfkc)
        nfkc.unicode_normalize(:nfkd).gsub(MARKS, '').gsub(IGNORABLE, '')
            .gsub(CONFUSABLES_RE, CONFUSABLES).downcase(:fold).gsub(HORIZONTAL_SPACE, ' ')
      end
    end

    class Guard
      # +prompt+: the pinned system prompt (a non-empty String).
      # +input_schema+ / +output_schema+: optional schemas in the subset (see Schema); anything else raises SchemaError.
      # +filters+: optional { pii: callable }. The callable gets the output as text and returns a truthy value when it
      # finds personal data; its return value is not repeated in the refusal. An error inside it also refuses.
      def initialize(prompt:, input_schema: nil, output_schema: nil, filters: nil)
        raise ConfigError, 'prompt must be a non-empty String' unless prompt.is_a?(String) && !prompt.strip.empty?

        Schema.check_schema!(input_schema, 'input_schema') unless input_schema.nil?
        Schema.check_schema!(output_schema, 'output_schema') unless output_schema.nil?
        @prompt = prompt.dup.freeze
        @input_schema = input_schema
        @output_schema = output_schema
        @pii = pii_filter(filters)
      end

      # The message list for one model call: the pinned prompt as +system+, the untrusted input as +user+ text.
      # Raises Refusal (:role_marker or :input_schema).
      def messages(untrusted_input)
        data = json_data(untrusted_input, :input_schema, 'input is not JSON data')
        marker = Markers.find(data)
        raise Refusal.new(:role_marker, "the input contains #{marker}") if marker

        check_schema(@input_schema, data, :input_schema)
        text = data.is_a?(String) ? data : JSON.generate(data)
        [{ role: 'system', content: @prompt }, { role: 'user', content: text }].freeze
      end

      # The validated, filtered model output. A String is parsed as JSON unless the output schema's type is "string".
      # Raises Refusal (:output_schema or :pii).
      def check_output(model_output)
        value = parse_output(model_output)
        check_schema(@output_schema, value, :output_schema)
        run_pii(value)
        value
      end

      # Lowercase hex SHA-256 of the pinned prompt, so you can pass it to Rampart or record it.
      def prompt_sha256
        Digest::SHA256.hexdigest(@prompt.b)
      end

      private

      def pii_filter(filters)
        return nil if filters.nil?
        raise ConfigError, 'filters must be a Hash' unless filters.is_a?(Hash)

        named = filters.transform_keys(&:to_s)
        unknown = named.keys - ['pii']
        raise ConfigError, "unknown filter #{unknown.first.inspect}; supported: pii" unless unknown.empty?

        callable = named['pii']
        return nil if callable.nil?
        raise ConfigError, 'filters[:pii] must respond to call' unless callable.respond_to?(:call)

        callable
      end

      # +value+ as plain JSON data (string keys), or a Refusal when it holds anything JSON cannot.
      def json_data(value, reason, detail)
        plain(value)
      rescue TypeError, EncodingError
        raise Refusal.new(reason, detail)
      end

      def plain(value)
        case value
        when nil, true, false, String then value
        when Symbol then value.to_s
        when Integer then value
        when Float
          raise TypeError, 'not finite' unless value.finite?

          value
        when Array then value.map { |item| plain(item) }
        when Hash
          value.each_with_object({}) do |(key, item), out|
            raise TypeError, 'keys must be strings' unless key.is_a?(String) || key.is_a?(Symbol)

            out[key.to_s] = plain(item)
          end
        else
          raise TypeError, 'not JSON data'
        end
      end

      def parse_output(model_output)
        string_schema = @output_schema && Schema.stringify(@output_schema)['type'] == 'string'
        return model_output unless model_output.is_a?(String) && @output_schema && !string_schema

        JSON.parse(model_output)
      rescue JSON::ParserError
        raise Refusal.new(:output_schema, 'the output is not valid JSON')
      end

      def check_schema(schema, value, reason)
        return if schema.nil?

        found = Schema.violation(schema, value)
        raise Refusal.new(reason, found) if found
      end

      def run_pii(value)
        return if @pii.nil?

        text = value.is_a?(String) ? value : JSON.generate(value)
        flagged = begin
          @pii.call(text)
        rescue StandardError => e
          raise Refusal.new(:pii, "the PII filter failed (#{e.class}), so the output is withheld")
        end
        return if flagged.nil? || flagged == false || (flagged.respond_to?(:empty?) && flagged.empty?)

        raise Refusal.new(:pii, 'the PII filter flagged the output')
      end
    end
  end
end
