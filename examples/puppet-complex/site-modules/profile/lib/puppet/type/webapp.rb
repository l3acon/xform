require 'puppet/type'

Puppet::Type.newtype(:webapp) do
  @doc = "Manages a Java web application deployment"

  ensurable

  newparam(:name, :namevar => true) do
    desc "The application name"
  end

  newparam(:deploy_dir) do
    desc "Base deployment directory"
    defaultto '/opt/apps'
  end

  newparam(:user) do
    desc "Application user"
    defaultto 'appuser'
  end

  newparam(:group) do
    desc "Application group"
    defaultto 'appgroup'
  end

  newproperty(:version) do
    desc "Application version (from jar manifest)"
  end

  newproperty(:running) do
    desc "Whether the application should be running"
    newvalues(:true, :false)
    defaultto :true
  end
end
