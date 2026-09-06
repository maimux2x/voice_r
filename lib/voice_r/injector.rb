require "open3"

module VoiceR
  class Injector
    # ydotool 1.0.4-r4's "key" subcommand only accepts raw Linux input-event
    # keycodes, not symbolic names like "ctrl" (documented v1.0.0 breaking
    # change, confirmed via man ydotool). 29=KEY_LEFTCTRL, 47=KEY_V; press
    # ctrl, press v, release v, release ctrl.
    PASTE_KEYSTROKE = ["ydotool", "key", "29:1", "47:1", "47:0", "29:0"].freeze

    def initialize(tool: "ydotool", ime_direct_engine: nil, clipboard_paste_delay: 0.4, logger: nil)
      @tool = tool
      @ime_direct_engine = ime_direct_engine
      @clipboard_paste_delay = clipboard_paste_delay
      @logger = logger
    end

    # text is the recognized/expanded transcript. It is handed to the
    # injection tool as a single argv element (or, on the paste path, as
    # stdin data) - never through a shell, never executed. This is the only
    # thing voice_r ever does with recognized text: type or paste it at the
    # cursor. See README's safety policy.
    #
    # ydotool can only inject ASCII text: it synthesizes keycodes via uinput
    # with no keycode existing for kana/kanji at all (unlike the IME issue
    # below, no keystroke sequence produces these characters, regardless of
    # IME state). Non-ASCII text is instead routed through the clipboard:
    # wl-copy loads it, ydotool sends a Ctrl+V keystroke, then the clipboard's
    # prior content is restored.
    def inject(text)
      return if text.nil? || text.empty?

      text.ascii_only? ? inject_via_type(text) : inject_via_paste(text)
      true
    end

    private

    # ydotool synthesizes keycodes via uinput, bypassing the IME entirely, so
    # if ibus/mozc (or any conversion-mode IME) is active it reinterprets the
    # raw romaji keystrokes as kana input (e.g. "hello" -> "へっぉ"). When
    # ime_direct_engine is configured, temporarily switch ibus to that direct
    # (non-conversion) engine around the injection and restore whatever was
    # active before.
    def inject_via_type(text)
      previous_engine = switch_to_direct_input
      run_or_raise(build_argv(text), label: @tool)
    ensure
      restore_input_engine(previous_engine) if previous_engine
    end

    # IME switching is deliberately not used here: the paste path only ever
    # sends a fixed Ctrl+V chord (no character-representing keystrokes), so
    # it's unaffected by IME state, and skipping it avoids a needless ibus
    # round-trip on every Japanese utterance.
    def inject_via_paste(text)
      previous_clipboard = read_clipboard
      write_clipboard(text)
      run_or_raise(PASTE_KEYSTROKE, label: "ydotool")
      sleep(@clipboard_paste_delay)
    ensure
      restore_clipboard(previous_clipboard) unless previous_clipboard.nil?
    end

    def run_or_raise(argv, label:)
      _, stderr, status = Open3.capture3(*argv)
      unless status.success?
        @logger&.error("injector: #{label} failed: #{stderr}")
        raise "text injection failed (#{label}): #{stderr}"
      end
    end

    def read_clipboard
      out, _stderr, status = Open3.capture3("wl-paste", "--no-newline")
      return nil unless status.success?

      out
    rescue Errno::ENOENT => e
      @logger&.warn("injector: wl-paste not available, cannot save clipboard for restore: #{e.message}")
      nil
    end

    # wl-copy forks into the background by default and stays alive to serve
    # the clipboard (the paste that follows depends on it still being
    # around) - confirmed on this machine that Open3.capture3 hangs forever
    # on it, because the pipes it sets up for stdout/stderr are inherited by
    # that backgrounded process and never see EOF. Process.spawn with
    # discarded output sidesteps this entirely: Process.wait2 only waits on
    # this specific child's own exit, independent of any file descriptor -
    # the same reasoning as Recorder's Process.spawn usage.
    #
    # Loading the new dictated text is core to the injection succeeding, so
    # unlike restore_clipboard below, failure here raises.
    def write_clipboard(text)
      pid = Process.spawn("wl-copy", text, out: File::NULL, err: File::NULL)
      _, status = Process.wait2(pid)
      unless status.success?
        @logger&.error("injector: wl-copy failed (exit #{status.exitstatus})")
        raise "text injection failed (wl-copy): exit #{status.exitstatus}"
      end
    rescue Errno::ENOENT => e
      @logger&.error("injector: wl-copy not available, cannot paste-inject: #{e.message}")
      raise "text injection failed: wl-clipboard not installed (#{e.message})"
    end

    # Best-effort restore of whatever was in the clipboard before the paste.
    # Runs from an ensure block, so failures are logged rather than raised -
    # raising here would mask the real error from the paste itself.
    def restore_clipboard(text)
      pid = Process.spawn("wl-copy", text, out: File::NULL, err: File::NULL)
      _, status = Process.wait2(pid)
      @logger&.warn("injector: failed to restore clipboard (exit #{status.exitstatus})") unless status.success?
    rescue Errno::ENOENT => e
      @logger&.warn("injector: wl-copy not available, could not restore clipboard: #{e.message}")
    end

    def switch_to_direct_input
      return nil if @ime_direct_engine.nil? || @ime_direct_engine.empty?

      current = query_ibus_engine
      return nil if current.nil? || current.empty?
      return nil if current == @ime_direct_engine

      Open3.capture3("ibus", "engine", @ime_direct_engine)
      switched = query_ibus_engine
      if switched != @ime_direct_engine
        @logger&.warn("injector: failed to switch ibus engine to #{@ime_direct_engine} (still #{switched.inspect})")
        return nil
      end

      current
    rescue Errno::ENOENT => e
      @logger&.warn("injector: ibus not available, skipping IME switch: #{e.message}")
      nil
    end

    def restore_input_engine(previous_engine)
      Open3.capture3("ibus", "engine", previous_engine)
      restored = query_ibus_engine
      unless restored == previous_engine
        @logger&.warn("injector: failed to restore ibus engine to #{previous_engine} (still #{restored.inspect})")
      end
    rescue Errno::ENOENT => e
      @logger&.warn("injector: ibus not available, could not restore engine: #{e.message}")
    end

    # ibus's "engine <name>" subcommand can report a non-zero exit status
    # for reasons unrelated to whether the switch worked (e.g. it also shells
    # out to setxkbmap for xkb-based engines, which may not be installed) -
    # confirmed on this machine. So switches/restores are verified by
    # re-querying rather than trusting that command's exit status; this
    # query (no args) has no such side effect and its exit status is reliable.
    def query_ibus_engine
      out, _, status = Open3.capture3("ibus", "engine")
      return nil unless status.success?

      out.to_s.strip
    end

    def build_argv(text)
      case @tool
      when "ydotool"
        ["ydotool", "type", text]
      else
        raise "unsupported injection.tool: #{@tool.inspect}"
      end
    end
  end
end
