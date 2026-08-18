require "fileutils"
require_relative "config"
require_relative "recorder"
require_relative "transcriber"
require_relative "logger_setup"
require_relative "daemon"
require_relative "socket_client"

module VoiceR
  class CLI
    RECORDINGS_DIR = File.join(Dir.home, ".local", "state", "voice_r", "recordings")

    def initialize(argv)
      @argv = argv
    end

    def run
      command = @argv.shift
      case command
      when "record" then cmd_record
      when "transcribe" then cmd_transcribe(@argv.shift, @argv.shift)
      when "daemon" then cmd_daemon
      when "toggle" then cmd_toggle(@argv.shift)
      when "status" then cmd_status
      when "reload" then cmd_reload
      else
        warn "usage: voice_r <record|transcribe PATH.wav [LANG]|daemon|toggle [LANG]|status|reload>"
        exit 1
      end
    end

    private

    def cmd_record
      config = Config.load
      logger = LoggerSetup.build
      FileUtils.mkdir_p(RECORDINGS_DIR)
      path = File.join(RECORDINGS_DIR, "rec-#{Time.now.strftime('%Y%m%d-%H%M%S')}-#{Process.pid}.wav")

      recorder = Recorder.new(capture_cmd: config.capture_cmd, sample_rate: config.sample_rate, logger: logger)
      recorder.start(path)
      puts "録音中... Enterキーで終了します。"
      $stdin.gets
      recorder.stop
      puts path
    end

    def cmd_transcribe(path, language_override)
      if path.nil? || !File.exist?(path)
        warn "usage: voice_r transcribe PATH.wav [LANG]  (LANG e.g. ja, en, auto - overrides config)"
        exit 1
      end

      config = Config.load
      logger = LoggerSetup.build
      transcriber = Transcriber.new(server_url: config.whisper_server_url, language: config.whisper_language, logger: logger)
      puts transcriber.transcribe(path, language: language_override || config.whisper_language, prompt: config.whisper_prompt)
    end

    def cmd_daemon
      Daemon.new.run
    end

    def cmd_toggle(lang)
      send_control(lang ? "TOGGLE #{lang}" : "TOGGLE")
    end

    def cmd_status
      send_control("STATUS")
    end

    def cmd_reload
      send_control("RELOAD")
    end

    def send_control(line)
      response = SocketClient.new(Daemon.socket_path).send_command(line)
      puts response || "ERR no response"
    rescue Errno::ENOENT, Errno::ECONNREFUSED => e
      warn "voice_r daemon not reachable at #{Daemon.socket_path} (#{e.message}). Is 'voice_r daemon' running?"
      exit 1
    end
  end
end
