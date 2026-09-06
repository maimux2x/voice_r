require "yaml"

module VoiceR
  class Config
    DEFAULTS = {
      "whisper" => {
        "server_url" => "http://127.0.0.1:8081",
        # whisper-server defaults to "en" server-side when no language is sent,
        # which forces English decoding onto Japanese audio and produces garbage
        # (e.g. hallucinated "[speaking Japanese]" captions). Always send a value.
        # "auto" is also unreliable on short utterances (observed misdetection as
        # an unrelated language) - pin to the primary spoken language and override
        # per-call (CLI arg / later TOGGLE <lang>) when speaking the other one.
        "language" => "ja",
        "match_threshold" => 0.82,
        # Static initial_prompt sent with every request to bias decoding toward
        # known vocabulary (e.g. "git" as a loanword rather than a similar-sounding
        # Japanese word). Confirmed empirically to fix real misrecognitions.
        # Superseded by a vocabulary-derived prompt in M5; this is a cheap interim win.
        "prompt" => ""
      },
      "audio" => {
        "capture_cmd" => "parecord",
        "sample_rate" => 16000
      },
      "injection" => {
        "tool" => "ydotool",
        # When set, temporarily switch ibus to this engine around each
        # injection so ydotool's raw uinput keystrokes aren't reinterpreted
        # as kana by a conversion-mode IME (confirmed: "hello" -> "へっぉ"
        # with mozc-jp active). Empty/nil disables the switch entirely.
        "ime_direct_engine" => "",
        # ydotool can't inject non-ASCII text at all (no keycode exists for
        # kana/kanji, regardless of IME state). Text that fails
        # String#ascii_only? is instead routed through the clipboard:
        # wl-copy loads it, ydotool sends a Ctrl+V keystroke, then the
        # clipboard's prior content is restored after this many seconds
        # (giving the target app time to actually read the paste before
        # it's overwritten - a placeholder value pending empirical tuning,
        # like the recorder's SIGINT-vs-SIGTERM timing).
        "clipboard_paste_delay" => 0.4
      }
    }.freeze

    attr_reader :data

    def self.config_dir
      File.join(ENV.fetch("XDG_CONFIG_HOME", File.join(Dir.home, ".config")), "voice_r")
    end

    def self.load(path = File.join(config_dir, "config.yml"))
      overrides = File.exist?(path) ? (YAML.safe_load_file(path) || {}) : {}
      new(deep_merge(DEFAULTS, overrides))
    end

    def initialize(data)
      @data = data
    end

    def whisper_server_url
      data.dig("whisper", "server_url")
    end

    def whisper_language
      data.dig("whisper", "language")
    end

    def match_threshold
      data.dig("whisper", "match_threshold")
    end

    def whisper_prompt
      data.dig("whisper", "prompt")
    end

    def capture_cmd
      data.dig("audio", "capture_cmd")
    end

    def sample_rate
      data.dig("audio", "sample_rate")
    end

    def injection_tool
      data.dig("injection", "tool")
    end

    def ime_direct_engine
      data.dig("injection", "ime_direct_engine")
    end

    def clipboard_paste_delay
      data.dig("injection", "clipboard_paste_delay")
    end

    def self.deep_merge(base, override)
      base.merge(override) do |_key, base_val, override_val|
        if base_val.is_a?(Hash) && override_val.is_a?(Hash)
          deep_merge(base_val, override_val)
        else
          override_val
        end
      end
    end
    private_class_method :deep_merge
  end
end
