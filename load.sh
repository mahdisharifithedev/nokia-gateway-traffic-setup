#!/bin/bash

PORT=8000
IP_INDICE=22

cd /data ; \
    rm -f /data/sysupgrade_backup.tgz /data/sysupgrade.tgz ; \
    wget "http://192.168.1.$IP_INDICE:$PORT/sysupgrade_backup.tgz" ; \
    cp /data/sysupgrade_backup.tgz /data/sysupgrade.tgz ; \
    ls