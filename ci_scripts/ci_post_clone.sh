#!/bin/sh
set -e

xcrun agvtool new-version -all $CI_BUILD_NUMBER
