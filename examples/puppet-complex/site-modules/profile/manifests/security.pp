# profile::security — hardening baseline
class profile::security (
  Integer          $password_max_age      = lookup('profile::security::password_max_age'),
  Integer          $password_min_length   = lookup('profile::security::password_min_length'),
  String           $selinux_mode          = lookup('profile::security::selinux_mode'),
  Array[String]    $allowed_ssh_networks  = lookup('profile::security::allowed_ssh_networks'),
  Integer          $fail2ban_maxretry     = lookup('profile::security::fail2ban_maxretry'),
) {

  # SELinux
  file { '/etc/selinux/config':
    ensure  => file,
    content => template('profile/selinux_config.erb'),
  }

  exec { 'selinux-set-mode':
    command => "/usr/sbin/setenforce ${selinux_mode == 'enforcing' ? { true => '1', false => '0' }}",
    unless  => "/usr/sbin/getenforce | /usr/bin/grep -qi ${selinux_mode}",
  }

  # SSH hardening
  file { '/etc/ssh/sshd_config.d/hardening.conf':
    ensure  => file,
    content => template('profile/sshd_hardening.conf.erb'),
    notify  => Service['sshd'],
  }

  service { 'sshd':
    ensure => running,
    enable => true,
  }

  # Password policy
  file { '/etc/login.defs':
    ensure  => file,
    content => template('profile/login.defs.erb'),
  }

  # Fail2ban
  package { 'fail2ban':
    ensure => installed,
  }

  file { '/etc/fail2ban/jail.local':
    ensure  => file,
    content => template('profile/fail2ban_jail.local.erb'),
    require => Package['fail2ban'],
    notify  => Service['fail2ban'],
  }

  service { 'fail2ban':
    ensure  => running,
    enable  => true,
    require => Package['fail2ban'],
  }
}
