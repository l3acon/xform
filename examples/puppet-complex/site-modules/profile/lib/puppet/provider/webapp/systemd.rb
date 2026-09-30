require 'puppet/provider'
require 'fileutils'

Puppet::Type.type(:webapp).provide(:systemd) do
  desc "Manages webapp via systemd service units"

  confine :osfamily => :RedHat

  commands :systemctl => '/usr/bin/systemctl'

  def create
    setup_directories
    generate_service_unit
    systemctl('daemon-reload')
    systemctl('enable', '--now', service_name)
  end

  def destroy
    systemctl('disable', '--now', service_name) if exists?
    FileUtils.rm_f(service_unit_path)
    systemctl('daemon-reload')
  end

  def exists?
    File.exist?(service_unit_path) && File.directory?(app_dir)
  end

  def running
    systemctl('is-active', service_name)
    :true
  rescue Puppet::ExecutionFailure
    :false
  end

  def running=(value)
    if value == :true
      systemctl('start', service_name)
    else
      systemctl('stop', service_name)
    end
  end

  def version
    jar = Dir.glob("#{app_dir}/bin/*.jar").first
    return nil unless jar
    output = `/usr/bin/unzip -p #{jar} META-INF/MANIFEST.MF 2>/dev/null`
    match = output.match(/Implementation-Version:\s*(.+)/)
    match ? match[1].strip : 'unknown'
  end

  def version=(value)
    Puppet.notice("Version management requires deploying a new jar — skipping")
  end

  private

  def app_dir
    "#{resource[:deploy_dir]}/#{resource[:name]}"
  end

  def service_name
    resource[:name]
  end

  def service_unit_path
    "/etc/systemd/system/#{service_name}.service"
  end

  def setup_directories
    ['', '/bin', '/config', '/logs'].each do |sub|
      dir = "#{app_dir}#{sub}"
      FileUtils.mkdir_p(dir)
      FileUtils.chown(resource[:user], resource[:group], dir)
    end
  end

  def generate_service_unit
    unit = <<~UNIT
      [Unit]
      Description=#{resource[:name]} Application
      After=network.target

      [Service]
      Type=simple
      User=#{resource[:user]}
      Group=#{resource[:group]}
      WorkingDirectory=#{app_dir}
      ExecStart=/usr/bin/java -jar #{app_dir}/bin/#{resource[:name]}.jar
      Restart=always

      [Install]
      WantedBy=multi-user.target
    UNIT
    File.write(service_unit_path, unit)
  end
end
