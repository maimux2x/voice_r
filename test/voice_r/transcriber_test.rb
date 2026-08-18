require_relative "../test_helper"
require "voice_r/transcriber"
require "tmpdir"
require "fileutils"

FakeStatus = Struct.new(:success?)

class TranscriberTest < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir
    @wav_path = File.join(@tmpdir, "fake.wav")
    # Content is irrelevant (Open3 is stubbed in these tests) - only needs to be
    # bigger than Transcriber::EMPTY_WAV_MAX_BYTES to pass the empty-file guard.
    File.write(@wav_path, "x" * 1000)
  end

  def teardown
    FileUtils.remove_entry(@tmpdir)
  end

  def test_transcribe_extracts_text_from_json
    transcriber = VoiceR::Transcriber.new(server_url: "http://127.0.0.1:8081")
    fake_status = FakeStatus.new(true)

    Open3.stub(:capture3, ->(*_argv) { ['{"text":" git status "}', "", fake_status] }) do
      assert_equal "git status", transcriber.transcribe(@wav_path)
    end
  end

  def test_transcribe_raises_on_curl_failure
    transcriber = VoiceR::Transcriber.new(server_url: "http://127.0.0.1:8081")
    fake_status = FakeStatus.new(false)

    Open3.stub(:capture3, ->(*_argv) { ["", "connection refused", fake_status] }) do
      assert_raises(RuntimeError) { transcriber.transcribe(@wav_path) }
    end
  end

  def test_transcribe_builds_argv_without_shell_string
    transcriber = VoiceR::Transcriber.new(server_url: "http://127.0.0.1:8081", language: "ja")
    captured_argv = nil
    fake_status = FakeStatus.new(true)

    Open3.stub(:capture3, lambda { |*argv|
      captured_argv = argv
      ['{"text":""}', "", fake_status]
    }) do
      transcriber.transcribe(@wav_path)
    end

    assert_kind_of Array, captured_argv
    assert_equal "curl", captured_argv.first
    assert_includes captured_argv, "file=@#{@wav_path}"
    assert_includes captured_argv, "language=ja"
    assert_includes captured_argv, "suppress_nst=true"
  end

  def test_transcribe_includes_prompt_when_present_and_omits_when_blank
    transcriber = VoiceR::Transcriber.new(server_url: "http://127.0.0.1:8081", language: "ja")
    fake_status = FakeStatus.new(true)

    with_prompt = nil
    Open3.stub(:capture3, lambda { |*argv| with_prompt = argv; ['{"text":""}', "", fake_status] }) do
      transcriber.transcribe(@wav_path, prompt: "git status, git push")
    end
    assert_includes with_prompt, "prompt=git status, git push"

    without_prompt = nil
    Open3.stub(:capture3, lambda { |*argv| without_prompt = argv; ['{"text":""}', "", fake_status] }) do
      transcriber.transcribe(@wav_path, prompt: "")
    end
    refute without_prompt.any? { |a| a.start_with?("prompt=") }
  end

  def test_transcribe_raises_without_calling_curl_when_wav_is_empty
    empty_path = File.join(@tmpdir, "empty.wav")
    File.write(empty_path, "x" * VoiceR::Transcriber::EMPTY_WAV_MAX_BYTES)
    transcriber = VoiceR::Transcriber.new(server_url: "http://127.0.0.1:8081")

    called = false
    Open3.stub(:capture3, ->(*_argv) { called = true; ['{"text":""}', "", FakeStatus.new(true)] }) do
      assert_raises(RuntimeError) { transcriber.transcribe(empty_path) }
    end
    refute called, "should short-circuit before invoking curl"
  end
end
