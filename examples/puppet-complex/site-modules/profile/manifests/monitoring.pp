# profile::monitoring — Prometheus node exporter + custom metrics
class profile::monitoring (
  Boolean          $enable_prometheus    = lookup('profile::monitoring::enable_prometheus'),
  Integer          $node_exporter_port   = lookup('profile::monitoring::node_exporter_port'),
  Array[Hash]      $custom_metrics       = lookup('profile::monitoring::custom_metrics'),
  String           $node_exporter_package = lookup('profile::monitoring::node_exporter_package',
                                                    String, 'first', 'node_exporter'),
) {

  if $enable_prometheus {
    package { $node_exporter_package:
      ensure => installed,
    }

    file { '/etc/sysconfig/node_exporter':
      ensure  => file,
      content => template('profile/node_exporter_sysconfig.erb'),
      notify  => Service['node_exporter'],
    }

    unless $custom_metrics.empty {
      file { '/var/lib/node_exporter/textfile':
        ensure => directory,
        owner  => 'nobody',
        group  => 'nobody',
        mode   => '0755',
      }

      file { '/var/lib/node_exporter/textfile/custom.prom':
        ensure  => file,
        content => template('profile/custom_metrics.prom.erb'),
        owner   => 'nobody',
        require => File['/var/lib/node_exporter/textfile'],
      }
    }

    service { 'node_exporter':
      ensure  => running,
      enable  => true,
      require => Package[$node_exporter_package],
    }

    exec { 'monitoring-firewall-port':
      command => "/usr/bin/firewall-cmd --permanent --add-port=${node_exporter_port}/tcp",
      unless  => "/usr/bin/firewall-cmd --query-port=${node_exporter_port}/tcp",
      notify  => Exec['monitoring-firewall-reload'],
    }

    exec { 'monitoring-firewall-reload':
      command     => '/usr/bin/firewall-cmd --reload',
      refreshonly => true,
    }
  }
}
