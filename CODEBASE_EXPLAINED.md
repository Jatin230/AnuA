# 🦀 Anuvadini — Offline-Local & Nostr-WebRTC Internet Architecture

> **What is Anuvadini?**  
> Anuvadini is a remote desktop system built on top of the open-source RustDesk/Anuvadini codebase. It is designed to work in two modes:
> 1. **Offline-Local Mode**: Direct TCP sockets and peer discovery over local Wi-Fi or Hotspots (no internet, accounts, or cloud servers required).
> 2. **Decentralized Internet Mode (Nostr + WebRTC)**: Connects devices over the internet *without* a central rendezvous/signaling server, using **Nostr relays** for WebRTC signaling and coordinate handshake exchanges.
>
> This makes Anuvadini completely self-hosted, private, and serverless.

This document serves as a comprehensive developer guide written specifically for **Rust beginners** to understand each module, how the system communicates, and where the custom local-only and Nostr WebRTC overrides are located.

---

## 📖 Table of Contents

1. [Rust Concepts Refresher](#1-rust-concepts-refresher)
2. [Anuvadini Architecture Modes](#2-anuvadini-architecture-modes)
3. [Local Networking (Direct TCP & Handshake)](#3-local-networking-direct-tcp--handshake)
4. [Internet Networking (Nostr & WebRTC Signaling)](#4-internet-networking-nostr--webrtc-signaling)
5. [Startup Entry Points & CLI](#5-startup-entry-points--cli)
6. [The Direct TCP Server (`rendezvous_mediator.rs`)](#6-the-direct-tcp-server-rendezvous_mediators)
7. [The Client Connection Interceptor (`client.rs`)](#7-the-client-connection-interceptor-clients)
8. [Authentication & Overrides (`server/connection.rs`)](#8-authentication--overrides-serverconnections)
9. [LAN Discovery (`lan.rs`)](#9-lan-discovery-lans)
10. [IPC (Inter-Process Communication)](#10-ipc-inter-process-communication)
11. [Core Library (`libs/hbb_common`)](#11-core-library-libshbb_common)
12. [Module Directory & Function Guide](#12-module-directory--function-guide)

---

## 1. Rust Concepts Refresher

Before looking at the code, here are the key Rust syntax patterns used across this project:

### Conditional Compilation (`#[cfg(...)]`)
Anuvadini compiles on Windows, Linux, macOS, Android, and iOS. The compiler uses `#[cfg]` rules to determine which code runs on which OS:
```rust
#[cfg(target_os = "windows")]
fn windows_specific_api() { ... }

#[cfg(not(any(target_os = "android", target_os = "ios")))]
fn desktop_only_logic() { ... }
```

### Async/Await & Tokio Runtime
Asynchronous programming allows the CPU to handle multiple networking streams simultaneously without blocking threads:
```rust
async fn process_stream(mut stream: TcpStream) {
    // .await yields execution back to the executor while waiting for network packet I/O
    let n = stream.read(&mut buf).await.unwrap_or(0);
}
```

### Mutexes, RwLocks, and Arc
- **`Arc<T>`** (Atomic Reference Counted pointer): Allows sharing ownership of read-only variables between threads.
- **`RwLock<T>`** (Read-Write Lock): Allows multiple threads to read data, or a single thread to write to it.
- **`Mutex<T>`** (Mutual Exclusion): Guarantees that only one thread can access data at any time.

Combined as `Arc<RwLock<T>>` or `Arc<Mutex<T>>`, these enable thread-safe shared states, such as managing active remote connections or global system configurations.

---

## 2. Anuvadini Architecture Modes

Anuvadini operates in two distinct connection modes:

### Mode A: Offline-Local Mode
```
 ┌───────────────────────────────────────────────────────────┐
 │                     LOCAL WI-FI NETWORK                   │
 │                                                           │
 │  ┌───────────────────┐             ┌───────────────────┐  │
 │  │   Android Client  │             │   Windows Host    │  │
 │  │   (Phone App)     │   Direct    │   (Laptop App)    │  │
 │  │                   │ ──────────→ │                   │  │
 │  │  Scans QR Code to │  TCP Port   │  Runs background  │  │
 │  │  get Laptop's IP  │   21118     │  direct TCP server│  │
 │  └───────────────────┘             └───────────────────┘  │
 └───────────────────────────────────────────────────────────┘
```
- **Connection**: Direct socket connection on port `21118`.
- **Server Discovery**: Laptop local IP is encoded inside a QR code.
- **Dependency**: 100% offline, zero internet or external server dependency.

### Mode B: Internet Mode (Nostr + WebRTC)
```
 ┌───────────────────────────────────────────────────────────────────────────────┐
 │                                 THE INTERNET                                  │
 │                                                                               │
 │  ┌────────────────┐           ┌───────────────────┐           ┌────────────┐  │
 │  │ Android Client │           │    Nostr Relay    │           │Windows Host│  │
 │  │ (Remote Phone) │ ◄───────► │(wss://relay.damus)│ ◄───────► │(Home PC)   │  │
 │  └────────────────┘  Signaling│                   │ Signaling └────────────┘  │
 │          │                    └───────────────────┘                 │         │
 │          └──────────────────────── WebRTC Stream ───────────────────┘         │
 │                            (Direct encrypted connection)                      │
 └───────────────────────────────────────────────────────────────────────────────┘
```
- **Connection**: P2P WebRTC data channels for low-latency video, audio, and inputs.
- **Signaling**: Standard WebRTC requires a signaling server to exchange "offers" and "answers" (SDP exchange) between the client and host. In Anuvadini, **Nostr relays** (e.g., `wss://relay.damus.io`, `wss://relay.primal.net`) serve as the decentralized signaling channel.
- **Dependency**: Requires internet access but runs completely serverless (no specialized rendezvous server needed).

> [!NOTE]
> **Legacy Code Notice**: Because this project is built on top of the RustDesk codebase, you will still see legacy systems like `RendezvousMediator` loops querying central rendezvous/relay servers. In Anuvadini, these can be bypassed by utilizing the local Direct TCP mode or Nostr WebRTC.

---

## 3. Local Networking (Direct TCP & Handshake)

Anuvadini pairs two devices locally using a custom TCP handshake:

```
Android Client (Phone)                                      Windows Host (Laptop)
      │                                                               │
      │ ── Step 1: Scan Laptop QR (Contains IP & Port) ──────────────►│
      │                                                               │
      │ ── Step 2: Establish TCP Connection on Port 21118 ───────────►│ (Runs direct_server)
      │                                                               │
      │ ── Step 3: Send "ANUVADINI_HELLO:device_name:device_id" ─────►│ (Handshake checks bytes)
      │                                                               │
      │ ◄─ Step 4: Acknowledge with "ANUVADINI_ACK" ──────────────────│
      │                                                               │
      ▼                                                               ▼
Laptop GUI triggers "mobile_device_registered"             Phone registered locally
```

1. **Host Server**: The host runs `direct_server` in the background listening on TCP port `21118`.
2. **Scan**: The client app scans a QR code containing `anuvadini://direct-tcp:<ip>_port_21118` and opens a TCP stream to it.
3. **Hello**: The client sends a handshake payload: `ANUVADINI_HELLO:<device_name>:<device_id>[:<temp_password>]\n`.
4. **Ack**: The host parses the device info, pushes a `mobile_device_registered` event to the local GUI via FFI, and replies with `ANUVADINI_ACK\n` to complete the local pairing.

---

## 4. Internet Networking (Nostr & WebRTC Signaling)

To connect over the internet without a central controller, Anuvadini uses **Nostr** as a message signaling network:

1. **Offer Generation**: When the host generates its internet connection link, it starts the Nostr background thread:
   - It runs `generate_host_nostr_webrtc_uri()` to produce a `nostr-webrtc://<device_id>#<pubkey>` link.
   - It begins a loop `run_host_webrtc_background()`. This loop generates a WebRTC connection **Offer** and publishes it as a signed Nostr text event to a list of configured relays (`wss://relay.damus.io`, `wss://relay.primal.net`, etc.).
2. **Answer Exchange**: 
   - The client scans the `nostr-webrtc:` URI and connects to the same Nostr relays.
   - The client fetches the host's WebRTC Offer matching the pubkey.
   - The client constructs a WebRTC **Answer** and publishes it back to the Nostr relays.
3. **Connection**: The host retrieves the client's WebRTC Answer from the relays, and both endpoints establish an encrypted Peer-to-Peer **WebRTC Stream** (`hbb_common::webrtc::WebRTCStream`).

---

## 5. Startup Entry Points & CLI

### `src/main.rs`
The compilation entry point:
- **Flutter Build**: Initializes WebRTC signaling components and starts the main application FFI loops.
- **CLI Build**: Parses arguments via `clap::App` for port forwarding and starting servers.
- **Desktop GUI**: Launches the core initialization routines before starting the UI runner window.

### `src/core_main.rs`
Coordinates process arguments and permissions:
- `core_main()`: Handles Windows DPI scaling, autostart configurations, and coordinates update scripts.
- `is_root()`: Checks if running with root/administrator access.

---

## 6. The Direct TCP Server (`rendezvous_mediator.rs`)

`src/rendezvous_mediator.rs` contains the logic for direct TCP listeners and handshakes:

### `direct_server(server: ServerPtr)`
Spawns the local server thread on TCP port `21118`.
- Listens using `hbb_common::tcp::listen_any()`.
- On connection, it **peeks** at the first 32 bytes of the payload.
- If they match `ANUVADINI_HELLO`, it delegates to `handle_mobile_registration()`.
- If they do not match, it treats the connection as a remote control stream and invokes `crate::server::create_tcp_connection()`.

```rust
// Peeled from src/rendezvous_mediator.rs
if n >= 15 && &peek_buf[..15] == b"ANUVADINI_HELLO" {
    handle_mobile_registration(stream, addr).await;
} else {
    crate::server::create_tcp_connection(server, Stream::from(stream, local_addr), addr, false, None).await;
}
```

### `handle_mobile_registration(...)`
Processes a mobile client's pairing handshake:
- Parses the registration payload: `ANUVADINI_HELLO:<name>:<id>[:<temp_password>]`.
- Extracts device parameters (`name`, `id`, `ip`, `temp_password`).
- Generates JSON and triggers a global FFI event `mobile_device_registered` to update the GUI state.
- Transmits `ANUVADINI_ACK\n` to complete the transaction.

---

## 7. The Client Connection Interceptor (`client.rs`)

When establishing a connection, `src/client.rs` intercept the peer destination type inside `_start()`:

- **Direct TCP Interceptor**: If the target identifier starts with `"direct-tcp:"`, it extracts the destination, cleans the character formatting, resolves the port (defaulting to 21118), and connects directly via `connect_tcp_local()`.
- **Nostr WebRTC Interceptor**: If the target identifier starts with `"nostr-webrtc://"`, it skips socket connection attempts and invokes `hbb_common::webrtc::WebRTCStream::new(peer, ...)` to run the decentralized Nostr relay signaling process.

```rust
// Peeled from src/client.rs
if peer.starts_with("direct-tcp:") {
    let addr = peer[11..].trim().replace("_port_", ":");
    let final_addr = hbb_common::socket_client::check_port(addr, 21118);
    return Ok(((
        connect_tcp_local(final_addr, None, CONNECT_TIMEOUT).await?,
        true, None, None, "TCP"
    ), (0, "".to_owned()), false));
} else if hbb_common::nostr_signaling::is_nostr_webrtc_uri(peer) {
    let stream = hbb_common::webrtc::WebRTCStream::new(peer, false, CONNECT_TIMEOUT).await?;
    return Ok(((Stream::WebRTC(stream), true, None, None, "WebRTC"), (0, "".to_owned()), false));
}
```

---

## 8. Authentication & Overrides (`server/connection.rs`)

`src/server/connection.rs` manages connection authentication. Anuvadini modifies the username validation check to support direct local connections and Nostr WebRTC handshakes:

- **Normalized Username**: If the incoming connection username is a Nostr link, it strips `"nostr-webrtc://"` to extract the raw peer ID.
- **Validation Override**: Standard validation blocks any connection that does not match the host ID. Anuvadini adds exceptions for `"direct-tcp:"` and allows the login request to proceed.

```rust
// Peeled from src/server/connection.rs
let normalized_username = if lr.username.starts_with("nostr-webrtc://") {
    lr.username.trim_start_matches("nostr-webrtc://").split('?').next().unwrap_or(&lr.username).replace(' ', "")
} else {
    lr.username.replace(' ', "")
};

if !hbb_common::is_ip_str(&lr.username)
    && !hbb_common::is_domain_port_str(&lr.username)
    && !lr.username.starts_with("direct-tcp:") // Bypasses ID verification check
    && normalized_username != Config::get_id().replace(' ', "")
{
    self.send_login_error(crate::client::LOGIN_MSG_OFFLINE).await;
    return false;
}
```

---

## 9. LAN Discovery (`lan.rs`)

`src/lan.rs` scans the local network subnets to find other active Anuvadini instances.

- **`start_listening()`**: Binds a UDP socket to a local broadcast port. If LAN discovery is enabled, it responds to incoming broadcast "ping" packets with a "pong" containing the device's hostname, active OS user, platform type, and MAC address.
- **`discover()`**: Sends a UDP broadcast "ping" message across all available network interfaces. It starts a thread to wait for "pong" replies and saves online peers to the local cache.
- **`send_wol(id)`**: Extracts the peer's MAC address from the configuration cache and broadcasts a Wake-on-LAN magic packet.

---

## 10. IPC (Inter-Process Communication)

Anuvadini runs multiple background services (e.g., the system daemon service and the desktop user agent). The module `src/ipc.rs` handles data transfer between these local processes.

- **`start(postfix)`**: Creates a local Unix domain socket (or a Windows Named Pipe) matching the module identifier (e.g. `_service`) and listens for incoming connections.
- **`connect(ms_timeout, postfix)`**: Connects to the local process socket.
- **`ipc::Data` Enum**: Standardizes messages passed between processes:
  - `Data::FS(FS)`: File system commands (listing directory, removing/writing files).
  - `DataKeyboard` & `DataMouse`: Enigo-compatible OS input commands.
  - `Data::SyncConfig`: Synchronizes desktop-agent config updates with the system service config file.

---

## 11. Core Library (`libs/hbb_common`)

`libs/hbb_common` is the engine room of the application, managing codecs, configuration files, and network encoding:

- **`libs/hbb_common/src/config.rs`**: Handles local configuration files (ID, keys, recent peers).
- **`libs/hbb_common/src/fs.rs`**: Tracks files and directories, checks checksum digests for resumable file transfers, and handles directory traversal.
- **`libs/hbb_common/src/stream.rs`**: Standardizes streams (TCP, WebRTC, KCP) into a single struct with standard `send()` and `next()` methods.
- **`libs/hbb_common/src/webrtc.rs`**: Standardizes WebRTC connection logic for mobile video transfers.
- **`libs/hbb_common/src/password_security.rs`**: Manages temporary passwords, permanent password hashes, and validation rules.
- **`libs/hbb_common/src/nostr_signaling.rs`**: Core WebRTC signaling logic over Nostr relays:
  - `ensure_started()`: Runs the Nostr relay connection loops.
  - `generate_host_nostr_webrtc_uri()`: Produces the QR code connection link.
  - `publish_webrtc_offer()` / `publish_webrtc_answer()`: Sends WebRTC signals as Nostr text events.

---

## 12. Module Directory & Function Guide

Here is a simplified directory index of all critical modules in the Rust backend:

### Platform-Specific Files (`src/platform/`)
- **`windows.rs`**: Win32 service handling, display capture APIs, registry read/writes, registry modifications for screen blanking (privacy mode), and process privilege checks.
- **`linux.rs`**: X11/Wayland coordinate mappings, Systemd daemon scripts, and PAM authentication hooks.
- **`macos.rs` & `macos.mm`**: macOS accessibility permissions, Cocoa wrappers, and DMG installer updates.

### Session Services (`src/server/`)
- **`video_service.rs`**: Grabs screen capture frames, compresses them using hardware/software codecs (VP9, AV1, H264), and sends them to remote viewers.
- **`audio_service.rs`**: Records audio input from the host microphone, compresses it with the Opus codec, and streams it.
- **`clipboard_service.rs`**: Syncs text and file paste operations between host and client clipboards.
- **`input_service.rs`**: Simulates local mouse movements, keyboard keystrokes, and scroll events received from remote users.
- **`terminal_service.rs`**: Simulates terminal interfaces using pseudoterminals (ConPTY on Windows, PTY on Unix).

### GUI FFI Bindings
- **`src/flutter_ffi.rs`**: Declares native functions exposed to the Dart VM (such as initiating sessions, editing options, and reading LAN lists).
- **`src/flutter.rs`**: Coordinates active window sessions, dispatches keyboard layout translations, and posts global JSON events to Dart.
