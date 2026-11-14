# frozen_string_literal: true

module K9o
  # The platform's canonical JSON form (the Kilimanjaro JCS code-point profile), implemented here with no dependency.
  #
  #   K9o::Jcs.canonicalize({ "b" => 2, "a" => [1, 3] })   # => '{"a":[1,3],"b":2}'
  #
  # Object members are sorted by UTF-8 byte order (the same as Unicode code-point order), there is no whitespace,
  # strings are escaped minimally (+"+ and +\+, the short escapes for backspace, tab, newline, form feed and carriage
  # return, every other control character as lowercase +\u00xx+; +/+ and every other character are written as they
  # are), and numbers are integers only: base 10, no exponent, +-0+ written +0+. A fractional number, NaN, an infinity
  # or an integer whose absolute value is above 2^53 - 1 raises, so a value that cannot be hashed identically
  # everywhere never gets a hash.
  module Jcs
    # Raised for a value that has no canonical form. +kind+ is :non_integer_number, :numeric_ceiling_exceeded or
    # :unsupported_value.
    class Error < ArgumentError
      attr_reader :kind

      def initialize(message, kind = :unsupported_value)
        super(message)
        @kind = kind
      end
    end

    ESCAPES = {
      '"' => '\\"', '\\' => '\\\\', "\b" => '\\b', "\t" => '\\t', "\n" => '\\n', "\f" => '\\f', "\r" => '\\r'
    }.freeze
    MAX_SAFE_INTEGER = 9_007_199_254_740_991

    module_function

    # The canonical form of +value+ as a UTF-8 String.
    def canonicalize(value)
      out = +''
      write(value, out)
      out.force_encoding(Encoding::UTF_8)
    end

    # The canonical form as bytes (UTF-8), the preimage to hash.
    def canonical_bytes(value)
      canonicalize(value).b
    end

    def write(value, out)
      case value
      when nil then out << 'null'
      when true then out << 'true'
      when false then out << 'false'
      when Integer then out << number(value)
      when Float then out << number(value)
      when String then write_string(value, out)
      when Symbol then write_string(value.to_s, out)
      when Array
        out << '['
        value.each_with_index do |item, index|
          out << ',' if index.positive?
          write(item, out)
        end
        out << ']'
      when Hash then write_object(value, out)
      else
        raise Error, "#{value.class} has no JSON form"
      end
    end

    def write_object(hash, out)
      members = hash.map { |key, val| [key.is_a?(Symbol) ? key.to_s : key, val] }
      members.each do |key, _|
        raise Error, 'object keys must be strings' unless key.is_a?(String)
      end
      keys = members.map(&:first)
      raise Error, 'object has duplicate keys' unless keys.uniq.size == keys.size

      sorted = members.sort_by { |key, _| key.b }
      out << '{'
      sorted.each_with_index do |(key, val), index|
        out << ',' if index.positive?
        write_string(key, out)
        out << ':'
        write(val, out)
      end
      out << '}'
    end

    def write_string(string, out)
      text = string.encoding == Encoding::UTF_8 ? string : string.encode(Encoding::UTF_8)
      raise Error, 'string is not valid UTF-8' unless text.valid_encoding?

      out << '"'
      text.each_char do |ch|
        if (esc = ESCAPES[ch])
          out << esc
        elsif ch.ord < 0x20
          out << format('\\u%04x', ch.ord)
        else
          out << ch
        end
      end
      out << '"'
    end

    # Integers only, within +/-(2^53 - 1). A float that is a whole number is written as that integer (a JSON reader
    # that parses +3.0+ sees the integer 3).
    def number(num)
      if num.is_a?(Float)
        raise Error.new('NaN and Infinity have no canonical form', :non_integer_number) unless num.finite?
        raise Error.new('a fractional number has no canonical form', :non_integer_number) unless num == num.floor

        num = num.to_i
      end
      raise Error.new("integer #{num} is above 2^53 - 1", :numeric_ceiling_exceeded) if num.abs > MAX_SAFE_INTEGER

      num.to_s
    end
  end
end
