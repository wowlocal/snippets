#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "net/http"
require "optparse"
require "uri"
require "webrick"

options = {
  bind: "127.0.0.1",
  fallback: nil
}

OptionParser.new do |parser|
  parser.on("--root PATH") { |value| options[:root] = value }
  parser.on("--token TOKEN") { |value| options[:token] = value }
  parser.on("--expires-at EPOCH", Integer) { |value| options[:expires_at] = value }
  parser.on("--port PORT", Integer) { |value| options[:port] = value }
  parser.on("--bind ADDRESS") { |value| options[:bind] = value }
  parser.on("--fallback URL") { |value| options[:fallback] = value }
end.parse!

required = %i[root token expires_at port]
missing = required.reject { |key| options.key?(key) && !options[key].to_s.empty? }
abort("Missing options: #{missing.join(', ')}") unless missing.empty?
abort("Invalid token") unless options[:token].match?(/\A[a-f0-9]{48}\z/)
abort("Invalid expiry") unless options[:expires_at].positive?
abort("Invalid port") unless (1..65_535).cover?(options[:port])

root = File.realpath(options[:root])
abort("Artifact root is not a directory") unless File.directory?(root)

fallback = if options[:fallback].to_s.empty?
             nil
           else
             candidate = URI(options[:fallback])
             unless %w[http https].include?(candidate.scheme) && candidate.host
               abort("Fallback must be an HTTP(S) URL")
             end
             candidate
           end

prefix = "/snippets-ios/#{options[:token]}"
public_files = Dir.children(root).each_with_object({}) do |name, result|
  path = File.join(root, name)
  next unless File.file?(path) && !File.symlink?(path)

  result["#{prefix}/#{name}"] = path
end.freeze

mime_types = {
  ".html" => "text/html; charset=utf-8",
  ".ipa" => "application/octet-stream",
  ".plist" => "application/xml",
  ".png" => "image/png"
}.freeze

hop_by_hop_headers = %w[
  connection
  content-length
  keep-alive
  proxy-authenticate
  proxy-authorization
  te
  trailer
  transfer-encoding
  upgrade
].freeze

server = WEBrick::HTTPServer.new(
  BindAddress: options[:bind],
  Port: options[:port],
  AccessLog: [],
  Logger: WEBrick::Log.new(File::NULL)
)

server.mount_proc("/") do |request, response|
  if request.path == "/__snippets_ios_share_health"
    active = Time.now.to_i < options[:expires_at]
    response.status = 200
    response["Content-Type"] = "application/json"
    response["Cache-Control"] = "no-store"
    response.body = JSON.generate(active: active, expires_at: options[:expires_at])
    next
  end

  if request.path == prefix || request.path == "#{prefix}/"
    response.status = Time.now.to_i < options[:expires_at] ? 302 : 410
    response["Location"] = "#{prefix}/install.html" if response.status == 302
    response["Cache-Control"] = "no-store"
    response.body = response.status == 302 ? "" : "This install link has expired.\n"
    next
  end

  if request.path.start_with?("/snippets-ios/")
    if Time.now.to_i >= options[:expires_at]
      response.status = 410
      response["Content-Type"] = "text/plain; charset=utf-8"
      response["Cache-Control"] = "no-store"
      response.body = "This install link has expired.\n"
      next
    end

    file_path = public_files[request.path]
    unless file_path
      response.status = 404
      response["Content-Type"] = "text/plain; charset=utf-8"
      response["Cache-Control"] = "no-store"
      response.body = "Not found.\n"
      next
    end

    response.status = 200
    response["Content-Type"] = mime_types.fetch(File.extname(file_path), "application/octet-stream")
    response["Cache-Control"] = "private, no-store, max-age=0"
    response["X-Content-Type-Options"] = "nosniff"
    response["Content-Disposition"] = "attachment; filename=\"#{File.basename(file_path)}\"" if file_path.end_with?(".ipa")
    response.body = request.request_method == "HEAD" ? "" : File.binread(file_path)
    next
  end

  unless fallback
    response.status = 404
    response["Content-Type"] = "text/plain; charset=utf-8"
    response.body = "Not found.\n"
    next
  end

  target = fallback.dup
  target.path = request.path
  target.query = request.query_string unless request.query_string.to_s.empty?
  headers = request.header.each_with_object({}) do |(name, values), result|
    next if hop_by_hop_headers.include?(name.downcase) || name.casecmp?("host")

    result[name] = values.join(", ")
  end
  forwarded = Net::HTTPGenericRequest.new(
    request.request_method,
    !request.body.nil?,
    request.request_method != "HEAD",
    target.request_uri,
    headers
  )
  forwarded.body = request.body if request.body

  upstream = Net::HTTP.start(
    target.host,
    target.port,
    use_ssl: target.scheme == "https",
    open_timeout: 5,
    read_timeout: 60
  ) { |http| http.request(forwarded) }

  response.status = upstream.code.to_i
  upstream.each_header do |name, value|
    next if hop_by_hop_headers.include?(name.downcase)

    response[name] = value
  end
  response.body = request.request_method == "HEAD" ? "" : upstream.body
rescue StandardError
  response.status = 503
  response["Content-Type"] = "application/json"
  response["Cache-Control"] = "no-store"
  response.body = '{"error":"share_gateway_upstream_unavailable"}'
end

trap("INT") { server.shutdown }
trap("TERM") { server.shutdown }
server.start
