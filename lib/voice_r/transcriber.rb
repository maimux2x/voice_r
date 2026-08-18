require "open3"
require "json"

module VoiceR
  class Transcriber
    # A canonical PCM WAV header (RIFF/WAVE/fmt /data, no extra chunks) is 44
    # bytes. A file at or below that size has zero audio frames - observed in
    # practice when the capture command is stopped too soon after starting for
    # its internal buffer to flush (see Recorder#stop). Sending such a file to
    # whisper-server gets a plain-text "Invalid request" (non-JSON) response.
    EMPTY_WAV_MAX_BYTES = 44

    def initialize(server_url:, language: nil, logger: nil)
      @server_url = server_url
      @language = language
      @logger = logger
    end

    # wav_path and prompt are our own local strings (tmp file path we generated,
    # vocabulary loaded from local config) - never derived from unsanitized remote
    # input. Passed to curl as discrete argv elements (no shell), never executed.
    def transcribe(wav_path, language: @language, prompt: nil)
      if File.size(wav_path) <= EMPTY_WAV_MAX_BYTES
        raise "録音データが空です。トグルしてから声を出し終えるまで2秒以上あけてください"
      end

      argv = ["curl", "-s", "-X", "POST", "#{@server_url}/inference",
              "-F", "file=@#{wav_path}",
              "-F", "response_format=json",
              # Filters hallucinated bracketed captions like "[speaking Japanese]"
              # that whisper emits on quiet/ambiguous audio - undesirable for dictation.
              "-F", "suppress_nst=true"]
      argv += ["-F", "language=#{language}"] if language
      argv += ["-F", "prompt=#{prompt}"] if prompt && !prompt.empty?

      stdout, stderr, status = Open3.capture3(*argv)
      unless status.success?
        @logger&.error("transcriber: curl failed: #{stderr}")
        raise "whisper-server request failed: #{stderr}"
      end

      json = JSON.parse(stdout)
      (json["text"] || "").strip
    rescue JSON::ParserError => e
      @logger&.error("transcriber: bad JSON from whisper-server: #{stdout.inspect}")
      raise "whisper-server returned invalid JSON: #{e.message}"
    end
  end
end
