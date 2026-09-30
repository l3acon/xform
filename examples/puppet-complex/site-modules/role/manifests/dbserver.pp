# role::dbserver — database + monitoring + security
class role::dbserver {
  include profile::base
  include profile::security
  include profile::database
  include profile::monitoring

  Class['profile::base']
  -> Class['profile::security']
  -> Class['profile::database']
  -> Class['profile::monitoring']
}
