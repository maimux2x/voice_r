module VoiceR
  class StateMachine
    class InvalidTransition < StandardError; end

    TRANSITIONS = {
      idle: %i[recording],
      recording: %i[transcribing],
      transcribing: %i[injecting idle],
      injecting: %i[idle]
    }.freeze

    attr_reader :state

    def initialize(state = :idle)
      @state = state
    end

    def transition_to!(new_state)
      allowed = TRANSITIONS.fetch(@state, [])
      unless allowed.include?(new_state)
        raise InvalidTransition, "cannot transition from #{@state} to #{new_state}"
      end

      @state = new_state
    end

    def idle?
      state == :idle
    end

    def recording?
      state == :recording
    end
  end
end
