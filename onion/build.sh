#!/bin/sh
# Cross-compiles guidewatch for the Miyoo Mini Plus using the same Docker
# toolchain image OnionOS itself builds with (aemiii91/miyoomini-toolchain).
# Output: sd-package/App/GuideWatch/guidewatch (static ARM binary).
# Also runs the host-side self-test of the parsing logic first.
set -e
cd "$(dirname "$0")"

echo "== self-test (host) =="
cc -DSELFTEST -Wall -o /tmp/guidewatch-selftest src/guidewatch.c
/tmp/guidewatch-selftest

echo "== cross-compile (docker) =="
docker run --rm --platform linux/amd64 -v "$PWD":/root/workspace aemiii91/miyoomini-toolchain:latest \
  /bin/bash -c 'source /root/.bashrc; cd /root/workspace && \
    ${CROSS_COMPILE:-arm-linux-gnueabihf-}gcc -Os -static -s -Wall \
      -o sd-package/App/GuideWatch/guidewatch src/guidewatch.c'

file sd-package/App/GuideWatch/guidewatch 2>/dev/null || true
echo "OK: sd-package/ is ready to copy onto the SD card"
