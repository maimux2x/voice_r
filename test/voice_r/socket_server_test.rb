require_relative "../test_helper"
require "voice_r/socket_server"
require "voice_r/socket_client"
require "tmpdir"

class SocketServerTest < Minitest::Test
  def test_round_trip_request_response
    Dir.mktmpdir do |dir|
      socket_path = File.join(dir, "test.sock")
      server = VoiceR::SocketServer.new(socket_path)
      thread = Thread.new { server.serve { |line| "ECHO:#{line.strip}" } }

      begin
        wait_for_socket(socket_path)
        client = VoiceR::SocketClient.new(socket_path)
        assert_equal "ECHO:PING", client.send_command("PING")
        assert_equal "ECHO:TOGGLE ja", client.send_command("TOGGLE ja")
      ensure
        thread.kill
        thread.join(1)
      end
    end
  end

  private

  def wait_for_socket(path, timeout: 2)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    sleep 0.01 until File.exist?(path) || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
  end
end
