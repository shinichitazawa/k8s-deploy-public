#!/bin/sh
# initContainer: 依存を emptyDir に入れる(wrenai と同じ作り)。
set -eu
# pip は wheel を TMPDIR に展開する。/tmp(256Mi)では足りないので 2Gi の emptyDir 側を使う。
export TMPDIR=/opt/app/.piptmp
mkdir -p "$TMPDIR"
pip install --no-cache-dir --disable-pip-version-check \
  --require-hashes --only-binary :all: \
  --target /opt/app -r /config/requirements.lock
rm -rf "$TMPDIR"
