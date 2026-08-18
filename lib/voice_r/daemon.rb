require "fileutils"
require "json"
require_relative "config"
require_relative "state_machine"
require_relative "protocol"
require_relative "socket_server"
require_relative "recorder"
require_relative "transcriber"
require_relative "notifier"
require_relative "injector"
require_relative "logger_setup"

module VoiceR
  class Daemon
    RECORDINGS_DIR = File.join(Dir.home, ".local", "state", "voice_r", "recordings")

    def self.socket_path
      runtime_dir = ENV.fetch("XDG_RUNTIME_DIR", "/tmp")
      File.join(runtime_dir, "voice_r.sock")
    end

    def initialize
      @config = Config.load
      @logger = LoggerSetup.build
      @state_machine = StateMachine.new
      @recorder = Recorder.new(capture_cmd: @config.capture_cmd, sample_rate: @config.sample_rate, logger: @logger)
      @notifier = Notifier.new(logger: @logger)
      @injector = Injector.new(tool: @config.injection_tool, ime_direct_engine: @config.ime_direct_engine, logger: @logger)
      @last_transcript = nil
      @mutex = Mutex.new
    end

    def run
      FileUtils.mkdir_p(RECORDINGS_DIR)
      @logger.info("daemon: starting, socket=#{self.class.socket_path}")
      @notifier.notify("voice_r", "daemon started")
      @server = SocketServer.new(self.class.socket_path, logger: @logger)
      trap_signals
      @server.serve { |line| handle_line(line) }
    end

    private

    def trap_signals
      %w[INT TERM].each do |sig|
        Signal.trap(sig) do
          @recorder.stop if @recorder.recording?
          exit 0
        end
      end
    end

    def transcriber
      Transcriber.new(server_url: @config.whisper_server_url, language: @config.whisper_language, logger: @logger)
    end

    def handle_line(line)
      command = Protocol.parse(line)
      @mutex.synchronize do
        case command.name
        when "TOGGLE" then handle_toggle(command.arg)
        when "STATUS" then handle_status
        when "RELOAD" then handle_reload
        when "STOP_DAEMON" then handle_stop_daemon
        else "ERR unknown command #{command.name.inspect}"
        end
      end
    rescue StandardError => e
      @logger.error("daemon: error handling #{line.inspect}: #{e.message}")
      "ERR #{e.message}"
    end

    def handle_toggle(lang_override)
      if @state_machine.idle?
        start_recording
      elsif @state_machine.recording?
        stop_recording_and_transcribe(lang_override)
      else
        "ERR busy (state=#{@state_machine.state})"
      end
    end

    def start_recording
      path = File.join(RECORDINGS_DIR, "rec-#{Time.now.strftime('%Y%m%d-%H%M%S')}-#{Process.pid}.wav")
      @recorder.start(path)
      @state_machine.transition_to!(:recording)
      @notifier.notify("voice_r", "録音開始")
      "OK STARTED"
    end

    def stop_recording_and_transcribe(lang_override)
      path = @recorder.stop
      @state_machine.transition_to!(:transcribing)
      @notifier.notify("voice_r", "認識中...")
      Thread.new { transcribe_and_finish(path, lang_override) }
      "OK STOPPED"
    end

    def transcribe_and_finish(path, lang_override)
      text = transcriber.transcribe(
        path,
        language: lang_override || @config.whisper_language,
        prompt: @config.whisper_prompt
      )
      @mutex.synchronize { @last_transcript = text }

      unless text.empty?
        @mutex.synchronize { @state_machine.transition_to!(:injecting) }
        @injector.inject(text)
      end

      @mutex.synchronize { @state_machine.transition_to!(:idle) }
      @notifier.notify("voice_r", text.empty? ? "(認識結果なし)" : text)
    rescue StandardError => e
      @logger.error("daemon: transcription/injection failed: #{e.message}")
      @mutex.synchronize { @state_machine.transition_to!(:idle) }
      @notifier.notify("voice_r エラー", e.message)
    end

    def handle_status
      { state: @state_machine.state.to_s, last_transcript: @last_transcript }.to_json
    end

    def handle_reload
      @config = Config.load
      "OK RELOADED"
    end

    def handle_stop_daemon
      Thread.new do
        sleep 0.1
        exit 0
      end
      "OK BYE"
    end
  end
end
