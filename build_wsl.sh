#!/bin/bash
export PATH=$PATH:/root/flutter_sdk/flutter/bin
source /root/.cargo/env
export VCPKG_ROOT=/root/vcpkg
cd /root/anuvadini
python3 build.py --flutter
