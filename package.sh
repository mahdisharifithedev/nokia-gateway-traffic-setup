#!/bin/bash

PORT=8000

rm -f sysupgrade_backup.tgz
cd staging
tar -czvf ../sysupgrade_backup.tgz .
cd ..
npx http-server -p $PORT