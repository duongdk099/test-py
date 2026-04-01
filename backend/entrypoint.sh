#!/bin/sh
set -eu

echo "Applying database migrations..."
python manage.py migrate --noinput

exec "$@"
