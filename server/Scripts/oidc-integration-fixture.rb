#!/usr/bin/env ruby
# frozen_string_literal: true

# Minimal RS256 issuer used only by the local end-to-end test. The private key
# stays in a mode-0700 temporary directory; the HTTP mode exposes only JWKS.

require "base64"
require "json"
require "openssl"
require "webrick"

KEY_ID = "snippets-integration-rs256"

def base64url(value)
  Base64.urlsafe_encode64(value, padding: false)
end

def load_key(path)
  OpenSSL::PKey::RSA.new(File.binread(path))
end

def jwks(key)
  JSON.generate(
    keys: [{
      kty: "RSA",
      kid: KEY_ID,
      use: "sig",
      alg: "RS256",
      n: base64url(key.n.to_s(2)),
      e: base64url(key.e.to_s(2))
    }]
  )
end

command, key_path, *arguments = ARGV
abort "usage: #{$PROGRAM_NAME} serve KEY_PATH PORT | token KEY_PATH ISSUER AUDIENCE SUBJECT" unless key_path

case command
when "serve"
  port = Integer(arguments.fetch(0), 10)
  body = jwks(load_key(key_path).public_key)
  server = WEBrick::HTTPServer.new(
    BindAddress: "127.0.0.1",
    Port: port,
    AccessLog: [],
    Logger: WEBrick::Log.new(File::NULL)
  )
  server.mount_proc "/jwks" do |_request, response|
    response.status = 200
    response["Cache-Control"] = "no-store"
    response["Content-Type"] = "application/json"
    response.body = body
  end
  server.mount_proc "/health" do |_request, response|
    response.status = 200
    response["Content-Type"] = "application/json"
    response.body = '{"status":"ok"}'
  end
  %w[INT TERM].each { |signal| trap(signal) { server.shutdown } }
  server.start
when "token"
  issuer, audience, subject = arguments
  abort "token requires issuer, audience, and subject" unless subject
  now = Time.now.to_i
  header = base64url(JSON.generate(alg: "RS256", kid: KEY_ID, typ: "JWT"))
  payload = base64url(JSON.generate(
    iss: issuer,
    sub: subject,
    aud: audience,
    iat: now,
    nbf: now - 5,
    exp: now + 900
  ))
  signed = "#{header}.#{payload}"
  signature = load_key(key_path).sign(OpenSSL::Digest::SHA256.new, signed)
  puts "#{signed}.#{base64url(signature)}"
else
  abort "unknown command"
end
