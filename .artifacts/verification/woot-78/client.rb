require 'open3'

root = File.expand_path('../../..', __dir__)
construction = File.readlines(File.join(root, 'docker/entrypoints/rails.sh'))[12, 2].join
%w[postgres postgresql].each do |scheme|
  env = { 'PATH' => ENV.fetch('PATH'), 'DATABASE_URL' => "#{scheme}://probe:woot78_synthetic_only@127.0.0.1/database", 'POSTGRES_PORT' => '6543' }
  out, err, status = Open3.capture3(env, 'sh', '-xc', construction + "$PG_READY -t 1\n", chdir: root, unsetenv_others: true)
  puts "#{scheme}:\n#{out}#{err}exit=#{status.exitstatus}"
  raise 'Password leaked' if (out + err).include?('woot78_synthetic_only')
  raise 'Expected bounded no-response result (not database-health proof)' unless status.exitstatus == 2
end
