require_relative "../test_helper"
require "voice_r/state_machine"

class StateMachineTest < Minitest::Test
  def test_starts_idle
    sm = VoiceR::StateMachine.new
    assert_equal :idle, sm.state
    assert sm.idle?
    refute sm.recording?
  end

  def test_valid_transition_idle_to_recording
    sm = VoiceR::StateMachine.new
    sm.transition_to!(:recording)
    assert_equal :recording, sm.state
    assert sm.recording?
  end

  def test_invalid_transition_raises
    sm = VoiceR::StateMachine.new
    assert_raises(VoiceR::StateMachine::InvalidTransition) { sm.transition_to!(:injecting) }
    assert_equal :idle, sm.state
  end

  def test_full_cycle_through_injecting
    sm = VoiceR::StateMachine.new
    sm.transition_to!(:recording)
    sm.transition_to!(:transcribing)
    sm.transition_to!(:injecting)
    sm.transition_to!(:idle)
    assert_equal :idle, sm.state
  end

  def test_transcribing_can_skip_injecting_back_to_idle
    sm = VoiceR::StateMachine.new
    sm.transition_to!(:recording)
    sm.transition_to!(:transcribing)
    sm.transition_to!(:idle)
    assert_equal :idle, sm.state
  end

  def test_cannot_double_start_recording
    sm = VoiceR::StateMachine.new(:recording)
    assert_raises(VoiceR::StateMachine::InvalidTransition) { sm.transition_to!(:recording) }
  end
end
