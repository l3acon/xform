package { 'httpd':
  ensure => installed,
}

package { 'firewalld':
  ensure => installed,
}

file { '/var/www/html/index.html':
  ensure  => file,
  content => template('webserver/index.html.erb'),
  owner   => 'apache',
  group   => 'apache',
  mode    => '0644',
  require => Package['httpd'],
}

service { 'httpd':
  ensure    => running,
  enable    => true,
  subscribe => File['/var/www/html/index.html'],
  require   => Package['httpd'],
}

service { 'firewalld':
  ensure  => running,
  enable  => true,
  require => Package['firewalld'],
}

exec { 'firewall-allow-http':
  command => '/usr/bin/firewall-cmd --permanent --add-service=http',
  unless  => '/usr/bin/firewall-cmd --query-service=http',
  require => Service['firewalld'],
  notify  => Exec['firewall-reload'],
}

exec { 'firewall-allow-https':
  command => '/usr/bin/firewall-cmd --permanent --add-service=https',
  unless  => '/usr/bin/firewall-cmd --query-service=https',
  require => Service['firewalld'],
  notify  => Exec['firewall-reload'],
}

exec { 'firewall-reload':
  command     => '/usr/bin/firewall-cmd --reload',
  refreshonly => true,
}
