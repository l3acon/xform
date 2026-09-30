# profile::base — system baseline
class profile::base (
  Array[String]    $ntp_servers        = lookup('profile::base::ntp_servers'),
  String           $timezone           = lookup('profile::base::timezone'),
  Boolean          $manage_firewall    = lookup('profile::base::manage_firewall'),
  Array[Hash]      $admin_users        = lookup('profile::base::admin_users'),
  String           $package_provider   = lookup('profile::base::package_provider', String, 'first', 'yum'),
  String           $firewall_provider  = lookup('profile::base::firewall_provider', String, 'first', 'iptables'),
  Array[String]    $extra_packages     = lookup('profile::base::extra_packages', Array, 'first', []),
) {

  # Timezone
  file { '/etc/localtime':
    ensure => link,
    target => "/usr/share/zoneinfo/${timezone}",
  }

  # NTP / Chrony
  package { 'chrony':
    ensure => installed,
  }

  file { '/etc/chrony.conf':
    ensure  => file,
    content => template('profile/chrony.conf.erb'),
    require => Package['chrony'],
    notify  => Service['chronyd'],
  }

  service { 'chronyd':
    ensure  => running,
    enable  => true,
    require => Package['chrony'],
  }

  # Extra packages
  $extra_packages.each |String $pkg| {
    package { $pkg:
      ensure => installed,
    }
  }

  # Admin users
  $admin_users.each |Hash $user| {
    user { $user['name']:
      ensure     => present,
      managehome => true,
      groups     => $user['groups'],
      shell      => '/bin/bash',
    }

    ssh_authorized_key { "${user['name']}_key":
      ensure => present,
      user   => $user['name'],
      type   => 'ssh-ed25519',
      key    => $user['ssh_key'],
    }
  }

  # Firewall baseline
  if $manage_firewall {
    package { $firewall_provider:
      ensure => installed,
    }

    service { $firewall_provider:
      ensure  => running,
      enable  => true,
      require => Package[$firewall_provider],
    }
  }
}
