#!/bin/sh
set -e

if [ "${MULTI_USER}" = "true" ]; then
  exec node dist/index.js --multi-user "$@"
fi

exec node dist/index.js "$@"
