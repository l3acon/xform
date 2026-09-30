# role::webserver — web + app + monitoring + security
class role::webserver {
  include profile::base
  include profile::security
  include profile::web
  include profile::app
  include profile::monitoring

  Class['profile::base']
  -> Class['profile::security']
  -> Class['profile::web']
  -> Class['profile::app']
  -> Class['profile::monitoring']
}
