# Anuvadini Remote Control

Anuvadini is a highly customized, self-hosted remote desktop application derived from the RustDesk codebase. It features a completely rebuilt local networking protocol that bypasses the need for internet-based Rendezvous servers and public relays, allowing for direct P2P connections on local networks (via the custom `direct-tcp:` protocol) without being subject to public server login requirements.

## Key Features & Customizations
- **Direct TCP Protocol (`direct-tcp:`)**: Custom handshake logic allows the Android client to bypass ID-sanitization and connect directly to the Windows host's local IP address and port (21118).
- **Forced Local Server Bind**: The Windows backend (`anuvadini.exe`) is forced to listen on port 21118 (`0.0.0.0:21118`) regardless of standard configuration defaults.
- **Offline Authentication Override**: The Rust backend handshake validation was patched to explicitly allow `direct-tcp:` prefixes, preventing the server from returning "Offline" errors when receiving custom connection strings.
- **Rebranding**: Package names, UI text, and binary targets have been rebranded from `rustdesk` to `anuvadini` across `Cargo.toml`, Android manifests, and Flutter FFI bindings (`VER_TYPE_ANUVADINI_CLIENT`).

---

## Technical Stack & Versions

- **Rust**: Version `1.75` (Required for backend compilation)
- **Flutter SDK**: `^3.1.0` (Verified on Flutter 3.19.x / 3.22.x)
- **Android NDK**: `r26d` (Required for building the Android native `libanuvadini.so`)
- **C++ Build Tools**: Visual Studio 2022 C++ Build Tools (Required for Windows backend)
- **VCPKG**: Used for managing C++ dependencies (e.g., FFmpeg) during cross-compilation.

---

## Environment Setup & Installation

### 1. Prerequisites
- Install **Git**.
- Install **Rust** via [rustup.rs](https://rustup.rs/).
- Install **Flutter** and run `flutter doctor` to ensure Android Studio and Windows Desktop toolchains are installed.
- Install **Visual Studio 2022** with "Desktop development with C++" workload (for Windows).
- (For Android build) Set up **WSL (Windows Subsystem for Linux)** with Ubuntu, and install `cargo-ndk`.

### 2. Install Rust Tools
```bash
cargo install flutter_rust_bridge_codegen@1.80.1
cargo install cargo-ndk
```

---

## Building and Running the Application

### Windows (Host Server & UI)

The Windows application consists of two parts: the background service (Rust) and the UI frontend (Flutter).

**Step 1: Run the Backend Service**
Open PowerShell as Administrator in the project root and run the backend server. It must be built *without* the Flutter feature flag to run as a standalone server:
```powershell
cargo run --release -- --server
```
*(Leave this terminal window open. It will listen on port 21118 for incoming connections).*

**Step 2: Build and Run the UI**
Open a new PowerShell window and build/run the Flutter UI:
```powershell
cd flutter
flutter build windows
flutter run -d windows
```
*Note: Ensure the Windows Firewall allows `target\release\anuvadini.exe` through on port 21118.*

### Android (Client App)

Building for Android requires cross-compiling the Rust backend into a `.so` library, and then packaging it with the Flutter app.

**Step 1: Compile Native Library (in WSL/Linux)**
```bash
# Add the target architecture
rustup target add aarch64-linux-android

# Build the native library
cargo ndk -t arm64-v8a -o ./flutter/android/app/src/main/jniLibs build --release --lib --features flutter
```
*(This produces `libanuvadini.so` inside the `jniLibs/arm64-v8a` directory).*

**Step 2: Build the APK (in Windows)**
Return to your Windows PowerShell and run:
```powershell
cd flutter
flutter build apk --release
```
The resulting APK will be located at `flutter/build/app/outputs/flutter-apk/app-release.apk`.

---

## Usage Guide (Bypassing AP Isolation)

1. Connect your Windows PC to a network that allows Peer-to-Peer communication (e.g., a Mobile Hotspot).
2. Start the Windows backend service (`cargo run --release -- --server`).
3. Open the Windows Anuvadini UI and navigate to the "Mobile Control" page.
4. Open the Anuvadini app on your Android device (connected to the same Hotspot).
5. Scan the QR code. The app will connect directly to `192.168.x.x:21118` via the custom `direct-tcp:` tunnel.

---

## Troubleshooting

- **"Failed to connect to 192.168.x.x:21118"**: 
  1. Ensure Windows Firewall is allowing inbound TCP connections on port 21118 for `target\release\anuvadini.exe`.
  2. Verify you are not on a network with "AP Isolation" (Client Isolation) enabled, which physically blocks P2P traffic. Use a Mobile Hotspot to test.
- **"Login error offline"**: 
  Ensure you are running the newly compiled server. This error occurred historically when the Rust server rejected the `direct-tcp:` handshake format.
- **LNK1104 / Permission Denied during build**: 
  Ensure the Anuvadini application and background services are completely closed before running `flutter build` or `cargo build`. Use `Stop-Process -Name anuvadini` if necessary.
