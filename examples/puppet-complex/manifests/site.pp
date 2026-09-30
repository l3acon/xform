# site.pp — top-level node classification using roles
#
# Uses Hiera-driven classification: each node's $role fact determines
# which role class is applied. Roles compose profiles.

node default {
  $role = lookup('role', String, 'first', 'base')
  notify { "Node ${facts['networking']['fqdn']} classified as role: ${role}": }

  case $role {
    'webserver': { include role::webserver }
    'dbserver':  { include role::dbserver }
    default:     { include role::base }
  }
}
