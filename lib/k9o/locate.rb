# frozen_string_literal: true

require 'uri'

module K9o
  # Locating the end user's region for password sign-in.
  #
  # K9o::Region finds the org's regional API host. An end user can live in another region of the project, so
  # +gate.sign_in+ first asks the project which region holds the address
  # (+POST /@<project>/gate/locate { email }+ at that regional base, with no credential) and sends the password to the
  # origin it names. The answer is the same for a known and an unknown address.
  #
  # Rules:
  # - The located origin is used for that one attempt. It is never cached. The one thing kept is a hint per refresh
  #   token (at most 64, in memory), so that refresh and sign-out reach the region that issued the session; a stale
  #   hint gets a 401.
  # - An origin is used only if it is https (http only when the base is itself http on a loopback host and the origin is
  #   loopback too), has no userinfo, port, path, query or fragment, and its host is exactly the base host's org,
  #   family and apex with the region code ([a-z]{2}\d{2}) added or swapped in the gateway label, and that code equals
  #   the answer's +region+. Anything else, or +origin: null+, means the base is used. A password never goes to a host
  #   that fails this.
  module Locate
    REGION_CODE = /\A[a-z]{2}\d{2}\z/.freeze
    HINT_LIMIT = 64
    HINT_LOCK = Mutex.new
    HINTS = {}

    module_function

    def loopback?(host)
      h = host.to_s.downcase
      h == 'localhost' || h.end_with?('.localhost') || h == '127.0.0.1' || h == '[::1]' || h == '::1'
    end

    # The origin the credential goes to: the located one if it passes the rule, else +base+. Pure; never raises.
    # +answer+ is the +data+ of the locate envelope.
    def choose_origin(base, answer)
      return base unless answer.is_a?(Hash)

      region = answer['region'] || answer[:region]
      origin = answer['origin'] || answer[:origin]
      return base unless origin.is_a?(String) && region.is_a?(String) && REGION_CODE.match?(region)

      b = URI.parse(base)
      u = URI.parse(origin)
      return base if b.host.nil? || u.host.nil? || !u.scheme.is_a?(String)
      return base unless u.userinfo.nil? && u.query.nil? && u.fragment.nil?
      return base unless u.port == u.default_port
      return base unless u.path.empty? || u.path == '/'

      bs = b.scheme.to_s.downcase
      us = u.scheme.to_s.downcase
      unless us == 'https' || (us == 'http' && bs == 'http' && loopback?(b.host) && loopback?(u.host))
        return base
      end

      bh = b.host.downcase
      uh = u.host.downcase
      return "#{bs}://#{bh}#{b.port == b.default_port ? '' : ":#{b.port}"}" if us == bs && uh == bh && u.port == b.port

      from = UrlGrammar.parse_api_host(bh)
      to = UrlGrammar.parse_api_host(uh)
      return base if from.nil? || to.nil? || to.region != region
      return base unless from.org_slug == to.org_slug && from.family == to.family && from.apex == to.apex

      "#{us}://#{uh}"
    rescue URI::Error, ArgumentError
      base
    end

    # Ask the project which region holds +email+ and return the origin the credential goes to. A 404 from the door
    # means the locate door is off and the base is used. Any other non-2xx answer (429, 503, anything else) raises as any other gateway error does, and nothing is sent after it. A 2xx
    # answer that cannot be read means the base is used.
    def origin_for(config, email, path)
      base = Region.resolve_origin(config).sub(%r{/+\z}, '')
      begin
        env = HttpTransport.request(config: config, method: 'POST', path: path, body: { 'email' => email },
                                    authenticated: false)
      rescue KError => e
        # 404: the locate door is off, so the base is used.
        raise unless e.status == 404 || (e.code == 'K9O_INTERNAL_ERROR' && e.status.to_i.between?(200, 299))

        return base
      end
      choose_origin(base, env.data)
    end

    # Remember which origin issued the session with this refresh token (a hint, not authority).
    def remember(refresh_token, origin)
      return unless refresh_token.is_a?(String) && !refresh_token.empty?

      HINT_LOCK.synchronize do
        HINTS.delete(refresh_token)
        HINTS[refresh_token] = origin
        HINTS.delete(HINTS.keys.first) while HINTS.size > HINT_LIMIT
      end
    end

    def hint(refresh_token)
      HINT_LOCK.synchronize { HINTS[refresh_token] }
    end

    def forget(refresh_token)
      HINT_LOCK.synchronize { HINTS.delete(refresh_token) }
    end

    # A refresh answers with a new refresh token and the old one stops working: the hint follows the session. Data
    # without a new token changes nothing.
    def rotate(old_refresh_token, data)
      token = data.is_a?(Hash) ? data['refreshToken'] : nil
      origin = hint(old_refresh_token)
      return unless token.is_a?(String) && !token.empty? && origin

      forget(old_refresh_token)
      remember(token, origin)
    end
  end
end
