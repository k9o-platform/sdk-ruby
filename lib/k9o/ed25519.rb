# frozen_string_literal: true

require 'openssl'

module K9o
  # Ed25519 signature verification (RFC 8032). Uses the openssl library when the Ruby in use can verify Ed25519, and
  # an in-process implementation (plain integer arithmetic) otherwise, so the answer never depends on the build of
  # OpenSSL underneath Ruby.
  module Ed25519
    P = (2**255) - 19
    L = (2**252) + 27_742_317_777_372_353_535_851_937_790_883_648_493
    D = (-121_665 * 121_666.pow(P - 2, P)) % P
    SQRT_M1 = 2.pow((P - 1) / 4, P)
    BASE_Y = (4 * 5.pow(P - 2, P)) % P

    module_function

    # True when +signature+ (64 bytes) is a valid Ed25519 signature of +message+ under +public_key+ (32 bytes).
    # Malformed input answers false.
    def verify(public_key, message, signature)
      public_key = public_key.b
      message = message.b
      signature = signature.b
      return false unless public_key.bytesize == 32 && signature.bytesize == 64

      if native?
        verify_native(public_key, message, signature)
      else
        Pure.verify(public_key, message, signature)
      end
    end

    # True when this Ruby's openssl can verify Ed25519 signatures.
    def native?
      return @native unless @native.nil?

      @native = begin
        OpenSSL::PKey.respond_to?(:new_raw_public_key) &&
          OpenSSL::PKey.new_raw_public_key('ED25519', ("\x00".b * 31) + "\x01".b).respond_to?(:verify)
      rescue StandardError
        false
      end
    end

    def verify_native(public_key, message, signature)
      OpenSSL::PKey.new_raw_public_key('ED25519', public_key).verify(nil, signature, message)
    rescue OpenSSL::PKey::PKeyError, ArgumentError
      false
    end

    # RFC 8032 section 5.1 in plain integers (extended coordinates).
    module Pure
      P = Ed25519::P
      L = Ed25519::L
      D = Ed25519::D
      IDENTITY = [0, 1, 1, 0].freeze

      module_function

      def verify(public_key, message, signature)
        a_point = decode_point(public_key)
        return false if a_point.nil?

        r_bytes = signature.byteslice(0, 32)
        s = int_le(signature.byteslice(32, 32))
        return false unless s < L
        return false if decode_point(r_bytes).nil?

        k = int_le(sha512(r_bytes + public_key + message)) % L
        # [s]B - [k]A must equal R.
        check = add(scalar_mult(base, s), scalar_mult(negate(a_point), k))
        encode_point(check) == r_bytes
      end

      # The 32-byte public key for a 32-byte seed. Exposed so tests can sign with a fresh key.
      def public_key(seed)
        encode_point(scalar_mult(base, expand(seed).first))
      end

      # A 64-byte signature of +message+ by +seed+. Exposed so tests can sign; callers verify with Ed25519.verify.
      def sign(seed, message)
        a, prefix = expand(seed)
        pub = encode_point(scalar_mult(base, a))
        r = int_le(sha512(prefix + message)) % L
        r_bytes = encode_point(scalar_mult(base, r))
        k = int_le(sha512(r_bytes + pub + message)) % L
        r_bytes + le32((r + (k * a)) % L)
      end

      def expand(seed)
        h = sha512(seed)
        a = int_le(h.byteslice(0, 32))
        a &= (1 << 254) - 8
        a |= 1 << 254
        [a, h.byteslice(32, 32)]
      end

      def sha512(data)
        OpenSSL::Digest::SHA512.digest(data)
      end

      def int_le(bytes)
        bytes.unpack('C*').each_with_index.sum { |byte, i| byte << (8 * i) }
      end

      def le32(int)
        Array.new(32) { |i| (int >> (8 * i)) & 0xff }.pack('C*')
      end

      def base
        x = recover_x(Ed25519::BASE_Y, 0)
        [x, Ed25519::BASE_Y, 1, (x * Ed25519::BASE_Y) % P]
      end

      def recover_x(y, sign)
        return nil if y >= P

        x2 = ((y * y) - 1) * ((D * y * y) + 1).pow(P - 2, P) % P
        if x2.zero?
          return sign.zero? ? 0 : nil
        end

        x = x2.pow((P + 3) / 8, P)
        x = (x * Ed25519::SQRT_M1) % P unless ((x * x) - x2) % P == 0
        return nil unless ((x * x) - x2) % P == 0

        x = P - x if (x & 1) != sign
        x
      end

      def decode_point(bytes)
        return nil unless bytes.bytesize == 32

        y = int_le(bytes)
        sign = y >> 255
        y &= (1 << 255) - 1
        x = recover_x(y, sign)
        return nil if x.nil?

        [x, y, 1, (x * y) % P]
      end

      def encode_point(point)
        x, y, z, = point
        zinv = z.pow(P - 2, P)
        xa = (x * zinv) % P
        ya = (y * zinv) % P
        le32(ya | ((xa & 1) << 255))
      end

      def add(p1, p2)
        x1, y1, z1, t1 = p1
        x2, y2, z2, t2 = p2
        a = ((y1 - x1) * (y2 - x2)) % P
        b = ((y1 + x1) * (y2 + x2)) % P
        c = (2 * t1 * t2 * D) % P
        d = (2 * z1 * z2) % P
        e = b - a
        f = d - c
        g = d + c
        h = b + a
        [(e * f) % P, (g * h) % P, (f * g) % P, (e * h) % P]
      end

      def negate(point)
        x, y, z, t = point
        [(-x) % P, y, z, (-t) % P]
      end

      def scalar_mult(point, scalar)
        result = IDENTITY
        addend = point
        while scalar.positive?
          result = add(result, addend) if scalar.odd?
          addend = add(addend, addend)
          scalar >>= 1
        end
        result
      end
    end
  end
end
