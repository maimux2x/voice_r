require_relative "lib/voice_r/version"

Gem::Specification.new do |spec|
  spec.name = "voice_r"
  spec.version = VoiceR::VERSION
  spec.authors = ["maimux2x"]
  spec.summary = "Personal voice dictation tool for Linux (Git/shell commands, vocabulary expansion)"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.files = Dir["lib/**/*.rb", "bin/*", "config/*.example"]
  spec.bindir = "bin"
  spec.executables = ["voice_r"]

  spec.add_dependency "text", "~> 1.3"
  spec.add_dependency "logger", "~> 1.6"

  spec.add_development_dependency "minitest", "~> 5.0"
  spec.add_development_dependency "rake", "~> 13.0"
end
