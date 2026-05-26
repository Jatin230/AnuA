# 🖥️ Anuvadini — Wireless Remote Desktop & Mobile Control

**Anuvadini** is a free, self-hosted remote desktop app that lets you **control your Windows laptop from your Android phone** (and vice versa) — **completely offline, no internet required, no account needed**.

It works over your local Wi-Fi or mobile hotspot. No cloud servers, no subscriptions. Everything runs directly between your devices.

---

## 📱 What Can You Do With Anuvadini?

| Feature | Description |
|---|---|
| 📱 → 💻 **Phone controls Laptop** | Use your Android phone as a remote control for your Windows laptop |
| 💻 → 📱 **Laptop controls Phone** | View and control your Android phone's screen from your laptop |
| 🔒 **100% Private** | All traffic stays on your local network — nothing goes to the internet |
| ⚡ **No login required** | No accounts, no servers, no subscriptions |
| 📡 **Works offline** | Use over Wi-Fi or even a Mobile Hotspot |

---

## 🚀 Quick Start — Just Want to Run It? (Non-Technical)

If someone has already given you the built files (`.exe` for laptop, `.apk` for phone), follow these steps:

### Step 1: Install the Android App (APK)
1. Copy the `app-release.apk` file to your Android phone (via USB, WhatsApp, Google Drive, etc.)
2. On your phone, go to **Settings → Security → Install Unknown Apps** and allow your file manager.
3. Tap the APK file and tap **Install**.

### Step 2: Install the Windows App (EXE)
1. Copy the `Anuvadini.exe` file to your laptop.
2. Double-click it. Windows may show a "Windows protected your PC" warning — click **"More info"** and then **"Run anyway"**.
3. If Windows Firewall asks for permission, click **Allow Access** (this is required for the connection to work).

