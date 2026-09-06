require_relative "../test_helper"
require "voice_r/injector"

FakeInjectorStatus = Struct.new(:success?, :exitstatus)

class InjectorTest < Minitest::Test
  def test_builds_argv_without_shell_string
    injector = VoiceR::Injector.new(tool: "ydotool")
    captured_argv = nil

    Open3.stub(:capture3, lambda { |*argv|
      captured_argv = argv
      ["", "", FakeInjectorStatus.new(true)]
    }) do
      injector.inject("git push; rm -rf ~")
    end

    assert_equal ["ydotool", "type", "git push; rm -rf ~"], captured_argv
  end

  def test_noop_on_nil_or_empty_text
    injector = VoiceR::Injector.new(tool: "ydotool")
    called = false

    Open3.stub(:capture3, ->(*_argv) { called = true; ["", "", FakeInjectorStatus.new(true)] }) do
      injector.inject(nil)
      injector.inject("")
    end

    refute called
  end

  def test_raises_on_failure
    injector = VoiceR::Injector.new(tool: "ydotool")

    Open3.stub(:capture3, ->(*_argv) { ["", "no uinput access", FakeInjectorStatus.new(false)] }) do
      assert_raises(RuntimeError) { injector.inject("git status") }
    end
  end

  def test_unsupported_tool_raises
    injector = VoiceR::Injector.new(tool: "something-else")
    assert_raises(RuntimeError) { injector.inject("git status") }
  end

  def test_ime_switch_disabled_by_default_makes_no_ibus_calls
    injector = VoiceR::Injector.new(tool: "ydotool")
    calls = []

    Open3.stub(:capture3, lambda { |*argv|
      calls << argv
      ["", "", FakeInjectorStatus.new(true)]
    }) do
      injector.inject("git status")
    end

    assert_equal [["ydotool", "type", "git status"]], calls
  end

  # Fakes ibus's real quirk (confirmed on this machine): "ibus engine <name>"
  # can report a non-zero exit status for reasons unrelated to whether the
  # switch worked (it also shells out to setxkbmap, which may be missing),
  # so the fake always reports success=false for the set form while still
  # updating the tracked state - exercising that Injector verifies by
  # re-querying rather than trusting that exit status.
  def stateful_ibus_responder(initial_engine, calls)
    state = { engine: initial_engine }
    lambda do |*argv|
      calls << argv
      if argv == ["ibus", "engine"]
        [state[:engine] + "\n", "", FakeInjectorStatus.new(true)]
      elsif argv[0..1] == ["ibus", "engine"] && argv.size == 3
        state[:engine] = argv[2]
        ["", "", FakeInjectorStatus.new(false)]
      elsif argv == ["ydotool", "type", "git status"]
        ["", "", FakeInjectorStatus.new(true)]
      else
        raise "unexpected argv #{argv.inspect}"
      end
    end
  end

  def test_switches_ibus_engine_around_injection_when_configured
    injector = VoiceR::Injector.new(tool: "ydotool", ime_direct_engine: "xkb:us::eng")
    calls = []

    Open3.stub(:capture3, stateful_ibus_responder("mozc-jp", calls)) do
      injector.inject("git status")
    end

    assert_equal [
      ["ibus", "engine"],
      ["ibus", "engine", "xkb:us::eng"],
      ["ibus", "engine"],
      ["ydotool", "type", "git status"],
      ["ibus", "engine", "mozc-jp"],
      ["ibus", "engine"]
    ], calls
  end

  def test_skips_switch_when_already_on_direct_engine
    injector = VoiceR::Injector.new(tool: "ydotool", ime_direct_engine: "xkb:us::eng")
    calls = []

    Open3.stub(:capture3, stateful_ibus_responder("xkb:us::eng", calls)) do
      injector.inject("git status")
    end

    assert_equal [["ibus", "engine"], ["ydotool", "type", "git status"]], calls
  end

  def test_restores_engine_even_when_injection_fails
    injector = VoiceR::Injector.new(tool: "ydotool", ime_direct_engine: "xkb:us::eng")
    calls = []
    state = { engine: "mozc-jp" }

    Open3.stub(:capture3, lambda { |*argv|
      calls << argv
      if argv == ["ibus", "engine"]
        [state[:engine] + "\n", "", FakeInjectorStatus.new(true)]
      elsif argv[0..1] == ["ibus", "engine"] && argv.size == 3
        state[:engine] = argv[2]
        ["", "", FakeInjectorStatus.new(false)]
      elsif argv == ["ydotool", "type", "git status"]
        ["", "uinput error", FakeInjectorStatus.new(false)]
      else
        raise "unexpected argv #{argv.inspect}"
      end
    }) do
      assert_raises(RuntimeError) { injector.inject("git status") }
    end

    assert_equal [
      ["ibus", "engine"],
      ["ibus", "engine", "xkb:us::eng"],
      ["ibus", "engine"],
      ["ydotool", "type", "git status"],
      ["ibus", "engine", "mozc-jp"],
      ["ibus", "engine"]
    ], calls
  end

  def test_continues_without_switching_when_ibus_missing
    injector = VoiceR::Injector.new(tool: "ydotool", ime_direct_engine: "xkb:us::eng")
    calls = []

    Open3.stub(:capture3, lambda { |*argv|
      raise Errno::ENOENT, "ibus" if argv[0] == "ibus"

      calls << argv
      ["", "", FakeInjectorStatus.new(true)]
    }) do
      injector.inject("git status")
    end

    assert_equal [["ydotool", "type", "git status"]], calls
  end

  def test_ascii_text_routes_to_type_path_unchanged
    injector = VoiceR::Injector.new(tool: "ydotool")
    calls = []

    Open3.stub(:capture3, lambda { |*argv, **_kwargs|
      calls << argv
      ["", "", FakeInjectorStatus.new(true)]
    }) do
      injector.inject("git status")
    end

    assert_equal [["ydotool", "type", "git status"]], calls
  end

  # wl-copy forks into the background to stay alive serving the clipboard
  # (confirmed on this machine: Open3.capture3 hangs forever on it, since
  # the backgrounded process inherits and holds open the pipes Open3 sets
  # up for stdout/stderr). Injector therefore invokes it via Process.spawn
  # (output discarded, so nothing waits on a pipe) + Process.wait2 (waits
  # only on this specific child's exit) - so the fake must stub those two
  # instead of Open3.capture3 for "wl-copy" specifically, while wl-paste and
  # ydotool key (which don't fork) still go through Open3.capture3.
  # Returns [capture3_stub, spawn_stub, wait2_stub] for use with
  # with_paste_stubs.
  def stateful_clipboard_responder(initial_clipboard, calls, ydotool_key_ok: true, wl_copy_ok: true)
    state = { clipboard: initial_clipboard, pids: {}, next_pid: 9000 }

    capture3_stub = lambda do |*argv, **kwargs|
      calls << [argv, kwargs]
      case argv
      when ["wl-paste", "--no-newline"]
        if state[:clipboard].nil?
          ["", "", FakeInjectorStatus.new(false)]
        else
          [state[:clipboard], "", FakeInjectorStatus.new(true)]
        end
      when ["ydotool", "key", "29:1", "47:1", "47:0", "29:0"]
        ["", "", FakeInjectorStatus.new(ydotool_key_ok)]
      else
        raise "unexpected Open3.capture3 argv #{argv.inspect}"
      end
    end

    spawn_stub = lambda do |*argv, **_kwargs|
      raise "unexpected Process.spawn argv #{argv.inspect}" unless argv.first == "wl-copy"

      text = argv[1]
      calls << [["wl-copy", text], {}]
      state[:clipboard] = text if wl_copy_ok
      pid = state[:next_pid]
      state[:next_pid] += 1
      state[:pids][pid] = wl_copy_ok
      pid
    end

    wait2_stub = lambda do |pid|
      ok = state[:pids].fetch(pid)
      [pid, FakeInjectorStatus.new(ok, ok ? 0 : 1)]
    end

    [capture3_stub, spawn_stub, wait2_stub]
  end

  def with_paste_stubs(capture3_stub, spawn_stub, wait2_stub, &block)
    Open3.stub(:capture3, capture3_stub) do
      Process.stub(:spawn, spawn_stub) do
        Process.stub(:wait2, wait2_stub, &block)
      end
    end
  end

  def test_non_ascii_text_routes_to_paste_path
    injector = VoiceR::Injector.new(tool: "ydotool", clipboard_paste_delay: 0)
    calls = []

    with_paste_stubs(*stateful_clipboard_responder("previous clip", calls)) do
      injector.inject("こんにちは")
    end

    assert_equal [
      [["wl-paste", "--no-newline"], {}],
      [["wl-copy", "こんにちは"], {}],
      [["ydotool", "key", "29:1", "47:1", "47:0", "29:0"], {}],
      [["wl-copy", "previous clip"], {}]
    ], calls
  end

  def test_paste_path_ignores_ime_direct_engine
    injector = VoiceR::Injector.new(tool: "ydotool", ime_direct_engine: "xkb:us::eng", clipboard_paste_delay: 0)
    calls = []
    capture3_stub, spawn_stub, wait2_stub = stateful_clipboard_responder("previous clip", calls)

    with_paste_stubs(
      lambda { |*argv, **kwargs|
        raise "unexpected ibus call: #{argv.inspect}" if argv.first == "ibus"

        capture3_stub.call(*argv, **kwargs)
      },
      spawn_stub, wait2_stub
    ) do
      injector.inject("こんにちは")
    end

    refute(calls.any? { |argv, _kwargs| argv.first == "ibus" })
  end

  def test_paste_path_skips_restore_when_clipboard_was_empty
    injector = VoiceR::Injector.new(tool: "ydotool", clipboard_paste_delay: 0)
    calls = []

    with_paste_stubs(*stateful_clipboard_responder(nil, calls)) do
      injector.inject("こんにちは")
    end

    assert_equal [
      [["wl-paste", "--no-newline"], {}],
      [["wl-copy", "こんにちは"], {}],
      [["ydotool", "key", "29:1", "47:1", "47:0", "29:0"], {}]
    ], calls
  end

  def test_paste_path_restores_empty_string_when_clipboard_was_empty_string
    injector = VoiceR::Injector.new(tool: "ydotool", clipboard_paste_delay: 0)
    calls = []

    with_paste_stubs(*stateful_clipboard_responder("", calls)) do
      injector.inject("こんにちは")
    end

    assert_equal [
      [["wl-paste", "--no-newline"], {}],
      [["wl-copy", "こんにちは"], {}],
      [["ydotool", "key", "29:1", "47:1", "47:0", "29:0"], {}],
      [["wl-copy", ""], {}]
    ], calls
  end

  def test_paste_path_raises_when_wl_copy_missing
    injector = VoiceR::Injector.new(tool: "ydotool", clipboard_paste_delay: 0)

    Open3.stub(:capture3, ->(*_argv, **_kwargs) { ["", "", FakeInjectorStatus.new(true)] }) do
      Process.stub(:spawn, ->(*argv, **_kwargs) { raise Errno::ENOENT, "wl-copy" if argv.first == "wl-copy" }) do
        error = assert_raises(RuntimeError) { injector.inject("こんにちは") }
        assert_match(/wl-clipboard/, error.message)
      end
    end
  end

  def test_paste_path_raises_when_wl_copy_write_fails
    injector = VoiceR::Injector.new(tool: "ydotool", clipboard_paste_delay: 0)
    calls = []

    with_paste_stubs(*stateful_clipboard_responder("previous clip", calls, wl_copy_ok: false)) do
      assert_raises(RuntimeError) { injector.inject("こんにちは") }
    end
  end

  def test_paste_path_warns_and_continues_when_wl_paste_missing
    injector = VoiceR::Injector.new(tool: "ydotool", clipboard_paste_delay: 0)
    calls = []
    capture3_stub, spawn_stub, wait2_stub = stateful_clipboard_responder("previous clip", calls)

    with_paste_stubs(
      lambda { |*argv, **kwargs|
        raise Errno::ENOENT, "wl-paste" if argv == ["wl-paste", "--no-newline"]

        capture3_stub.call(*argv, **kwargs)
      },
      spawn_stub, wait2_stub
    ) do
      injector.inject("こんにちは")
    end

    assert_equal [
      [["wl-copy", "こんにちは"], {}],
      [["ydotool", "key", "29:1", "47:1", "47:0", "29:0"], {}]
    ], calls
  end

  def test_paste_path_restores_clipboard_even_on_ydotool_key_failure
    injector = VoiceR::Injector.new(tool: "ydotool", clipboard_paste_delay: 0)
    calls = []

    with_paste_stubs(*stateful_clipboard_responder("previous clip", calls, ydotool_key_ok: false)) do
      assert_raises(RuntimeError) { injector.inject("こんにちは") }
    end

    assert_equal [
      [["wl-paste", "--no-newline"], {}],
      [["wl-copy", "こんにちは"], {}],
      [["ydotool", "key", "29:1", "47:1", "47:0", "29:0"], {}],
      [["wl-copy", "previous clip"], {}]
    ], calls
  end
end
