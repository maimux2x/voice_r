require "open3"

module VoiceR
  class Injector
    def initialize(tool: "ydotool", ime_direct_engine: nil, logger: nil)
      @tool = tool
      @ime_direct_engine = ime_direct_engine
      @logger = logger
    end

    # text is the recognized/expanded transcript. It is handed to the
    # injection tool as a single argv element - never through a shell, never
    # executed. This is the only thing voice_r ever does with recognized text:
    # type it at the cursor. See README's safety policy.
    #
    # ydotool synthesizes keycodes via uinput, bypassing the IME entirely, so
    # if ibus/mozc (or any conversion-mode IME) is active it reinterprets the
    # raw romaji keystrokes as kana input (e.g. "hello" -> "へっぉ"). When
    # ime_direct_engine is configured, temporarily switch ibus to that direct
    # (non-conversion) engine around the injection and restore whatever was
    # active before.
    def inject(text)
      return if text.nil? || text.empty?

      previous_engine = switch_to_direct_input

      argv = build_argv(text)
      _, stderr, status = Open3.capture3(*argv)
      unless status.success?
        @logger&.error("injector: #{@tool} failed: #{stderr}")
        raise "text injection failed (#{@tool}): #{stderr}"
      end

      true
    ensure
      restore_input_engine(previous_engine) if previous_engine
    end

    private

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
