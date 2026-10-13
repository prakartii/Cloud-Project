#!/bin/bash
# Packages the app for EC2: application code, frontend and an offline "wheelhouse" of Python
# dependencies, built in a python:3.12 container (Ubuntu 24.04 ships Python 3.12).
# Output: dist/library-release.tar.gz  -> upload to S3.
set -euo pipefail
cd "$(dirname "$0")/.."

rm -rf dist/stage && mkdir -p dist/stage
docker run --rm -v "$PWD":/work -w /work python:3.12-slim \
  pip wheel --quiet -r backend/requirements.txt -w dist/stage/wheelhouse

cp -r backend/app dist/stage/app
cp backend/requirements.txt dist/stage/requirements.txt
cp -r frontend dist/stage/frontend
find dist/stage -name __pycache__ -prune -exec rm -rf {} +
tar -czf dist/library-release.tar.gz -C dist/stage .
ls -lh dist/library-release.tar.gz
