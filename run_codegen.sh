export VCPKG_ROOT=/root/vcpkg
export PKG_CONFIG_PATH=/root/vcpkg/installed/x64-linux/lib/pkgconfig
export PATH=$PATH:/root/flutter_sdk/flutter/bin
export BOT=true
export FLUTTER_ALLOW_ROOT=true
git config --global --add safe.directory /root/flutter_sdk/flutter
git config --global --add safe.directory /home/jatin/anuvadini
. /root/.cargo/env
cd /home/jatin/anuvadini/flutter
flutter pub get
cd /home/jatin/anuvadini
/root/.cargo/bin/flutter_rust_bridge_codegen --rust-input ./src/flutter_ffi.rs --dart-output ./flutter/lib/generated_bridge.dart --rust-output ./src/bridge_generated.rs --c-output ./src/bridge_generated.h
