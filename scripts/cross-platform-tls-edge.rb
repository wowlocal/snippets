#!/usr/bin/env ruby
# frozen_string_literal: true

# A disposable reverse proxy for the cross-platform integration test. One Cloudflare
# quick tunnel fronts both JWKS and the local HTTP API, avoiding two independent DNS
# publication races. An optional atomically-replaced JSON plan injects deterministic
# failures at this boundary. This is not a production TLS terminator.

require "base64"
require "json"
require "net/http"
require "openssl"
require "thread"
require "webrick"

module SnippetsIntegrationEdge
  KEY_ID = "snippets-integration-rs256"
  MAX_CHAOS_BODY_BYTES = 16 * 1_024 * 1_024
  ACTION_TYPES = %w[
    return_before_upstream
    delay_before_upstream
    forward_then_replace
    forward_then_truncate
    repeat_upstream
    rewrite_upstream_path
  ].freeze

  class ConfigurationError < StandardError; end

  def self.base64url(value)
    Base64.urlsafe_encode64(value, padding: false)
  end

  class ChaosPlan
    def initialize(configuration_path:, state_path:)
      @configuration_path = configuration_path
      @state_path = state_path
      @mutex = Mutex.new
      @generation = nil
      @rules = []
      @counts = {}
      @triggered = {}
      @upstream_attempts = {}
      @configuration_error = nil
    end

    def action_for(method:, path_and_query:)
      @mutex.synchronize do
        reload
        raise ConfigurationError, @configuration_error if @configuration_error

        @rules.each do |rule|
          next unless rule.fetch("method") == method
          next unless Regexp.new(rule.fetch("pathPattern")).match?(path_and_query)

          id = rule.fetch("id")
          @counts[id] += 1
          next unless @counts[id] == rule.fetch("nth")

          @triggered[id] += 1
          persist_state
          return [id, rule.fetch("action")]
        end
        persist_state
        nil
      end
    end

    def record_upstream_attempt(rule_id)
      return unless rule_id

      @mutex.synchronize do
        @upstream_attempts[rule_id] += 1
        persist_state
      end
    end

    private

    def reload
      document = if @configuration_path && File.file?(@configuration_path)
                   JSON.parse(File.binread(@configuration_path))
                 else
                   { "generation" => "disabled", "rules" => [] }
                 end
      validate_document(document)
      generation = document.fetch("generation")
      return if generation == @generation

      @generation = generation
      @rules = document.fetch("rules")
      @counts = @rules.to_h { |rule| [rule.fetch("id"), 0] }
      @triggered = @rules.to_h { |rule| [rule.fetch("id"), 0] }
      @upstream_attempts = @rules.to_h { |rule| [rule.fetch("id"), 0] }
      @configuration_error = nil
      persist_state
    rescue JSON::ParserError, KeyError, TypeError, ArgumentError, ConfigurationError
      @configuration_error = "invalid chaos configuration"
      persist_state
    end

    def validate_document(document)
      raise ConfigurationError unless document.is_a?(Hash)
      generation = document.fetch("generation")
      rules = document.fetch("rules")
      raise ConfigurationError unless generation.is_a?(String) && !generation.empty?
      raise ConfigurationError unless rules.is_a?(Array) && rules.length <= 32

      identifiers = {}
      rules.each do |rule|
        raise ConfigurationError unless rule.is_a?(Hash)
        id = rule.fetch("id")
        method = rule.fetch("method")
        pattern = rule.fetch("pathPattern")
        nth = rule.fetch("nth")
        action = rule.fetch("action")
        raise ConfigurationError unless id.is_a?(String) && id.match?(/\A[a-z0-9_-]{1,64}\z/)
        raise ConfigurationError if identifiers[id]
        identifiers[id] = true
        raise ConfigurationError unless method.is_a?(String) && method.match?(/\A[A-Z]+\z/)
        raise ConfigurationError unless pattern.is_a?(String) && pattern.bytesize <= 2_048
        Regexp.new(pattern)
        raise ConfigurationError unless nth.is_a?(Integer) && nth.positive? && nth <= 10_000
        validate_action(action)
      end
    end

    def validate_action(action)
      raise ConfigurationError unless action.is_a?(Hash)
      type = action.fetch("type")
      raise ConfigurationError unless ACTION_TYPES.include?(type)
      case type
      when "return_before_upstream", "forward_then_replace"
        status = action.fetch("status")
        body = action.fetch("body")
        raise ConfigurationError unless status.is_a?(Integer) && (100..599).cover?(status)
        raise ConfigurationError unless body.is_a?(String) && body.bytesize <= MAX_CHAOS_BODY_BYTES
      when "delay_before_upstream"
        milliseconds = action.fetch("milliseconds")
        raise ConfigurationError unless milliseconds.is_a?(Integer) && (0..120_000).cover?(milliseconds)
      when "forward_then_truncate"
        bytes = action.fetch("bytes")
        raise ConfigurationError unless bytes.is_a?(Integer) && bytes >= 0
      when "repeat_upstream"
        count = action.fetch("count")
        raise ConfigurationError unless count.is_a?(Integer) && (2..5).cover?(count)
      when "rewrite_upstream_path"
        path = action.fetch("path")
        raise ConfigurationError unless path.is_a?(String) && path.start_with?("/")
        raise ConfigurationError if path.bytesize > 8_192 || path.include?("\r") || path.include?("\n")
      end
      headers = action.fetch("headers", {})
      raise ConfigurationError unless headers.is_a?(Hash) && headers.length <= 16
      headers.each do |name, value|
        raise ConfigurationError unless name.is_a?(String) && name.match?(/\A[A-Za-z0-9-]+\z/)
        raise ConfigurationError unless value.is_a?(String) && value.bytesize <= 1_024
        raise ConfigurationError if value.include?("\r") || value.include?("\n")
      end
    end

    def persist_state
      return unless @state_path

      state = {
        generation: @generation,
        configurationValid: @configuration_error.nil?,
        rules: @rules.map do |rule|
          id = rule.fetch("id")
          {
            id: id,
            matched: @counts.fetch(id, 0),
            triggered: @triggered.fetch(id, 0),
            upstreamAttempts: @upstream_attempts.fetch(id, 0)
          }
        end
      }
      temporary = "#{@state_path}.#{Process.pid}.tmp"
      File.binwrite(temporary, JSON.generate(state))
      File.chmod(0o600, temporary)
      File.rename(temporary, @state_path)
    end
  end

  class Server
    def initialize(key_path:, edge_port:, api_port:, chaos_configuration_path: nil,
                   chaos_state_path: nil, logger: WEBrick::Log.new(File::NULL))
      public_key = OpenSSL::PKey::RSA.new(File.binread(key_path)).public_key
      @jwks = JSON.generate(keys: [{
        kty: "RSA",
        kid: KEY_ID,
        use: "sig",
        alg: "RS256",
        n: SnippetsIntegrationEdge.base64url(public_key.n.to_s(2)),
        e: SnippetsIntegrationEdge.base64url(public_key.e.to_s(2))
      }])
      @api_port = Integer(api_port)
      @chaos = ChaosPlan.new(
        configuration_path: chaos_configuration_path,
        state_path: chaos_state_path)
      @server = WEBrick::HTTPServer.new(
        BindAddress: "127.0.0.1",
        Port: Integer(edge_port),
        AccessLog: [],
        Logger: logger)
      @server.mount_proc("/") { |request, response| handle(request, response) }
    end

    def start
      @server.start
    end

    def shutdown
      @server.shutdown
    end

    private

    def handle(request, response)
      if request.path == "/jwks"
        response.status = 200
        response["Cache-Control"] = "no-store"
        response["Content-Type"] = "application/json"
        response.body = @jwks
        return
      end

      path_and_query = request.path
      path_and_query += "?#{request.query_string}" unless request.query_string.to_s.empty?
      selected = @chaos.action_for(
        method: request.request_method,
        path_and_query: path_and_query)
      rule_id, action = selected if selected

      if action&.fetch("type") == "return_before_upstream"
        apply_synthetic(response, action)
        return
      end

      sleep(action.fetch("milliseconds") / 1_000.0) if action&.fetch("type") == "delay_before_upstream"
      upstream_path = if action&.fetch("type") == "rewrite_upstream_path"
                        action.fetch("path")
                      else
                        path_and_query
                      end
      attempts = action&.fetch("type") == "repeat_upstream" ? action.fetch("count") : 1
      upstream_responses = Array.new(attempts) do
        @chaos.record_upstream_attempt(rule_id)
        forward(request, upstream_path)
      end
      upstream = upstream_responses.first

      case action&.fetch("type")
      when "forward_then_replace"
        apply_synthetic(response, action)
      when "forward_then_truncate"
        apply_upstream(response, upstream, body: upstream.body.to_s.byteslice(0, action.fetch("bytes")))
      else
        apply_upstream(response, upstream)
      end
    rescue ConfigurationError
      response.status = 503
      response["Content-Type"] = "application/json"
      response.body = '{"code":"chaos_configuration_invalid"}'
    rescue StandardError => error
      warn "edge proxy failure: #{error.class}"
      response.status = 503
      response["Content-Type"] = "application/json"
      response.body = '{"code":"edge_unavailable"}'
    end

    def forward(request, path_and_query)
      target = URI("http://127.0.0.1:#{@api_port}#{path_and_query}")
      forwarded = Net::HTTPGenericRequest.new(
        request.request_method,
        !request.body.nil?,
        request.request_method != "HEAD",
        target.request_uri,
        request.header.each_with_object({}) do |(name, values), headers|
          next if %w[host connection content-length transfer-encoding].include?(name.downcase)
          headers[name] = values.join(", ")
        end)
      forwarded.body = request.body if request.body
      Net::HTTP.start(target.host, target.port) { |http| http.request(forwarded) }
    end

    def apply_upstream(response, upstream, body: upstream.body)
      response.status = upstream.code.to_i
      upstream.each_header do |name, value|
        next if %w[connection content-length transfer-encoding].include?(name.downcase)
        response[name] = value
      end
      response.body = body
    end

    def apply_synthetic(response, action)
      response.status = action.fetch("status")
      response["Content-Type"] = "application/json"
      action.fetch("headers", {}).each { |name, value| response[name] = value }
      response.body = action.fetch("body")
    end
  end

  def self.run(arguments)
    key_path, edge_port, api_port, chaos_configuration_path, chaos_state_path = arguments
    abort "usage: #{$PROGRAM_NAME} KEY_PATH EDGE_PORT API_PORT [CHAOS_CONFIG STATE]" unless api_port
    if [chaos_configuration_path, chaos_state_path].one?(&:nil?)
      abort "CHAOS_CONFIG and STATE must be provided together"
    end

    server = Server.new(
      key_path: key_path,
      edge_port: edge_port,
      api_port: api_port,
      chaos_configuration_path: chaos_configuration_path,
      chaos_state_path: chaos_state_path)
    %w[INT TERM].each { |signal| trap(signal) { server.shutdown } }
    server.start
  end
end

SnippetsIntegrationEdge.run(ARGV) if $PROGRAM_NAME == __FILE__
