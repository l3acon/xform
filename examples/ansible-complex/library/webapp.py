#!/usr/bin/python
# -*- coding: utf-8 -*-

# Translated from Puppet custom type/provider:
#   lib/puppet/type/webapp.rb + lib/puppet/provider/webapp/systemd.rb

DOCUMENTATION = r'''
---
module: webapp
short_description: Manage Java web application deployments via systemd
description:
  - Deploy, manage, and remove Java web applications as systemd services.
  - Translated from Puppet webapp type with systemd provider.
options:
  name:
    description: Application name
    required: true
    type: str
  state:
    description: Desired state (present/absent/started/stopped)
    default: present
    choices: [present, absent, started, stopped]
    type: str
  deploy_dir:
    description: Base deployment directory
    default: /opt/apps
    type: str
  user:
    description: Application user
    default: appuser
    type: str
  group:
    description: Application group
    default: appgroup
    type: str
'''

import os
import subprocess
from ansible.module_utils.basic import AnsibleModule


def get_app_dir(params):
    return os.path.join(params['deploy_dir'], params['name'])


def get_service_unit_path(params):
    return '/etc/systemd/system/{}.service'.format(params['name'])


def app_exists(params):
    return (os.path.exists(get_service_unit_path(params)) and
            os.path.isdir(get_app_dir(params)))


def is_running(module, params):
    rc = module.run_command(['systemctl', 'is-active', params['name']])[0]
    return rc == 0


def get_version(params):
    app_dir = get_app_dir(params)
    jars = [f for f in os.listdir(os.path.join(app_dir, 'bin'))
            if f.endswith('.jar')] if os.path.isdir(os.path.join(app_dir, 'bin')) else []
    if not jars:
        return 'unknown'
    jar_path = os.path.join(app_dir, 'bin', jars[0])
    rc, stdout, _ = subprocess.Popen(
        ['unzip', '-p', jar_path, 'META-INF/MANIFEST.MF'],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE
    ).communicate()
    for line in (stdout or b'').decode().splitlines():
        if line.startswith('Implementation-Version:'):
            return line.split(':', 1)[1].strip()
    return 'unknown'


def setup_directories(module, params):
    app_dir = get_app_dir(params)
    for sub in ['', '/bin', '/config', '/logs']:
        path = app_dir + sub
        if not os.path.isdir(path):
            os.makedirs(path)
        os.chown(path,
                 module.run_command(['id', '-u', params['user']])[1].strip(),
                 module.run_command(['id', '-g', params['group']])[1].strip())


def generate_service_unit(params):
    app_dir = get_app_dir(params)
    return """[Unit]
Description={name} Application
After=network.target

[Service]
Type=simple
User={user}
Group={group}
WorkingDirectory={app_dir}
ExecStart=/usr/bin/java -jar {app_dir}/bin/{name}.jar
Restart=always

[Install]
WantedBy=multi-user.target
""".format(name=params['name'], user=params['user'],
           group=params['group'], app_dir=app_dir)


def create_app(module, params):
    setup_directories(module, params)
    unit_path = get_service_unit_path(params)
    with open(unit_path, 'w') as f:
        f.write(generate_service_unit(params))
    module.run_command(['systemctl', 'daemon-reload'], check_rc=True)
    module.run_command(['systemctl', 'enable', '--now', params['name']], check_rc=True)


def destroy_app(module, params):
    if is_running(module, params):
        module.run_command(['systemctl', 'disable', '--now', params['name']])
    unit_path = get_service_unit_path(params)
    if os.path.exists(unit_path):
        os.remove(unit_path)
    module.run_command(['systemctl', 'daemon-reload'])


def main():
    module = AnsibleModule(
        argument_spec=dict(
            name=dict(type='str', required=True),
            state=dict(type='str', default='present',
                       choices=['present', 'absent', 'started', 'stopped']),
            deploy_dir=dict(type='str', default='/opt/apps'),
            user=dict(type='str', default='appuser'),
            group=dict(type='str', default='appgroup'),
        ),
        supports_check_mode=True,
    )

    params = module.params
    changed = False
    exists = app_exists(params)
    running = is_running(module, params) if exists else False

    if params['state'] == 'absent':
        if exists:
            if not module.check_mode:
                destroy_app(module, params)
            changed = True
    elif params['state'] in ('present', 'started'):
        if not exists:
            if not module.check_mode:
                create_app(module, params)
            changed = True
        if params['state'] == 'started' and not running and not module.check_mode:
            module.run_command(['systemctl', 'start', params['name']], check_rc=True)
            changed = True
    elif params['state'] == 'stopped':
        if not exists:
            if not module.check_mode:
                create_app(module, params)
            changed = True
        if running and not module.check_mode:
            module.run_command(['systemctl', 'stop', params['name']], check_rc=True)
            changed = True

    result = dict(
        changed=changed,
        name=params['name'],
        state=params['state'],
        app_dir=get_app_dir(params),
        version=get_version(params) if app_exists(params) else None,
        running=is_running(module, params) if app_exists(params) else False,
    )
    module.exit_json(**result)


if __name__ == '__main__':
    main()
