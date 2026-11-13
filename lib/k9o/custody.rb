# frozen_string_literal: true

module K9o
  # Key custody: k9o.custody.* reads how the project's keys are held. Changing custody is a Console action.
  #
  #   status()    GET /@<slug>/custody/status    (project admin or auditor)
  #
  # +data+ is { 'mode', 'attached', 'provider', 'lastJob', 'hsm' }: +mode+ is a string such as "PLATFORM_MANAGED",
  # +attached+ a boolean, +provider+ "platform", "external_kms", "hsm" or nil, +lastJob+ nil or
  # { 'kind', 'status', 'completedAt' }. +hsm+ is nil unless the provider is "hsm"; then it is
  # { 'vendor', 'clusterId', 'region', 'attestation' => { 'status', 'verifiedAt' }, 'keys' }, where
  # +attestation+ values and +keys+ are nil for now. An answer without an +hsm+ key reads as +hsm+ nil.
  # Errors: 403 for another role, 404 when the caller is not a project member, 502 K9O_UPSTREAM_UNAVAILABLE when the
  # key manager cannot answer for an attached project.
  class Custody
    def initialize(config)
      @config = config
    end

    def status
      path = UrlGrammar.project_path(Studio.require_project_slug(@config, 'custody'), 'custody/status')
      envelope = HttpTransport.request(config: @config, method: 'GET', path: path)
      data = envelope.data
      data['hsm'] = nil if data.is_a?(Hash) && !data.key?('hsm')
      envelope
    end
  end
end
