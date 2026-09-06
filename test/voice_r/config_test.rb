require_relative "../test_helper"
require "voice_r/config"
require "tmpdir"

class ConfigTest < Minitest::Test
  def test_defaults_when_no_file
    Dir.mktmpdir do |dir|
      config = VoiceR::Config.load(File.join(dir, "nonexistent.yml"))
      assert_equal "http://127.0.0.1:8081", config.whisper_server_url
      assert_equal "ja", config.whisper_language
      assert_in_delta 0.82, config.match_threshold
      assert_equal "", config.whisper_prompt
      assert_equal "parecord", config.capture_cmd
      assert_equal 16000, config.sample_rate
      assert_equal "ydotool", config.injection_tool
      assert_equal "", config.ime_direct_engine
    end
  end

  def test_overrides_merge_with_defaults
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.yml")
      File.write(path, <<~YAML)
        whisper:
          match_threshold: 0.9
          language: ja
          prompt: "git status, git push"
      YAML

      config = VoiceR::Config.load(path)
      assert_in_delta 0.9, config.match_threshold
      assert_equal "ja", config.whisper_language
      assert_equal "git status, git push", config.whisper_prompt
      assert_equal "http://127.0.0.1:8081", config.whisper_server_url
      assert_equal "parecord", config.capture_cmd
    end
  end

  def test_injection_overrides_merge_with_defaults
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.yml")
      File.write(path, <<~YAML)
        injection:
          ime_direct_engine: "xkb:us::eng"
      YAML

      config = VoiceR::Config.load(path)
      assert_equal "ydotool", config.injection_tool
      assert_equal "xkb:us::eng", config.ime_direct_engine
    end
  end
end
