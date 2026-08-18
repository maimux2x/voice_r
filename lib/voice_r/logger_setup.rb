require "logger"
require "fileutils"

module VoiceR
  module LoggerSetup
    def self.build
      state_dir = File.join(Dir.home, ".local", "state", "voice_r")
      FileUtils.mkdir_p(state_dir)
      Logger.new(File.join(state_dir, "voice_r.log"), 5, 1_048_576)
    end
  end
end
