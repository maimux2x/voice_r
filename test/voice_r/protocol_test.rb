require_relative "../test_helper"
require "voice_r/protocol"

class ProtocolTest < Minitest::Test
  def test_parses_command_without_arg
    cmd = VoiceR::Protocol.parse("STATUS\n")
    assert_equal "STATUS", cmd.name
    assert_nil cmd.arg
  end

  def test_parses_command_with_arg
    cmd = VoiceR::Protocol.parse("TOGGLE ja")
    assert_equal "TOGGLE", cmd.name
    assert_equal "ja", cmd.arg
  end

  def test_upcases_command_name_but_not_arg
    cmd = VoiceR::Protocol.parse("toggle en")
    assert_equal "TOGGLE", cmd.name
    assert_equal "en", cmd.arg
  end

  def test_empty_line_returns_nil_name
    cmd = VoiceR::Protocol.parse("")
    assert_nil cmd.name
    assert_nil cmd.arg
  end

  def test_whitespace_only_line_returns_nil_name
    cmd = VoiceR::Protocol.parse("   \n")
    assert_nil cmd.name
  end
end
