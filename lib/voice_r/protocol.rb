module VoiceR
  module Protocol
    Command = Struct.new(:name, :arg)

    # Parses one line of the daemon's newline-delimited control protocol.
    # Pure function - no I/O - so it's testable without a real socket.
    def self.parse(line)
      stripped = line.to_s.strip
      return Command.new(nil, nil) if stripped.empty?

      name, arg = stripped.split(/\s+/, 2)
      Command.new(name.upcase, arg)
    end
  end
end
