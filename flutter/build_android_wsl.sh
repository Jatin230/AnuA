#!/bin/bash
source /home/jatin/.cargo/env
export ANDROID_NDK_HOME=/home/jatin/android-ndk-r26d
export VCPKG_ROOT=/home/jatin/vcpkg
export CARGO_TARGET_DIR=/home/jatin/anuvadini_target_r26
cd /mnt/c/Users/jatin/Downloads/anuvadini
export RUSTFLAGS="-L /home/jatin/vcpkg/installed/arm64-android/lib"
/home/jatin/.cargo/bin/cargo ndk -t arm64-v8a -P 21 build --features flutter --release > /mnt/c/Users/jatin/Downloads/anuvadini/build_log_wsl.txt 2>&1
