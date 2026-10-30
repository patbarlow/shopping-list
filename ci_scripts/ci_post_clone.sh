#!/bin/sh
set -e

cd "$CI_PRIMARY_REPOSITORY_PATH"
# Keep cloud uploads above the existing locally uploaded 200-series builds.
# CI_BUILD_NUMBER increases across this product, including verification runs.
xcrun agvtool new-version -all $((CI_BUILD_NUMBER + 1000))
