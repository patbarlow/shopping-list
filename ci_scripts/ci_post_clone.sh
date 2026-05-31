#!/bin/sh
set -e

cd "$CI_PRIMARY_REPOSITORY_PATH"
xcrun agvtool new-version -all $((CI_BUILD_NUMBER + 100))
