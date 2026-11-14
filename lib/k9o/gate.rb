# frozen_string_literal: true

module K9o
  # Gate (Identity-Aware Kernel) namespace. Project-scoped; the gateway closes each body to the fields shown.
  class Gate
    def initialize(config)
      @config = config
    end

    # POST /@<slug>/gate/signup { email, password, displayName? }
    def sign_up(email:, password:, display_name: nil)
      body = { 'email' => email, 'password' => password }
      body['displayName'] = display_name if display_name
      HttpTransport.request(config: @config, method: 'POST', path: gate_path('signup'), body: body)
    end

    # POST /@<slug>/gate/signin { email, password }
    #
    # Asks the project which region holds the email first (POST /@<slug>/gate/locate, the email only, no credential),
    # then sends the password to that region's host if it is a host of your own org and apex, else to the base URL.
    # A 429 or 503 from that step raises as any gateway error does, nothing else is sent, and it is safe to retry.
    def sign_in(email:, password:)
      origin = Locate.origin_for(@config, email, gate_path('locate'))
      out = HttpTransport.request(
        config: @config, method: 'POST', path: gate_path('signin'),
        body: { 'email' => email, 'password' => password }, origin: origin
      )
      Locate.remember(session_refresh_token(out), origin)
      out
    end

    # POST /@<slug>/gate/signout { refreshToken } — the refresh token is required (the gateway answers 400 without it).
    def sign_out(refresh_token:)
      out = HttpTransport.request(config: @config, method: 'POST', path: gate_path('signout'),
                                  body: { 'refreshToken' => refresh_token }, origin: Locate.hint(refresh_token))
      Locate.forget(refresh_token)
      out
    end

    # GET /@<slug>/gate/whoami
    def whoami
      HttpTransport.request(config: @config, method: 'GET', path: gate_path('whoami'))
    end

    # POST /@<slug>/auth/sessions/revoke-all
    #
    # Ends every live session of the signed-in end user, on every device, this one included. Call it with the end
    # user's access token as the client's `api_key` (the token `whoami` uses), not a refresh token. The answer's `data`
    # is `{ revokedCount }`. Each ended session's next refresh raises a KError with code `K9O_SESSION_EXPIRED` and a
    # `reason` of `"revoked"` in its `context`; access tokens already issued keep working until they expire. An
    # operator's token raises `K9O_TRUST_ZONE_VIOLATION` (403), and a token issued for another project
    # `K9O_PROJECT_SCOPE_MISMATCH` (403).
    def revoke_all_sessions
      HttpTransport.request(config: @config, method: 'POST', path: project_path('auth/sessions/revoke-all'))
    end

    # POST /@<slug>/gate/refresh { refreshToken }
    #
    # The answer's `data` is `{ accessToken, refreshToken, expiresAt }`. The refresh token you sent stops working: store
    # the returned `refreshToken` before the next refresh, and refresh one at a time per session. A second call with a
    # secret that was already used is a replay: the session is revoked and the call raises a KError with code
    # `K9O_SESSION_EXPIRED` and a `reason` of `"replay"` in its `context`. The newer secret then gets `"revoked"`. The
    # other reasons are `"inactive"` and `"max_length"`; sign in again.
    def refresh_token(refresh_token:)
      out = HttpTransport.request(
        config: @config, method: 'POST', path: gate_path('refresh'),
        body: { 'refreshToken' => refresh_token }, origin: Locate.hint(refresh_token)
      )
      Locate.rotate(refresh_token, out.respond_to?(:data) ? out.data : nil)
      out
    end

    private

    def session_refresh_token(envelope)
      data = envelope.respond_to?(:data) ? envelope.data : nil
      session = data.is_a?(Hash) ? data['session'] : nil
      session.is_a?(Hash) ? session['refreshToken'] : nil
    end

    def gate_path(action)
      project_path("gate/#{action}")
    end

    def project_path(suffix)
      raise KError.new(
        code: 'K9O_MISSING_PROJECT_CONTEXT',
        message: 'k9o.gate operations require project_slug bound on the client',
        context: {}
      ) if @config.project_slug.nil? || @config.project_slug.empty?
      UrlGrammar.project_path(@config.project_slug, suffix)
    end
  end
end
