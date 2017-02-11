#!/bin/bash

# Update the container version tag in scripts and documentation 

: ${1?Must supply a version number (e.g. $0 1.2.3)}

exp='s/\(whereisaaron\/kube-backup:\)[0-9][0-9.]\+/\1'"$1"'/g'

sed -i -e "$exp" README.md doc/*.sh doc/*.ps1

sed -i -e 's/\(VERSION=\)[0-9][0-9.]\+/\1'"$1"'/' bin/kube-backup.sh
