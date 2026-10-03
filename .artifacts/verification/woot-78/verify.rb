require 'open3'
require 'tmpdir'

ROOT = File.expand_path('../../..', __dir__)
HELPER = 'docker/entrypoints/helpers/pg_database_url.rb'
PASSWORD = 'woot78_synthetic_only'
cases = []
%w[postgres postgresql].each do |scheme|
  [nil, '', '6543'].each do |port|
    cases << ["#{scheme} omitted / separate #{port.inspect}", "#{scheme}://probe:#{PASSWORD}@url-host/database", port, '5432']
  end
  %w[5432 6544].each do |port|
    cases << ["#{scheme} explicit #{port}", "#{scheme}://probe:#{PASSWORD}@url-host:#{port}/database", '6543', port]
  end
end
[nil, ''].each do |url|
  [nil, '', '6543'].each do |port|
    cases << ["URL #{url.inspect} / separate #{port.inspect}", url, port, port.nil? || port.empty? ? '5432' : port]
  end
end
raise 'Incomplete matrix' unless cases.length == 16

# Use the entrypoint's actual two lines, without its startup loop or bundle install.
construction = File.readlines(File.join(ROOT, 'docker/entrypoints/rails.sh'))[12, 2].join
failures = 0
Dir.mktmpdir('woot78-') do |dir|
  stub = File.join(dir, 'pg_isready')
  File.write(stub, "#!/bin/sh\nprintf '%s\\n' \"$@\"\n")
  File.chmod(0o755, stub)
  cases.each do |label, url, port, expected_port|
    env = { 'PATH' => "#{dir}:#{ENV.fetch('PATH')}", 'DATABASE_URL' => url,
            'POSTGRES_HOST' => 'separate-host', 'POSTGRES_PORT' => port, 'POSTGRES_USERNAME' => 'separate-user' }
    exports, error, helper_status = Open3.capture3(env, HELPER, chdir: ROOT, unsetenv_others: true)
    output, shell_error, shell_status = Open3.capture3(env, 'sh', '-xc', construction + "$PG_READY\n", chdir: ROOT, unsetenv_others: true)
    url_present = url && !url.empty?
    expected = ['-h', url_present ? 'url-host' : 'separate-host', '-p', expected_port, '-U', url_present ? 'probe' : 'separate-user']
    passed = helper_status.success? && shell_status.success? && output.lines.map(&:chomp) == expected &&
             ![exports, error, output, shell_error].join.include?(PASSWORD)
    failures += 1 unless passed
    puts "#{passed ? 'PASS' : 'FAIL'} #{label}: argv=#{output.lines.map(&:chomp).inspect}"
  end
end
puts "#{cases.length - failures}/#{cases.length} passed"
exit(failures.zero? ? 0 : 1)
