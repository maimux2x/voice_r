require "socket"

module VoiceR
  class SocketClient
    def initialize(socket_path)
      @socket_path = socket_path
    end

    def send_command(line)
      socket = UNIXSocket.new(@socket_path)
      socket.puts(line)
      socket.gets&.chomp
    ensure
      socket&.close
    end
  end
end
