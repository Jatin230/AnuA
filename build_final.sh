export VCPKG_ROOT=/root/vcpkg
export PKG_CONFIG_PATH=/root/vcpkg/installed/x64-linux/lib/pkgconfig
export PATH=$PATH:/root/flutter_sdk/flutter/bin
export BOT=true
export FLUTTER_ALLOW_ROOT=true
git config --global --add safe.directory /root/flutter_sdk/flutter
git config --global --add safe.directory /home/jatin/rustdesk
. /root/.cargo/env
cd /home/jatin/rustdesk
python3 build.py --flutter
