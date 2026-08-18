require_relative "../test_helper"
require "voice_r/injector"

FakeInjectorStatus = Struct.new(:success?)

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
end