### Step 3: Connect Phone and Laptop
1. Make sure **both devices are on the same Wi-Fi network** (or use your phone's Mobile Hotspot and connect the laptop to it).
2. Open the **Anuvadini** app on your **laptop**.
3. Click **"Mobile Command Center"** from the menu.
4. A **QR Code** will appear on the laptop screen.
5. Open the **Anuvadini** app on your **phone**.
6. Tap the **Scan QR** button and scan the QR code on your laptop.
7. Your phone will appear in the "Active Mobile Devices" list on the laptop.
8. Click **"Control Phone"** to view your phone screen on the laptop, or click **"Let Phone Control Me"** to control the laptop from the phone.

> **That's it!** No configuration, no servers, no login.

---

## 🛠️ For Developers — Building From Source

This section is for developers who want to build the app themselves from the source code.

### Prerequisites — What You Need to Install

> ⚠️ This is a complex project with both Rust (backend) and Flutter (UI) components. Set aside 1-2 hours for initial environment setup.

#### On Windows (for the Laptop app):

| Tool | Download Link | Notes |
|---|---|---|
| **Git** | https://git-scm.com/download/win | For cloning the repo |
| **Rust** | https://rustup.rs/ | The programming language for the backend |
| **Flutter SDK** | https://docs.flutter.dev/get-started/install/windows | UI framework |
| **Visual Studio 2022 Build Tools** | https://visualstudio.microsoft.com/downloads/#build-tools-for-visual-studio-2022 | Select "Desktop development with C++" workload |
| **WSL2 with Ubuntu** | Run `wsl --install` in PowerShell | Required only for building the Android app |

#### On Ubuntu/WSL (for the Android app):

```bash
# Install Rust in WSL
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
source ~/.cargo/env

# Add Android target
rustup target add aarch64-linux-android

# Install cargo-ndk
cargo install cargo-ndk

# Install Android NDK r26d via Android Studio (on Windows side), 
# or set NDK path manually in WSL:
export ANDROID_NDK_HOME=/path/to/your/ndk/r26d
```

---

### 📥 Clone the Repository

```powershell
git clone https://github.com/Jatin230/AnuC.git
cd AnuC
```

---

### 🖥️ Building the Windows App (Laptop)

Open **PowerShell** (not Ubuntu/WSL) inside the project folder:

**Step 1: Compile the Rust backend DLL**
```powershell
cargo build --release --features flutter
```
*(This takes 5-15 minutes the first time. Subsequent builds are much faster.)*

**Step 2: Copy the DLL for Flutter**
```powershell
Copy-Item -Force "target\release\anuvadini.dll" -Destination "target\release\libanuvadini.dll"
```

**Step 3: Build the Flutter Windows app**
```powershell
cd flutter
flutter build windows --release
```

**Step 4: Run the app**
```powershell
.\build\windows\x64\runner\Release\Anuvadini.exe
```

The final `.exe` and all required files are inside:
```
flutter\build\windows\x64\runner\Release\
```
You can copy this entire folder to any Windows PC and run `Anuvadini.exe`.

---

### 📱 Building the Android App (Phone)

**Step 1: In WSL/Ubuntu — compile the native Rust library**
```bash
cd /mnt/c/Users/<your-username>/Downloads/AnuC

cargo ndk -t arm64-v8a -o ./flutter/android/app/src/main/jniLibs build --release --lib --features flutter
```
*(This cross-compiles the Rust backend into a `.so` library for Android.)*

**Step 2: In Windows PowerShell — build the APK**
```powershell
cd flutter
flutter build apk --release
```

The APK will be at:
```
flutter\build\app\outputs\flutter-apk\app-release.apk
```

Send this file to your Android phone and install it (see Quick Start above for how to install an APK).

---

## 🔧 How It Works (Technical Overview)

```
┌─────────────────────────────────────────────────────┐
│                  YOUR LOCAL NETWORK                  │
│                                                      │
│  ┌──────────────────┐         ┌──────────────────┐  │
│  │   Android Phone  │ ◄─────► │  Windows Laptop  │  │
│  │                  │  Wi-Fi  │                  │  │
│  │  Flutter UI      │  TCP    │  Flutter UI      │  │
│  │  + Rust .so lib  │ :21118  │  + Rust .dll lib │  │
│  └──────────────────┘         └──────────────────┘  │
│                                                      │
│         No internet. No cloud. 100% local.           │
└─────────────────────────────────────────────────────┘
```

### Custom Protocol — How Pairing Works

1. The laptop generates a **QR code** containing its local IP address (e.g., `anuvadini://direct-tcp:192.168.68.125_port_21118`).
2. The phone scans the QR and opens a raw TCP socket to `192.168.68.125:21118`.
3. The phone sends a handshake: `ANUVADINI_HELLO:<device-name>:<device-id>`.
4. The laptop recognizes the custom handshake, registers the phone, and replies: `ANUVADINI_ACK`.
5. The phone appears in the "Active Mobile Devices" list. The devices can now establish a remote session.

### Key Technical Modifications from Anuvadini Upstream

| Area | Change |
|---|---|
| `src/rendezvous_mediator.rs` | Added `handle_mobile_registration()` — custom TCP handshake handler |
| `src/rendezvous_mediator.rs` | Added packet peeking to detect `ANUVADINI_HELLO` vs normal Anuvadini traffic |
| `src/client.rs` | Added `direct-tcp:` URI scheme support — bypasses rendezvous server lookup |
| `src/server/connection.rs` | Patched auth to allow `direct-tcp:` prefixed usernames (offline override) |
| `flutter/lib/desktop/pages/mobile_control_page.dart` | New "Mobile Command Center" UI — QR generation, device list, control buttons |
| `flutter/lib/mobile/pages/scan_page.dart` | Updated QR scanner to handle `anuvadini://direct-tcp:` URIs |
| `Cargo.toml` | Rebranded from `anuvadini` → `anuvadini` |

---

## 🐛 Troubleshooting

### ❌ "Failed to connect" error
- Make sure both devices are on **the same Wi-Fi network** or connected to the same **Mobile Hotspot**.
- On Windows, check that Windows Firewall allows `Anuvadini.exe` on port **21118** (TCP, inbound).
- Some routers have **"AP Isolation"** enabled which blocks devices from talking to each other. Switch to a Mobile Hotspot to test.

### ❌ "Windows protected your PC" warning
- Click **"More info"** → **"Run anyway"**. This appears because the app is unsigned.

### ❌ Phone doesn't appear after scanning QR
- Make sure you tapped "Start Service" on the Anuvadini Android app first.
- Make sure the QR code is fresh — click "Refresh IP" on the laptop if the IP may have changed.

### ❌ Cargo build fails with "could not find flutter"
- On Windows, always build with `--features flutter`:
  ```powershell
  cargo build --release --features flutter
  ```

### ❌ Flutter build fails with "permission denied" on DLL
- The app is still running. Close it first:
  ```powershell
  Stop-Process -Name "anuvadini" -Force -ErrorAction SilentlyContinue
  ```
  Then retry the build.

### ❌ Android app crashes on launch
- Make sure `libanuvadini.so` is inside `flutter/android/app/src/main/jniLibs/arm64-v8a/` before building the APK. Run the `cargo ndk` step in WSL first.

---

## 🏗️ Project Structure

```
AnuC/
├── src/                          # Rust backend source code
│   ├── rendezvous_mediator.rs    # ⭐ Custom mobile registration protocol
│   ├── client.rs                 # ⭐ direct-tcp:// URI connection handler
│   └── server/connection.rs     # ⭐ Auth override for direct connections
├── flutter/
│   ├── lib/
│   │   ├── desktop/pages/
│   │   │   └── mobile_control_page.dart  # ⭐ Mobile Command Center UI
│   │   └── mobile/pages/
│   │       └── scan_page.dart            # ⭐ QR scanner with registration
│   ├── android/                  # Android build config
│   └── windows/                  # Windows CMake build config
├── Cargo.toml                    # Rust package config (rebranded to anuvadini)
└── build.py                      # Build helper script
```

---

## 📄 License

This project is based on [Anuvadini](https://github.com/anuvadini/anuvadini) which is licensed under [AGPL-3.0](https://www.gnu.org/licenses/agpl-3.0.html). All modifications and additions in this repository are also subject to the same AGPL-3.0 license.

---

## 👤 Author

**Jatin** — [github.com/Jatin230](https://github.com/Jatin230)

*Built with ❤️ using Rust + Flutter*
