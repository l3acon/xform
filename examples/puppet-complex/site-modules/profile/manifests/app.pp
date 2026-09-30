# profile::app — Java application deployment
class profile::app (
  String           $app_name       = lookup('profile::app::app_name'),
  String           $app_user       = lookup('profile::app::app_user'),
  String           $app_group      = lookup('profile::app::app_group'),
  Integer          $app_port       = lookup('profile::app::app_port'),
  String           $deploy_dir     = lookup('profile::app::deploy_dir'),
  String           $log_level      = lookup('profile::app::log_level'),
  String           $environment    = lookup('profile::app::environment'),
  String           $java_opts      = lookup('profile::app::java_opts'),
  String           $database_host  = lookup('profile::app::database_host'),
  Integer          $database_port  = lookup('profile::app::database_port'),
  String           $database_name  = lookup('profile::app::database_name'),
) {

  # Java runtime
  package { 'java-17-openjdk-headless':
    ensure => installed,
  }

  # App user/group
  group { $app_group:
    ensure => present,
  }

  user { $app_user:
    ensure     => present,
    gid        => $app_group,
    home       => $deploy_dir,
    managehome => true,
    shell      => '/sbin/nologin',
    require    => Group[$app_group],
  }

  # Deploy directory structure
  [$deploy_dir, "${deploy_dir}/bin", "${deploy_dir}/config", "${deploy_dir}/logs"].each |String $dir| {
    file { $dir:
      ensure  => directory,
      owner   => $app_user,
      group   => $app_group,
      mode    => '0755',
      require => User[$app_user],
    }
  }

  # Application config
  file { "${deploy_dir}/config/application.yml":
    ensure  => file,
    content => template('profile/application.yml.erb'),
    owner   => $app_user,
    group   => $app_group,
    mode    => '0640',
    notify  => Service[$app_name],
  }

  # Systemd unit file
  file { "/etc/systemd/system/${app_name}.service":
    ensure  => file,
    content => template('profile/app.service.erb'),
    notify  => Exec['app-systemd-reload'],
  }

  exec { 'app-systemd-reload':
    command     => '/usr/bin/systemctl daemon-reload',
    refreshonly => true,
  }

  # Firewall for app port
  exec { 'app-firewall-port':
    command => "/usr/bin/firewall-cmd --permanent --add-port=${app_port}/tcp",
    unless  => "/usr/bin/firewall-cmd --query-port=${app_port}/tcp",
    notify  => Exec['app-firewall-reload'],
  }

  exec { 'app-firewall-reload':
    command     => '/usr/bin/firewall-cmd --reload',
    refreshonly => true,
  }

  service { $app_name:
    ensure    => running,
    enable    => true,
    require   => [
      File["/etc/systemd/system/${app_name}.service"],
      Package['java-17-openjdk-headless'],
    ],
    subscribe => File["${deploy_dir}/config/application.yml"],
  }
}
