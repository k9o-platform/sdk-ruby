# frozen_string_literal: true

require_relative 'kerror'

module K9o
  # The bound Kibo core for K9o::KiboClientCore: it hands the SDK's plain Hashes and Strings to the generated uniffi
  # binding (+KiboKmsRestFfi+, zk-bundle-v2.16.3 or later) as the typed records, integer enums and federation variant
  # the binding wants, and turns the binding's errors into the SDK's "CODE: detail" form. There is no cryptography here:
  # sealing, opening, the key pin and the token exchange all run in the native core. Requiring +k9o+ does not load the
  # binding; building this object does, and raises a K9o::KError saying what is missing when it cannot.
  #
  #   core = K9o::KiboFfiCore.new                                    # binding and library on the default paths
  #   core = K9o::KiboFfiCore.new(library: '/opt/kibo/libkibo_kms_rest_ffi.so')  # library at an absolute path
  #
  # The generated binding opens the native library by its bare name, +kibo_kms_rest_ffi+. Ruby's +ffi+ gem looks for it in
  # the system library paths (+/opt/homebrew/lib+, +/opt/local/lib+, +/usr/local/lib+, +/usr/lib+, and on Linux the
  # loader paths such as +LD_LIBRARY_PATH+). macOS does not pass +DYLD_LIBRARY_PATH+ to the system Ruby, so on macOS put
  # the library in one of those directories or pass +library:+ with its absolute path. +library:+ makes this adapter load
  # the binding with that path in place of the bare name; the binding file itself is not changed.
  class KiboFfiCore
    # Raised from the binding's errors. The message is "<CODE>: <detail>", which KiboClientCore turns into the item's
    # code and message.
    class CoreError < StandardError; end

    PROVIDERS = { 'aws-kms' => :AWS_KMS, 'gcp-kms' => :GCP_KMS, 'azure-kv' => :AZURE_KV,
                  'hashicorp-vault' => :HASHICORP_VAULT }.freeze
    POSTURES = { 'byok' => :BYOK, 'hyok' => :HYOK }.freeze
    BINDING_LIB_LINE = /^(\s*)ffi_lib\s+'kibo_kms_rest_ffi'\s*$/.freeze
    REQUIRED = %i[app_crypto_seal_blocking app_crypto_open_blocking acquire_kms_credential_blocking
                  core_capabilities].freeze

    # +library+: absolute path of the native library, for a library that is not on the default paths.
    # +binding_path+: path of the generated +kibo_kms_rest_ffi.rb+, when it is not on the load path. Needed only if
    #   +KiboKmsRestFfi+ is not already loaded and +require 'kibo_kms_rest_ffi'+ would not find it.
    # +ffi+: the binding module itself, when you have already loaded it under another name.
    def initialize(library: nil, binding_path: nil, ffi: nil)
      @ffi = ffi || load_binding(library, binding_path)
      REQUIRED.each do |fn|
        next if @ffi.respond_to?(fn)

        raise unavailable("the loaded KiboKmsRestFfi does not export #{fn}; it is older than zk-bundle-v2.16.3")
      end
    end

    def core_capabilities
      guard { @ffi.core_capabilities }
    end

    def acquire_kms_credential_blocking(input)
      guard do
        @ffi.acquire_kms_credential_blocking(
          @ffi::FfiFederationInput.new(spec: spec(input[:spec]), identity_token: input[:identity_token],
                                       now_unix_secs: input[:now_unix_secs])
        )
      end
    end

    def app_crypto_seal_blocking(input)
      guard do
        @ffi.app_crypto_seal_blocking(
          @ffi::AppSealInput.new(
            provider: enum(@ffi::KmsProvider, PROVIDERS, input[:provider], 'provider'),
            posture: enum(@ffi::FfiPosture, POSTURES, input[:posture], 'posture'),
            kms_cred: cred(input[:kms_cred]),
            key_ref: @ffi::FfiKeyRef.new(version: input[:key_ref][:version], external_ref: input[:key_ref][:external_ref]),
            provider_config: provider_config(input[:provider_config]),
            project_id: input[:project_id], crypt: input[:crypt], context: input[:context],
            plaintext: input[:plaintext], expected_key_refs: input[:expected_key_refs]
          )
        )
      end
    end

    def app_crypto_open_blocking(input)
      guard do
        @ffi.app_crypto_open_blocking(
          @ffi::AppOpenInput.new(
            kms_cred: cred(input[:kms_cred]), provider_config: provider_config(input[:provider_config]),
            project_id: input[:project_id], crypt: input[:crypt], context: input[:context],
            container: input[:container], expected_key_refs: input[:expected_key_refs]
          )
        )
      end
    end

    def inspect
      "#<#{self.class.name}>"
    end

    private

    def unavailable(message)
      KError.new(code: 'KIBO_WASM_ERROR', message: message,
                 recommendation: 'Install the generated Kibo binding (kibo_kms_rest_ffi.rb) and the native library ' \
                                 '(zk-bundle-v2.16.3 or later); see "Encrypt through client.crypto" in the README.')
    end

    def load_binding(library, binding_path)
      require 'ffi'
      existing = loaded_binding
      return existing if existing
      return require_binding(binding_path) if library.nil?

      load_with_library(library, binding_path)
    rescue LoadError => e
      raise unavailable("the Kibo binding or its native library could not be loaded: #{e.message}")
    end

    def loaded_binding
      return nil unless Object.const_defined?(:KiboKmsRestFfi)

      mod = Object.const_get(:KiboKmsRestFfi)
      mod.respond_to?(:app_crypto_seal_blocking) ? mod : nil
    end

    def require_binding(binding_path)
      binding_path ? require(File.expand_path(binding_path)) : require('kibo_kms_rest_ffi')
      Object.const_get(:KiboKmsRestFfi)
    end

    # The binding opens +ffi_lib 'kibo_kms_rest_ffi'+ at load. To use an absolute path, the file is read and loaded with
    # that one line pointing at the path; nothing on disk changes.
    def load_with_library(library, binding_path)
      path = File.expand_path(library)
      raise LoadError, "no native library at #{path}" unless File.file?(path)

      file = binding_path ? File.expand_path(binding_path) : $LOAD_PATH.map { |d| File.join(d.to_s, 'kibo_kms_rest_ffi.rb') }.find { |f| File.file?(f) }
      raise LoadError, 'cannot find kibo_kms_rest_ffi.rb; pass binding_path: with its path' unless file

      source = File.read(file)
      raise LoadError, "#{file} does not look like the generated Kibo binding" unless source.match?(BINDING_LIB_LINE)

      # rubocop:disable Security/Eval
      TOPLEVEL_BINDING.eval(source.sub(BINDING_LIB_LINE) { "#{Regexp.last_match(1)}ffi_lib #{path.inspect}" }, file)
      # rubocop:enable Security/Eval
      Object.const_get(:KiboKmsRestFfi)
    end

    def enum(mod, table, wire, field)
      name = table[wire.to_s]
      raise KError.new(code: 'K9O_INVALID_FIELD_VALUE', message: "unknown #{field} #{wire.inspect}", context: { 'field' => field }) unless name

      mod.const_get(name)
    end

    def cred(h)
      @ffi::FfiCredential.new(secret: h[:secret], expires_at_unix_secs: h[:expires_at_unix_secs])
    end

    def provider_config(h)
      h ||= {}
      @ffi::FfiProviderConfig.new(aws_region: h[:aws_region], vault_address: h[:vault_address])
    end

    # The core's federation spec is a variant class per cloud.
    def spec(s)
      v = @ffi::FfiFederationSpec
      case s[:provider].to_s
      when 'aws' then v::AWS.new(s[:role_arn], s[:session_name], s[:region], s[:key_arn], s[:duration_secs])
      when 'gcp' then v::GCP.new(s[:audience])
      when 'azure' then v::AZURE.new(s[:tenant_id], s[:client_id], s[:scope])
      when 'vault' then v::VAULT.new(s[:vault_addr], s[:mount], s[:role])
      else
        raise KError.new(code: 'K9O_INVALID_FIELD_VALUE', message: "unknown federation provider #{s[:provider].inspect}",
                         context: { 'field' => 'federation.provider' })
      end
    end

    # The binding's error classes keep the code and detail as readers; their +message+ is not "CODE: detail".
    def guard
      yield
    rescue @ffi::ZkFfiUniffiError::Platform, @ffi::ZkFfiUniffiError::PostureViolation => e
      raise CoreError, "#{e.code}: #{e.detail}"
    rescue @ffi::ZkFfiUniffiError::UpstreamKms => e
      raise CoreError, "UPSTREAM_KMS_ERROR: #{e.detail}"
    end
  end
end
