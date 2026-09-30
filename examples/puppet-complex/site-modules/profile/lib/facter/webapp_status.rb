# Custom fact: webapp_status
# Reports the status of deployed web applications
Facter.add(:webapp_status) do
  confine :osfamily => 'RedHat'
  setcode do
    apps = {}
    deploy_dir = '/opt/apps'
    if File.directory?(deploy_dir)
      Dir.entries(deploy_dir).select { |d| d != '.' && d != '..' }.each do |app|
        jar = Dir.glob("#{deploy_dir}/#{app}/bin/*.jar").first
        if jar
          pid_running = Facter::Core::Execution.execute(
            "pgrep -f '#{File.basename(jar)}' 2>/dev/null"
          ).strip
          apps[app] = {
            'installed' => true,
            'running'   => !pid_running.empty?,
            'jar'       => File.basename(jar),
          }
        end
      end
    end
    apps
  end
end

Facter.add(:webapp_count) do
  setcode do
    status = Facter.value(:webapp_status)
    status.is_a?(Hash) ? status.keys.length : 0
  end
end
