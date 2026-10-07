#!/bin/sh
set -eu
export PATH=/var/jb/usr/bin:/var/jb/bin:/var/jb/usr/sbin:/var/jb/sbin:/sbin:/usr/sbin:/bin:/usr/bin
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
PYTHON=/var/jb/usr/bin/python3
if test ! -x "$PYTHON"; then
    PYTHON=/usr/bin/python3
fi
exec "$PYTHON" "$SCRIPT_DIR/bootpd-hotspot-merge.py"
