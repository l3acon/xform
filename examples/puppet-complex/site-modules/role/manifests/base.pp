# role::base — minimal baseline for all nodes
class role::base {
  include profile::base
  include profile::security
  include profile::monitoring
}
