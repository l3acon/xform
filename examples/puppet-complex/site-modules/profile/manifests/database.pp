# profile::database — PostgreSQL server
class profile::database (
  String           $postgresql_version = lookup('profile::database::postgresql_version'),
  String           $listen_addresses   = lookup('profile::database::listen_addresses'),
  Integer          $max_connections     = lookup('profile::database::max_connections'),
  String           $shared_buffers      = lookup('profile::database::shared_buffers'),
  Hash             $databases           = lookup('profile::database::databases'),
  String           $package_name        = lookup('profile::database::package_name'),
  String           $service_name        = lookup('profile::database::service_name'),
  String           $data_dir            = lookup('profile::database::data_dir'),
  String           $config_file         = lookup('profile::database::config_file'),
  String           $hba_file            = lookup('profile::database::hba_file'),
) {

  package { $package_name:
    ensure => installed,
  }

  package { 'postgresql-contrib':
    ensure  => installed,
    require => Package[$package_name],
  }

  exec { 'postgresql-initdb':
    command => "/usr/bin/postgresql-setup --initdb",
    creates => "${data_dir}/PG_VERSION",
    require => Package[$package_name],
  }

  file { $config_file:
    ensure  => file,
    content => template('profile/postgresql.conf.erb'),
    require => Exec['postgresql-initdb'],
    notify  => Service[$service_name],
  }

  file { $hba_file:
    ensure  => file,
    content => template('profile/pg_hba.conf.erb'),
    require => Exec['postgresql-initdb'],
    notify  => Service[$service_name],
  }

  service { $service_name:
    ensure  => running,
    enable  => true,
    require => Exec['postgresql-initdb'],
  }

  # Firewall for PostgreSQL
  exec { 'db-firewall-port':
    command => '/usr/bin/firewall-cmd --permanent --add-service=postgresql',
    unless  => '/usr/bin/firewall-cmd --query-service=postgresql',
    notify  => Exec['db-firewall-reload'],
  }

  exec { 'db-firewall-reload':
    command     => '/usr/bin/firewall-cmd --reload',
    refreshonly => true,
  }

  # Create databases from Hiera
  $databases.each |String $dbname, Hash $opts| {
    exec { "create-db-${dbname}":
      command => "/usr/bin/createdb -O ${opts['owner']} -E ${opts['encoding']} ${dbname}",
      unless  => "/usr/bin/psql -lqt | grep -qw ${dbname}",
      user    => 'postgres',
      require => Service[$service_name],
    }
  }
}
