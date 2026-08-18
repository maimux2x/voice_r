require "open3"

module VoiceR
  class Notifier
    def initialize(logger: nil)
      @logger = logger
      @available = detect_notify_send
    end

    # title/body may contain the recognized transcript text (from the user's own
    # speech). Passed to notify-send as discrete argv elements, never through a
    # shell, so no injection risk regardless of content.
    def notify(title, body)
      return unless @available

      Open3.capture3("notify-send", title, body)
    rescue StandardError => e
      @logger&.warn("notifier: notify-send failed: #{e.message}")
    end

    private

    def detect_notify_send
      _, _, status = Open3.capture3("which", "notify-send")
      status.success?
    rescue StandardError
      false
    end
  end
end
