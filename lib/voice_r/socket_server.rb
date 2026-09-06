require "socket"

module VoiceR
  class SocketServer
    def initialize(socket_path, logger: nil)
      @socket_path = socket_path
      @logger = logger
    end

    # Accepts one connection per command: read one line, hand it to `handler`,
    # write back the single-line response, close. Each connection is handled
    # on its own thread so a slow handler (e.g. background transcription
    # kicked off elsewhere) never blocks accepting the next control command.
    def serve(&handler)
      File.unlink(@socket_path) if File.exist?(@socket_path)
      server = UNIXServer.new(@socket_path)
      File.chmod(0o600, @socket_path)
      @logger&.info("socket_server: listening on #{@socket_path}")

      loop do
        client = server.accept
        Thread.new(client) do |c|
          begin
            line = c.gets
            response = line ? handler.call(line) : nil
            c.puts(response) if response
          rescue StandardError => e
            @logger&.error("socket_server: error handling connection: #{e.message}")
          ensure
            c.close
          end
        end
      end
    ensure
      server&.close
      File.unlink(@socket_path) if File.exist?(@socket_path)
    end
  end
end
