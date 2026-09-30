# profile::web — Apache httpd with vhosts and optional SSL
class profile::web (
  Integer          $http_port              = lookup('profile::web::http_port'),
  Integer          $https_port             = lookup('profile::web::https_port'),
  String           $docroot                = lookup('profile::web::docroot'),
  Integer          $max_keepalive_requests = lookup('profile::web::max_keepalive_requests'),
  Integer          $keepalive_timeout      = lookup('profile::web::keepalive_timeout'),
  String           $server_tokens          = lookup('profile::web::server_tokens'),
  Hash             $vhosts                 = lookup('profile::web::vhosts'),
  String           $package_name           = lookup('profile::web::package_name'),
  String           $service_name           = lookup('profile::web::service_name'),
  String           $config_dir             = lookup('profile::web::config_dir'),
  String           $ssl_package            = lookup('profile::web::ssl_package'),
) {

  package { $package_name:
    ensure => installed,
  }

  package { $ssl_package:
    ensure  => installed,
    require => Package[$package_name],
  }

  file { "${config_dir}/conf/httpd.conf":
    ensure  => file,
    content => template('profile/httpd.conf.erb'),
    require => Package[$package_name],
    notify  => Service[$service_name],
  }

  file { $docroot:
    ensure  => directory,
    owner   => 'apache',
    group   => 'apache',
    mode    => '0755',
    require => Package[$package_name],
  }

  file { "${docroot}/index.html":
    ensure  => file,
    content => template('profile/index.html.erb'),
    owner   => 'apache',
    group   => 'apache',
    mode    => '0644',
    require => File[$docroot],
  }

  # Dynamic vhost generation from Hiera data
  $vhosts.each |String $name, Hash $vhost| {
    file { "${config_dir}/conf.d/${name}.conf":
      ensure  => file,
      content => template('profile/vhost.conf.erb'),
      require => Package[$package_name],
      notify  => Service[$service_name],
    }
  }

  # Firewall rules
  exec { 'web-firewall-http':
    command => "/usr/bin/firewall-cmd --permanent --add-port=${http_port}/tcp",
    unless  => "/usr/bin/firewall-cmd --query-port=${http_port}/tcp",
    notify  => Exec['web-firewall-reload'],
  }

  exec { 'web-firewall-https':
    command => "/usr/bin/firewall-cmd --permanent --add-port=${https_port}/tcp",
    unless  => "/usr/bin/firewall-cmd --query-port=${https_port}/tcp",
    notify  => Exec['web-firewall-reload'],
  }

  exec { 'web-firewall-reload':
    command     => '/usr/bin/firewall-cmd --reload',
    refreshonly => true,
  }

  service { $service_name:
    ensure    => running,
    enable    => true,
    require   => Package[$package_name],
    subscribe => File["${config_dir}/conf/httpd.conf"],
  }
}
