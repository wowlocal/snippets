#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "fileutils"
require "minitest/autorun"
require "net/http"
require "openssl"
require "socket"
require "tmpdir"
require "webrick"
require_relative "cross-platform-tls-edge"

class CrossPlatformTLSEdgeTests < Minitest::Test
  def setup
    @temporary_directory = Dir.mktmpdir("snippets-chaos-edge-test")
    @configuration_path = File.join(@temporary_directory, "chaos.json")
    @state_path = File.join(@temporary_directory, "state.json")
    @key_path = File.join(@temporary_directory, "oidc.pem")
    File.binwrite(@key_path, OpenSSL::PKey::RSA.new(2_048).to_pem)
    File.chmod(0o600, @key_path)
    @upstream_counts = Hash.new(0)
    @upstream_mutex = Mutex.new
    @upstream = WEBrick::HTTPServer.new(
      BindAddress: "127.0.0.1",
      Port: available_port,
      AccessLog: [],
      Logger: WEBrick::Log.new(File::NULL))
    @upstream_port = @upstream.config.fetch(:Port)
    @upstream.mount_proc("/") do |request, response|
      path_and_query = request.path
      path_and_query += "?#{request.query_string}" unless request.query_string.to_s.empty?
      count = @upstream_mutex.synchronize do
        @upstream_counts[path_and_query] += 1
      end
      response.status = 200
      response["Content-Type"] = "application/json"
      response.body = JSON.generate(path: path_and_query, count: count, body: request.body)
    end
    @upstream_thread = Thread.new { @upstream.start }

    write_plan("initial", [])
    @edge_port = available_port
    @edge = SnippetsIntegrationEdge::Server.new(
      key_path: @key_path,
      edge_port: @edge_port,
      api_port: @upstream_port,
      chaos_configuration_path: @configuration_path,
      chaos_state_path: @state_path)
    @edge_thread = Thread.new { @edge.start }
    wait_until_ready
  end

  def teardown
    @edge&.shutdown
    @upstream&.shutdown
    @edge_thread&.join(5)
    @upstream_thread&.join(5)
    FileUtils.remove_entry_secure(@temporary_directory) if @temporary_directory
  end

  def test_nth_match_can_fail_before_upstream_exactly_once
    write_plan("before", [{
      id: "before",
      method: "GET",
      pathPattern: "\\A/before\\z",
      nth: 2,
      action: {
        type: "return_before_upstream",
        status: 429,
        body: '{"code":"rate_limited"}'
      }
    }])

    assert_equal 200, get("/before").code.to_i
    assert_equal 429, get("/before").code.to_i
    assert_equal 200, get("/before").code.to_i
    assert_equal 2, upstream_count("/before")
    assert_rule_state("before", matched: 3, triggered: 1, upstream_attempts: 0)
  end

  def test_response_can_be_lost_after_upstream_commits
    write_plan("lost", [{
      id: "lost",
      method: "POST",
      pathPattern: "\\A/commit\\z",
      nth: 1,
      action: {
        type: "forward_then_replace",
        status: 503,
        body: '{"code":"dependency_unavailable"}'
      }
    }])

    response = post("/commit", '{"value":1}')
    assert_equal 503, response.code.to_i
    assert_equal 1, upstream_count("/commit")
    assert_rule_state("lost", matched: 1, triggered: 1, upstream_attempts: 1)
  end

  def test_response_can_be_truncated_once
    write_plan("truncate", [{
      id: "truncate",
      method: "GET",
      pathPattern: "\\A/truncate\\z",
      nth: 1,
      action: { type: "forward_then_truncate", bytes: 7 }
    }])

    first = get("/truncate")
    second = get("/truncate")
    assert_equal 7, first.body.bytesize
    assert_equal "/truncate", JSON.parse(second.body).fetch("path")
    assert_equal 2, upstream_count("/truncate")
  end

  def test_request_can_be_delayed_without_random_timing
    write_plan("delay", [{
      id: "delay",
      method: "GET",
      pathPattern: "\\A/delay\\z",
      nth: 1,
      action: { type: "delay_before_upstream", milliseconds: 150 }
    }])

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    assert_equal 200, get("/delay").code.to_i
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    assert_operator elapsed, :>=, 0.13
    assert_operator elapsed, :<, 2.0
  end

  def test_request_can_be_repeated_and_original_response_returned
    write_plan("repeat", [{
      id: "repeat",
      method: "POST",
      pathPattern: "\\A/repeat\\z",
      nth: 1,
      action: { type: "repeat_upstream", count: 3 }
    }])

    response = post("/repeat", '{"value":2}')
    assert_equal 200, response.code.to_i
    assert_equal 1, JSON.parse(response.body).fetch("count")
    assert_equal 3, upstream_count("/repeat")
    assert_rule_state("repeat", matched: 1, triggered: 1, upstream_attempts: 3)
  end

  def test_upstream_path_can_be_rewritten_once
    write_plan("rewrite", [{
      id: "rewrite",
      method: "GET",
      pathPattern: "\\A/original\\?cursor=current\\z",
      nth: 1,
      action: {
        type: "rewrite_upstream_path",
        path: "/original?cursor=stale"
      }
    }])

    first = JSON.parse(get("/original?cursor=current").body)
    second = JSON.parse(get("/original?cursor=current").body)
    assert_equal "/original?cursor=stale", first.fetch("path")
    assert_equal "/original?cursor=current", second.fetch("path")
  end

  def test_invalid_configuration_fails_closed
    replace_configuration("not-json")

    response = get("/must-not-pass")
    assert_equal 503, response.code.to_i
    assert_equal 0, upstream_count("/must-not-pass")
    refute JSON.parse(File.binread(@state_path)).fetch("configurationValid")
  end

  private

  def available_port
    socket = TCPServer.new("127.0.0.1", 0)
    port = socket.addr[1]
    socket.close
    port
  end

  def wait_until_ready
    100.times do
      return if get("/ready").code.to_i == 200
    rescue Errno::ECONNREFUSED
      sleep 0.01
    end
    flunk "edge did not start"
  end

  def write_plan(generation, rules)
    replace_configuration(JSON.generate(generation: generation, rules: rules))
  end

  def replace_configuration(contents)
    temporary = "#{@configuration_path}.tmp"
    File.binwrite(temporary, contents)
    File.chmod(0o600, temporary)
    File.rename(temporary, @configuration_path)
  end

  def get(path)
    Net::HTTP.get_response(URI("http://127.0.0.1:#{@edge_port}#{path}"))
  end

  def post(path, body)
    request = Net::HTTP::Post.new(path)
    request["Content-Type"] = "application/json"
    request.body = body
    Net::HTTP.start("127.0.0.1", @edge_port) { |http| http.request(request) }
  end

  def upstream_count(path)
    @upstream_mutex.synchronize { @upstream_counts[path] }
  end

  def assert_rule_state(id, matched:, triggered:, upstream_attempts:)
    state = JSON.parse(File.binread(@state_path))
    rule = state.fetch("rules").find { |candidate| candidate.fetch("id") == id }
    refute_nil rule
    assert_equal matched, rule.fetch("matched")
    assert_equal triggered, rule.fetch("triggered")
    assert_equal upstream_attempts, rule.fetch("upstreamAttempts")
  end
end
