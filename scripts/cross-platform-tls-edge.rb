#!/usr/bin/env ruby
# frozen_string_literal: true

# A disposable reverse proxy for the cross-platform integration test. One Cloudflare
# quick tunnel fronts both JWKS and the local HTTP API, avoiding two independent DNS
# publication races. It is not a production TLS terminator.

require "base64"
require "json"
require "net/http"
require "openssl"
require "webrick"

KEY_ID = "snippets-integration-rs256"

def base64url(value)
  Base64.urlsafe_encode64(value, padding: false)
end

key_path, edge_port, api_port = ARGV
abort "usage: #{$PROGRAM_NAME} KEY_PATH EDGE_PORT API_PORT" unless api_port
public_key = OpenSSL::PKey::RSA.new(File.binread(key_path)).public_key
jwks = JSON.generate(keys: [{
  kty: "RSA",
  kid: KEY_ID,
  use: "sig",
  alg: "RS256",
  n: base64url(public_key.n.to_s(2)),
  e: base64url(public_key.e.to_s(2))
}])

server = WEBrick::HTTPServer.new(
  BindAddress: "127.0.0.1",
  Port: Integer(edge_port, 10),
  AccessLog: [],
  Logger: WEBrick::Log.new(File::NULL)
)
server.mount_proc "/" do |request, response|
  if request.path == "/jwks"
    response.status = 200
    response["Cache-Control"] = "no-store"
    response["Content-Type"] = "application/json"
    response.body = jwks
    next
  end

  path_and_query = request.path
  path_and_query += "?#{request.query_string}" unless request.query_string.to_s.empty?
  target = URI("http://127.0.0.1:#{Integer(api_port, 10)}#{path_and_query}")
  forwarded = Net::HTTPGenericRequest.new(
    request.request_method,
    !request.body.nil?,
    request.request_method != "HEAD",
    target.request_uri,
    request.header.each_with_object({}) do |(name, values), headers|
      next if %w[host connection content-length transfer-encoding].include?(name.downcase)
      headers[name] = values.join(", ")
    end
  )
  forwarded.body = request.body if request.body
  upstream = Net::HTTP.start(target.host, target.port) { |http| http.request(forwarded) }
  response.status = upstream.code.to_i
  upstream.each_header do |name, value|
    next if %w[connection content-length transfer-encoding].include?(name.downcase)
    response[name] = value
  end
  response.body = upstream.body
rescue StandardError => error
  warn "edge proxy failure: #{error.class}: #{error.message}"
  response.status = 503
  response["Content-Type"] = "application/json"
  response.body = '{"code":"edge_unavailable"}'
end

%w[INT TERM].each { |signal| trap(signal) { server.shutdown } }
server.start
