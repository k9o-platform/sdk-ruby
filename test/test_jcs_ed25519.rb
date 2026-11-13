# frozen_string_literal: true

require 'minitest/autorun'
require 'json'
require_relative '../lib/k9o'

# Canonical JSON profile vectors and RFC 8032 Ed25519 vectors.
class JcsEd25519Test < Minitest::Test
  def canon(value)
    K9o::Jcs.canonicalize(value)
  end

  CASES = JSON.parse(File.read(File.join(__dir__, 'fixtures', 'jcs-cases.json')))['cases']

  def test_every_shared_case
    refute_empty CASES
    CASES.each do |c|
      if c.key?('expectCanonical')
        assert_equal c['expectCanonical'], canon(c['input']), c['name']
      else
        e = assert_raises(K9o::Jcs::Error, c['name']) { canon(c['input']) }
        assert_equal c['expectError'], e.kind.to_s, c['name']
      end
    end
  end

  def test_integers_print_exactly
    assert_equal '0', canon(0)
    assert_equal '-7', canon(-7)
    assert_equal '9007199254740991', canon(2**53 - 1)
    assert_equal '0', canon(-0.0)
    assert_equal '3', canon(3.0)
  end

  def test_numbers_beyond_2_53_minus_1_and_fractions_are_refused
    [2**53, -(2**53), 10**21, 0.5, 1e30, 2.0**60].each do |bad|
      assert_raises(K9o::Jcs::Error) { canon([bad]) }
    end
  end

  def test_nan_and_infinity_are_rejected
    [Float::NAN, Float::INFINITY, -Float::INFINITY].each do |bad|
      assert_raises(K9o::Jcs::Error) { canon(bad) }
    end
    assert_raises(K9o::Jcs::Error) { canon('a' => Float::NAN) }
  end

  def test_unsupported_values_are_rejected
    assert_raises(K9o::Jcs::Error) { canon(Object.new) }
    assert_raises(K9o::Jcs::Error) { canon(1 => 2) }
    assert_raises(K9o::Jcs::Error) { canon("bad\xff") }
  end

  def test_keys_sort_by_utf8_bytes_not_utf16_units
    input = { "\u{1F600}" => 1, "\ufb00" => 2, 'a' => 3, "\u00f6" => 4 }
    assert_equal ['a', "\u00f6", "\ufb00", "\u{1F600}"], JSON.parse(canon(input)).keys
  end

  def test_string_escapes_and_no_whitespace
    assert_equal "\"\\b\\t\\n\\f\\r\\u0001\\u001f/\u007f\u00e9\"", canon("\b\t\n\f\r\u0001\u001f/\u007f\u00e9")
    assert_equal '{"a":[1,{"b":null}],"z":true}', canon(z: true, a: [1, { b: nil }])
  end

  def test_whole_json_numbers_round_trip_through_parse
    assert_equal '[1,100]', canon(JSON.parse('[1.0, 1e2]'))
  end

  # RFC 8032 section 7.1.
  VECTORS = [
    ['9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60',
     'd75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a', '',
     'e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b'],
    ['4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb',
     '3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c', '72',
     '92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00'],
    ['c5aa8df43f9f837bedb7442f31dcb7b166d38535076f094b85ce3a2e0b4458f7',
     'fc51cd8e6218a1a38da47ed00230f0580816ed13ba3303ac5deb911548908025', 'af82',
     '6291d657deec24024827e69c3abe01a30ce548a284743a445e3680d7db5ac3ac18ff9b538d16f290ae67f760984dc6594a7c15e9716ed28dc027beceea1ec40a']
  ].freeze

  def h(hex)
    [hex].pack('H*')
  end

  def test_rfc8032_vectors_pure
    VECTORS.each do |seed, pub, msg, sig|
      assert_equal h(pub), K9o::Ed25519::Pure.public_key(h(seed)), 'public key'
      assert_equal h(sig), K9o::Ed25519::Pure.sign(h(seed), h(msg)), 'signature'
      assert K9o::Ed25519::Pure.verify(h(pub), h(msg), h(sig))
    end
  end

  def test_rfc8032_vectors_through_verify
    VECTORS.each do |_seed, pub, msg, sig|
      assert K9o::Ed25519.verify(h(pub), h(msg), h(sig))
    end
  end

  def test_tampering_is_refused
    seed, pub, msg, sig = VECTORS[1]
    refute K9o::Ed25519.verify(h(pub), h(msg + '00'), h(sig))
    flipped = h(sig).dup
    flipped.setbyte(10, flipped.getbyte(10) ^ 1)
    refute K9o::Ed25519.verify(h(pub), h(msg), flipped)
    refute K9o::Ed25519::Pure.verify(h(pub), h(msg), flipped)
    other = K9o::Ed25519::Pure.public_key(h(VECTORS[0][0]))
    refute K9o::Ed25519.verify(other, h(msg), h(sig))
    assert seed
  end

  def test_scalar_not_below_group_order_is_refused
    _seed, pub, msg, sig = VECTORS[0]
    raw = h(sig)
    s = K9o::Ed25519::Pure.int_le(raw.byteslice(32, 32)) + K9o::Ed25519::L
    forged = raw.byteslice(0, 32) + K9o::Ed25519::Pure.le32(s)
    refute K9o::Ed25519.verify(h(pub), h(msg), forged)
  end

  def test_wrong_lengths_are_refused
    _seed, pub, msg, sig = VECTORS[0]
    refute K9o::Ed25519.verify(h(pub)[0, 31], h(msg), h(sig))
    refute K9o::Ed25519.verify(h(pub), h(msg), h(sig)[0, 63])
  end

  def test_native_openssl_agrees_with_pure_when_available
    skip 'this Ruby cannot verify Ed25519 with openssl' unless K9o::Ed25519.native?
    seed = h('11' * 32)
    pub = K9o::Ed25519::Pure.public_key(seed)
    sig = K9o::Ed25519::Pure.sign(seed, 'hello')
    assert K9o::Ed25519.verify_native(pub, 'hello', sig)
    refute K9o::Ed25519.verify_native(pub, 'hellp', sig)
  end
end
