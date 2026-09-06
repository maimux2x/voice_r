require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test" << "lib"
  t.test_files = FileList["test/**/*_test.rb"]
end

desc "Guard against shell-executing recognized/expanded text (safety invariant)"
task :safety_check do
  offenders = []
  Dir["lib/**/*.rb"].each do |file|
    File.readlines(file).each_with_index do |line, idx|
      next if line.strip.start_with?("#")
      if line =~ /`[^`]*`/ || line =~ /\bsystem\(\s*"/ || line =~ /IO\.popen\(\s*true/ || line =~ /%x\{/
        offenders << "#{file}:#{idx + 1}: #{line.strip}"
      end
    end
  end
  unless offenders.empty?
    warn "Potential shell-string invocation found (must use argv-array Open3/Process.spawn instead):"
    offenders.each { |o| warn "  #{o}" }
    abort
  end
  puts "safety_check: OK (no shell-string process invocations found)"
end

task default: %i[test safety_check]
