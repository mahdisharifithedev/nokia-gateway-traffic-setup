#!/usr/bin/expect -f

set timeout 30
set ip "192.168.1.1"
set port "HTTP_PORT"
set localip "LOCAL_IP"
set user "SSH_USER_NAME"
set password "SSH_USER_PASSWORD"
set rootpass "SSH_ROOT_PASSWORD"

spawn ssh $user@$ip
# It checks for "assword:" in case of capital P or lowercase p
expect "*assword:*"
send "$password\r"
# Wait for standard user prompt (usually ends in $ or >)
expect -re {[$>]}

send "su -\r"
expect "*assword:*"
send "$rootpass\r"
# Wait for root prompt (usually ends in #)
expect "*#*"

send "rm -f /data/sysupgrade_backup.tgz /data/sysupgrade.tgz\r"
expect "*#*"
send "wget -O /data/sysupgrade_backup.tgz http://$localip:$port/sysupgrade_backup.tgz\r"
expect "*#*"
send "cp /data/sysupgrade_backup.tgz /data/sysupgrade.tgz\r"
expect "*#*"
send "chown root:root /data/sysupgrade_backup.tgz /data/sysupgrade.tgz\r"
expect "*#*"
send "ls -lh /data\r"
expect "*#*"

send "reboot\r"
expect "*#*"
# Exit su
send "exit\r"
expect -re {[$>]}
# Exit ssh
send "exit\r"
expect eof