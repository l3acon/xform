#!/bin/bash
# Translated from Puppet custom fact: lib/facter/webapp_status.rb
# Outputs JSON for ansible_local.webapp_status

DEPLOY_DIR="/opt/apps"
echo "{"

first=true
if [ -d "$DEPLOY_DIR" ]; then
    for app in "$DEPLOY_DIR"/*/; do
        [ -d "$app" ] || continue
        app_name=$(basename "$app")
        jar=$(find "$app/bin" -name '*.jar' -print -quit 2>/dev/null)

        if [ -n "$jar" ]; then
            jar_name=$(basename "$jar")
            if pgrep -f "$jar_name" > /dev/null 2>&1; then
                running="true"
            else
                running="false"
            fi

            if [ "$first" = true ]; then
                first=false
            else
                echo ","
            fi

            cat <<ENTRY
  "$app_name": {
    "installed": true,
    "running": $running,
    "jar": "$jar_name"
  }
ENTRY
        fi
    done
fi

echo "}"
