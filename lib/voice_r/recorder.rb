module VoiceR
  class Recorder
    def initialize(capture_cmd:, sample_rate:, logger: nil)
      @capture_cmd = capture_cmd
      @sample_rate = sample_rate
      @logger = logger
      @pid = nil
      @path = nil
    end

    def recording?
      !@pid.nil?
    end

    def start(path)
      raise "already recording" if recording?

      @path = path
      argv = build_argv(path)
      @pid = Process.spawn(*argv, out: File::NULL, err: File::NULL)
      @logger&.info("recorder: started pid=#{@pid} path=#{path} cmd=#{@capture_cmd}")
      @pid
    end

    def stop
      return nil unless recording?

      # SIGINT (not SIGTERM): empirically, parecord only flushes its internal
      # buffer to the WAV file on a "clean" stop. SIGTERM was observed to yield
      # a 0-frame (header-only) file for recordings under ~3s; SIGINT reliably
      # flushed real audio down to ~2s. Very short recordings (a quick word
      # said right after toggling on) can still come out empty either way -
      # Transcriber guards against sending an empty file to whisper-server.
      Process.kill("INT", @pid)
      Process.wait(@pid)
      path = @path
      @logger&.info("recorder: stopped path=#{path}")
      @pid = nil
      @path = nil
      path
    end

    private

    def build_argv(path)
      case @capture_cmd
      when "pw-record"
        ["pw-record", "--rate=#{@sample_rate}", "--channels=1", "--format=s16", path]
      when "parecord"
        ["parecord", "--rate=#{@sample_rate}", "--channels=1", "--format=s16le", path]
      else
        raise "unsupported audio.capture_cmd: #{@capture_cmd.inspect}"
      end
    end
  end
end
