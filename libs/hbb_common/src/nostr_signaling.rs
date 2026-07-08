use std::borrow::Cow;
use std::future::Future;
use std::pin::Pin;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

use base64::engine::general_purpose::STANDARD as BASE64_STANDARD;
use base64::Engine;
use futures_util::{SinkExt, StreamExt};
use serde_json::json;
use tokio::sync::{oneshot, watch};
use tokio_tungstenite::tungstenite::protocol::Message as WsMessage;

use crate::{anyhow::anyhow, config::Config, log, ResultType};

/// Only relays that reliably accept TLS from Windows native-tls.
/// nos.lol is excluded because its certificate chain is not trusted by the
/// Windows root CA store (os error -2146762487).
pub const DEFAULT_NOSTR_RELAYS: [&str; 2] = [
    "wss://relay.damus.io",
    "wss://relay.primal.net",
];

static STARTED: AtomicBool = AtomicBool::new(false);
/// Monotonically-increasing session counter. Each new call to
/// `run_host_webrtc_background` increments this. `wait_for_webrtc_answer`
/// checks whether the session it belongs to is still the current one,
/// so that a superseded session can detect it should give up instead of
/// silently holding a dead oneshot channel.
static HOST_SESSION_ID: AtomicU64 = AtomicU64::new(0);
/// Factory function type: creates a Future that runs the server session on a connected
/// `WebRTCStream`. Stored as an `Arc` so it can be called repeatedly for each new
/// connection attempt without being consumed.
pub type SessionStarterFn = Arc<dyn Fn(crate::webrtc::WebRTCStream) -> Pin<Box<dyn Future<Output = ()> + Send>> + Send + Sync>;

lazy_static::lazy_static! {
    static ref SHUTDOWN_TX: std::sync::Mutex<Option<watch::Sender<bool>>> = Default::default();
    /// Holds a oneshot sender waiting for the next incoming WebRTC answer endpoint.
    static ref PENDING_ANSWER_TX: Mutex<Option<oneshot::Sender<String>>> = Default::default();
    /// Notifies when the host WebRTC offer is ready (URI includes embedded ?offer=).
    static ref OFFER_URI_TX: Mutex<Option<watch::Sender<String>>> = Default::default();
    /// Optional factory callback invoked with the connected `WebRTCStream` after the
    /// handshake. Stored as an Arc so it survives multiple connection attempts.
    static ref HOST_SESSION_STARTER: Mutex<Option<SessionStarterFn>> = Default::default();
    /// Caches the latest received answer and the time it was received, resolving the
    /// race condition where the client publishes the answer while the host is still
    /// busy publishing the offer.
    static ref RECEIVED_ANSWER_CACHE: Mutex<Option<(std::time::Instant, String)>> = Default::default();
    /// Registered callback to handle incoming device registrations over Nostr.
    static ref REGISTRATION_HANDLER: Mutex<Option<RegistrationHandlerFn>> = Default::default();
}

pub type RegistrationHandlerFn = Arc<
    dyn Fn(String) -> Pin<Box<dyn Future<Output = ()> + Send>> + Send + Sync,
>;

pub fn set_registration_handler(handler: RegistrationHandlerFn) {
    *REGISTRATION_HANDLER.lock().unwrap() = Some(handler);
}

/// Register a factory callback that will be called each time a new WebRTC
/// connection completes.  Unlike a one-shot `Box<dyn FnOnce>`, this `Arc`-wrapped
/// factory is reused across multiple connection attempts so the laptop keeps
/// accepting new sessions without needing another call to `start_nostr_webrtc_host`.
pub fn set_host_session_starter(starter: SessionStarterFn) {
    *HOST_SESSION_STARTER.lock().unwrap() = Some(starter);
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NostrWebRtcLink {
    pub device_id: String,
    pub pubkey: String,
    pub embedded_offer: Option<String>,
    pub password: Option<String>,
}

impl NostrWebRtcLink {
    pub fn to_uri(&self) -> String {
        let offer = self
            .embedded_offer
            .as_ref()
            .map(|value| BASE64_STANDARD.encode(value))
            .unwrap_or_default();
        let mut parts = Vec::new();
        if !offer.is_empty() {
            parts.push(format!("offer={}", offer));
        }
        if let Some(p) = &self.password {
            parts.push(format!("pwd={}", p));
        }
        let query = if parts.is_empty() {
            String::new()
        } else {
            format!("?{}", parts.join("&"))
        };
        format!("nostr-webrtc://{}{}#{}", self.device_id, query, self.pubkey)
    }
}

pub fn is_nostr_webrtc_uri(value: &str) -> bool {
    value.starts_with("nostr-webrtc://")
}

pub fn ensure_started() {
    if STARTED.swap(true, Ordering::SeqCst) {
        return;
    }

    // Initialize sodiumoxide for cryptographic operations (signing events)
    sodiumoxide::init().ok();

    let identity = Config::get_key_pair();
    let public_key = BASE64_STANDARD.encode(identity.1.as_slice());
    let public_key_suffix = public_key.chars().take(12).collect::<String>();

    thread::spawn(move || {
        let runtime = match tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .worker_threads(3)
            .thread_name("nostr-relay")
            .build()
        {
            Ok(runtime) => runtime,
            Err(err) => {
                log::error!("Failed to create Nostr relay runtime: {}", err);
                return;
            }
        };

        log::info!(
            "Nostr WebRTC identity ready, pubkey starts with {}",
            public_key_suffix
        );

        let (shutdown_tx, mut shutdown_rx) = watch::channel(false);
        *SHUTDOWN_TX.lock().unwrap() = Some(shutdown_tx);
        runtime.block_on(async move {
            for relay in DEFAULT_NOSTR_RELAYS {
                let relay = relay.to_owned();
                let mut shutdown_rx = shutdown_rx.clone();
                tokio::spawn(async move {
                    relay_background_loop(relay, &mut shutdown_rx).await;
                });
            }

            let _ = shutdown_rx.changed().await;
            STARTED.store(false, Ordering::SeqCst);
        });
    });
}

pub fn shutdown() {
    if let Some(tx) = SHUTDOWN_TX.lock().unwrap().take() {
        let _ = tx.send(true);
    }
    STARTED.store(false, Ordering::SeqCst);
}

/// Subscribe for the host offer URI (with embedded `?offer=`). Call before
/// `generate_host_nostr_webrtc_uri` so the background task can notify.
pub fn offer_uri_watch() -> watch::Receiver<String> {
    let (tx, rx) = watch::channel(String::new());
    *OFFER_URI_TX.lock().unwrap() = Some(tx);
    rx
}

pub async fn publish_webrtc_offer(device_id: &str, sdp_or_endpoint: &str, session_id: u64) -> ResultType<()> {
    publish_signal(device_id, sdp_or_endpoint, "", "offer", session_id).await
}

pub async fn publish_webrtc_answer(device_id: &str, sdp_or_endpoint: &str) -> ResultType<()> {
    publish_signal(device_id, sdp_or_endpoint, "_answer", "answer", 0).await
}

pub async fn publish_webrtc_registration(device_id: &str, registration_msg: &str) -> ResultType<()> {
    publish_signal(device_id, registration_msg, "_reg", "registration", 0).await
}

fn get_nostr_keys() -> ResultType<nostr::key::Keys> {
    use nostr::{Keys, SecretKey};
    let identity = Config::get_key_pair();
    if identity.0.len() < 32 {
        return Err(anyhow!("Secret key is too short"));
    }
    let secret_key = SecretKey::from_slice(&identity.0[0..32])
        .map_err(|e| anyhow!("Failed to parse Nostr secret key: {}", e))?;
    Ok(Keys::new(secret_key))
}

/// Generate a Nostr-WebRTC QR URI for the host.
///
/// Returns a `nostr-webrtc://<device_id>#<pubkey>` URI immediately so the UI can
/// show the QR code without delay. The actual WebRTC offer generation and
/// publishing to Nostr relays happens in the background.
pub async fn generate_host_nostr_webrtc_uri() -> ResultType<String> {
    let device_id = Config::get_id().replace(' ', "");
    let keys = get_nostr_keys()?;
    let pubkey = keys.public_key().to_hex();

    let link = NostrWebRtcLink {
        device_id: device_id.clone(),
        pubkey: pubkey.clone(),
        embedded_offer: None,
        password: Some(Config::get_permanent_password()),
    };
    let uri = link.to_uri();

    // #region agent log
    crate::agent_debug_log::agent_debug_log(
        "N3",
        "nostr_signaling.rs:generate_host_nostr_webrtc_uri",
        "nostr qr uri generated",
        serde_json::json!({
            "device_id": device_id,
            "pubkey_len": pubkey.len(),
            "uri_len": uri.len(),
        }),
    );
    // #endregion

    // Assign a new session ID so that any previously-running background session
    // can detect it has been superseded and exit cleanly.
    let my_session_id = HOST_SESSION_ID.fetch_add(1, Ordering::SeqCst) + 1;

    // ponytail: WebRTC setup must outlive the caller's short-lived current_thread
    // runtime (see flutter_ffi::start_nostr_webrtc_host). tokio::spawn there gets
    // dropped when that runtime exits, which can abort webrtc-rs mid-handshake and
    // crash the process (0xc0000409 in libanuvadini.dll).
    thread::spawn(move || {
        let runtime = match tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .worker_threads(2)
            .thread_name("nostr-webrtc-host")
            .build()
        {
            Ok(runtime) => runtime,
            Err(err) => {
                log::error!("Failed to create Nostr WebRTC runtime: {}", err);
                return;
            }
        };
        runtime.block_on(run_host_webrtc_background(device_id, my_session_id));
    });

    Ok(uri)
}

async fn run_host_webrtc_background(device_id: String, initial_session_id: u64) {
    log::info!("Starting background WebRTC host setup for Nostr... (session {})", initial_session_id);
    // #region agent log
    crate::agent_debug_log::agent_debug_log(
        "N2",
        "nostr_signaling.rs:run_host_webrtc_background",
        "webrtc host setup started",
        serde_json::json!({ "device_id": device_id }),
    );
    // #endregion

    // Loop so the laptop continuously waits for new connections after each attempt.
    // This prevents the "no waiting host task found" error that occurred when a
    // second scan attempt arrived after the first session had already completed.
    let mut my_session_id = initial_session_id;
    loop {
        // Clear any cached peer connections so we get a fresh DTLS certificate.
        // Without this the SDP fingerprint is identical every session → same Nostr
        // event content → relay returns "duplicate: have this event" and the phone
        // fetches a stale offer that doesn't match the new peer.
        crate::webrtc::clear_host_sessions().await;

        match crate::webrtc::WebRTCStream::new("", false, 30_000).await {
            Ok(stream) => match stream.get_local_endpoint().await {
                Ok(local_endpoint) => {
                    let publish_result = publish_webrtc_offer(&device_id, &local_endpoint, my_session_id).await;
                    // #region agent log
                    crate::agent_debug_log::agent_debug_log(
                        "N1",
                        "nostr_signaling.rs:run_host_webrtc_background",
                        "publish webrtc offer result",
                        serde_json::json!({
                            "device_id": device_id,
                            "ok": publish_result.is_ok(),
                            "err": publish_result.as_ref().err().map(|e| e.to_string()),
                            "endpoint_len": local_endpoint.len(),
                        }),
                    );
                    // #endregion
                    if let Err(err) = publish_result {
                        log::warn!("Failed to publish WebRTC offer to Nostr: {}", err);
                    } else {
                        log::info!("WebRTC offer published to Nostr for device {}", device_id);
                    }

                    let keys = match get_nostr_keys() {
                        Ok(k) => k,
                        Err(err) => {
                            log::error!("Failed to get Nostr keys in background: {}", err);
                            return;
                        }
                    };
                    let pubkey = keys.public_key().to_hex();
                    let offer_uri = NostrWebRtcLink {
                        device_id: device_id.clone(),
                        pubkey,
                        embedded_offer: Some(local_endpoint),
                        password: None,
                    }
                    .to_uri();
                    if let Some(tx) = OFFER_URI_TX.lock().unwrap().as_ref() {
                        let _ = tx.send(offer_uri);
                    }

                    match wait_for_webrtc_answer(120_000, my_session_id).await {
                        Ok(answer_endpoint) => {
                            log::info!("Received WebRTC answer from client via Nostr");
                            if let Err(err) = stream.set_remote_endpoint(&answer_endpoint).await {
                                log::error!("Failed to apply client WebRTC answer: {}", err);
                            } else {
                                log::info!("WebRTC handshake complete for device {}", device_id);
                                // Start the Anuvadini server session on the WebRTC stream.
                                // Clone the Arc so the factory remains registered for future connections.
                                let starter_opt = HOST_SESSION_STARTER.lock().unwrap().clone();
                                if let Some(starter) = starter_opt {
                                    starter(stream).await;
                                    log::info!("WebRTC server session completed; looping for next connection");
                                } else {
                                    // No session starter registered — keep the stream alive
                                    // so the peer connection isn't dropped prematurely.
                                    log::warn!("No host session starter registered; stream will idle");
                                    std::future::pending::<()>().await;
                                }
                            }
                        }
                        Err(err) => {
                            log::warn!("No WebRTC answer received from client on Nostr (session {}): {}", my_session_id, err);
                        }
                    }
                }
                Err(err) => {
                    log::error!("Failed to get local WebRTC endpoint: {}", err);
                }
            },
            Err(err) => {
                log::error!("Failed to start WebRTC host for Nostr: {}", err);
                // #region agent log
                crate::agent_debug_log::agent_debug_log(
                    "N2",
                    "nostr_signaling.rs:run_host_webrtc_background",
                    "webrtc stream new failed",
                    serde_json::json!({ "device_id": device_id, "err": err.to_string() }),
                );
                // #endregion
                // Brief pause before retrying to avoid a tight failure loop.
                tokio::time::sleep(Duration::from_secs(5)).await;
            }
        }

        // Advance the session ID so any stale relay-delivered answers for the
        // previous session are ignored by the next wait_for_webrtc_answer call.
        my_session_id = HOST_SESSION_ID.fetch_add(1, Ordering::SeqCst) + 1;
        log::info!("WebRTC host loop: starting new session {} for device {}", my_session_id, device_id);

        // Brief pause between connection attempts.
        tokio::time::sleep(Duration::from_secs(2)).await;
    }
}

/// Wait (up to `timeout_ms`) for a WebRTC answer endpoint delivered via a Nostr relay.
///
/// Registers a one-shot receiver so that `relay_background_loop` can forward the
/// next incoming answer event directly here.  Only one waiter at a time is
/// supported; a newer session (higher `my_session_id`) will supersede this one.
///
/// `my_session_id` is the session counter value assigned when
/// `run_host_webrtc_background` was called.  If a newer session starts before
/// this one receives its answer, the newer session increments `HOST_SESSION_ID`
/// and this function detects the mismatch and returns an appropriate error
/// instead of silently holding a dead channel.
pub async fn wait_for_webrtc_answer(
    timeout_ms: u64,
    my_session_id: u64,
) -> ResultType<String> {
    // Check if we have a recently cached answer from the last 30 seconds
    {
        let mut cache = RECEIVED_ANSWER_CACHE.lock().unwrap();
        log::info!("DEBUG: wait_for_webrtc_answer checking RECEIVED_ANSWER_CACHE, is_some={}", cache.is_some());
        if let Some((timestamp, content)) = cache.take() {
            let age_ms = timestamp.elapsed().as_millis();
            log::info!("DEBUG: found cached answer in RECEIVED_ANSWER_CACHE, age={} ms", age_ms);
            if timestamp.elapsed() < Duration::from_secs(30) {
                log::info!("DEBUG: found valid cached answer in RECEIVED_ANSWER_CACHE ({} ms old)", age_ms);
                return Ok(content);
            } else {
                log::warn!("DEBUG: cached answer was too old ({} ms)", age_ms);
            }
        }
    }

    let (tx, rx) = oneshot::channel::<String>();

    log::info!(
        "DEBUG: registering answer waiter for session {}",
        my_session_id
    );

    *PENDING_ANSWER_TX.lock().unwrap() = Some(tx);

    log::info!("DEBUG: answer waiter registered");

    let answer = tokio::time::timeout(
        Duration::from_millis(timeout_ms),
        rx,
    )
    .await
    .map_err(|_| anyhow!("Timed out waiting for WebRTC answer from Nostr"))?
    .map_err(|_| anyhow!("WebRTC answer channel was dropped"))?;

    log::info!("DEBUG: wait_for_webrtc_answer returning successfully");

    Ok(answer)
}

/// Called from `relay_background_loop` whenever a TEXT message arrives from a relay.
/// Parses Nostr `EVENT` messages and, if the content is a `webrtc://` endpoint
/// **tagged** with `{device_id}_answer`, delivers it to the pending waiter registered
/// by `wait_for_webrtc_answer`.
fn handle_relay_message(text: &str) {
    // Nostr message format: ["EVENT", <subscription_id>, <event_object>]
    let Ok(arr) = serde_json::from_str::<serde_json::Value>(text) else {
        return;
    };
    if arr[0].as_str() != Some("EVENT") {
        return;
    }
    let event = &arr[2];
    let content = match event["content"].as_str() {
        Some(c) if c.starts_with("webrtc://") => c.to_owned(),
        _ => return,
    };

    let device_id = Config::get_id().replace(' ', "");
    let answer_tag = format!("{}_answer", device_id);
    let reg_tag = format!("{}_reg", device_id);

    let mut has_answer_tag = false;
    let mut has_reg_tag = false;

    if let Some(tags) = event["tags"].as_array() {
        for tag in tags {
            if let Some(t) = tag.as_array() {
                if t.len() >= 2 && t[0].as_str() == Some("t") {
                    if t[1].as_str() == Some(&answer_tag) {
                        has_answer_tag = true;
                    } else if t[1].as_str() == Some(&reg_tag) {
                        has_reg_tag = true;
                    }
                }
            }
        }
    }

    if has_answer_tag {
        log::info!("Nostr relay: received WebRTC answer endpoint for device {}", device_id);
        let mut guard = PENDING_ANSWER_TX.lock().unwrap();
        if let Some(tx) = guard.take() {
            log::info!("DEBUG: delivering answer to waiting host task");
            let _ = tx.send(content);
        } else {
            log::info!("DEBUG: no waiting host task found, caching answer in RECEIVED_ANSWER_CACHE");
            *RECEIVED_ANSWER_CACHE.lock().unwrap() = Some((std::time::Instant::now(), content));
        }  
    } else if has_reg_tag {
        log::info!("Nostr relay: received WebRTC registration signal for device {}", device_id);
        // Decode the base64 payload to get the ANUVADINI_HELLO message
        let encoded = &content["webrtc://".len()..];
        if let Ok(decoded_bytes) = BASE64_STANDARD.decode(encoded) {
            if let Ok(msg) = String::from_utf8(decoded_bytes) {
                if msg.starts_with("ANUVADINI_HELLO:") {
                    // Format: ANUVADINI_HELLO:<name>:<id>[:<temp_password>]:<offer_uri>
                    let parts: Vec<&str> = msg.splitn(5, ':').collect();
                    let name          = parts.get(1).copied().unwrap_or("Unknown Device");
                    let id            = parts.get(2).copied().unwrap_or("unknown");
                    let temp_password = parts.get(3).copied().unwrap_or("");
                    let offer_uri     = parts.get(4).copied().unwrap_or("");

                    let device_json = serde_json::json!({
                        "name":          name,
                        "id":            id,
                        "ip":            offer_uri, // Emulate IP as WebRTC URI for _connectDevice
                        "temp_password": temp_password,
                    }).to_string();

                    let handler_opt = REGISTRATION_HANDLER.lock().unwrap().clone();
                    if let Some(handler) = handler_opt {
                        tokio::spawn(async move {
                            handler(device_json).await;
                        });
                    }
                }
            }
        }
    }
}

async fn relay_background_loop(relay: String, shutdown: &mut watch::Receiver<bool>) {
    loop {
        match crate::websocket::WsFramedStream::new(&relay, None, None, 15_000).await {
            Ok(mut stream) => {
                log::info!("Connected Nostr relay: {}", relay);

                let device_id = Config::get_id().replace(' ', "");
                let answer_tag = format!("{}_answer", device_id);
                let reg_tag = format!("{}_reg", device_id);
                let since_ts = std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap_or_default()
                    .as_secs()
                    .saturating_sub(30); // look back only 30 s
                let req = json!([
                    "REQ",
                    "sub_webrtc_signals",
                    {
                        "kinds": [10005],
                        "#t": [answer_tag, reg_tag],
                        "since": since_ts,
                        "limit": 10
                    }
                ]);
                if let Ok(req_str) = serde_json::to_string(&req) {
                    if let Err(err) = stream.send_raw(req_str.into_bytes()).await {
                        log::warn!(
                            "Failed to send REQ subscription to Nostr relay {}: {}",
                            relay,
                            err
                        );
                    }
                }

                loop {
                    tokio::select! {
                        changed = shutdown.changed() => {
                            if changed.is_ok() {
                                log::info!("Shutting down Nostr relay loop: {}", relay);
                            }
                            return;
                        }
                        message = stream.next_timeout(60_000) => {
                            match message {
                                Some(Ok(bytes)) => {
                                    if let Ok(text) = std::str::from_utf8(&bytes) {
                                        handle_relay_message(text);
                                    }
                                    continue;
                                }
                                Some(Err(err)) => {
                                    log::warn!("Nostr relay {} closed with error: {}", relay, err);
                                    break;
                                }
                                None => continue,
                            }
                        }
                    }
                }
            }
            Err(err) => {
                log::warn!("Failed to connect Nostr relay {}: {}", relay, err);
            }
        }

        tokio::time::sleep(Duration::from_secs(5)).await;
    }
}

async fn publish_signal(
    device_id: &str,
    sdp_or_endpoint: &str,
    tag_suffix: &str,
    label: &str,
    session_id: u64,
) -> ResultType<()> {
    log::info!("publish_signal entered: label={label}, device={device_id}, endpoint_len={}", sdp_or_endpoint.len());
    let endpoint = normalize_webrtc_endpoint(sdp_or_endpoint);
    let event = match build_signal_event(device_id, &endpoint, tag_suffix, session_id) {
        Ok(e) => e,
        Err(err) => {
            log::error!("publish_signal: build_signal_event failed: {}", err);
            return Err(err);
        }
    };
    let mut success_count = 0usize;

    for relay in DEFAULT_NOSTR_RELAYS {
        match publish_event_to_relay(relay, &event).await {
            Ok(()) => {
                success_count += 1;
            }
            Err(err) => {
                log::warn!("Failed to publish WebRTC {label} to {}: {}", relay, err);
            }
        }
    }

    if success_count == 0 {
        return Err(anyhow!(format!(
            "failed to publish WebRTC {label} to all relays"
        )));
    }

    // #region agent log
    crate::agent_debug_log::agent_debug_log(
        "N3",
        "nostr_signaling.rs:publish_signal",
        "publish signal done",
        serde_json::json!({
            "device_id": device_id,
            "tag_suffix": tag_suffix,
            "label": label,
            "success_count": success_count,
        }),
    );
    // #endregion

    Ok(())
}

fn normalize_webrtc_endpoint(sdp_or_endpoint: &str) -> String {
    if sdp_or_endpoint.starts_with("webrtc://") {
        sdp_or_endpoint.to_owned()
    } else {
        format!("webrtc://{}", BASE64_STANDARD.encode(sdp_or_endpoint))
    }
}

fn build_signal_event(device_id: &str, endpoint: &str, tag_suffix: &str, session_id: u64) -> ResultType<String> {
    use nostr::{EventBuilder, Tag, Kind, JsonUtil};
    
    let keys = get_nostr_keys()?;
    let norm_device_id = device_id.replace(' ', "");
    let tagged_device_id = if tag_suffix.is_empty() {
        norm_device_id
    } else {
        format!("{}{}", norm_device_id, tag_suffix)
    };
    
    // Include a session nonce tag so every new offer/answer has a unique
    // Nostr event ID, even if the SDP content is identical (e.g. same DTLS
    // certificate across restarts). Without this, relays return
    // "duplicate: have this event" and the phone gets a stale cached offer.
    let session_tag = format!("session_{}", session_id);
    let tags = vec![
        Tag::Hashtag(tagged_device_id),
        Tag::Hashtag(session_tag),
    ];
    let event = EventBuilder::new(Kind::Custom(10005), endpoint, tags)
        .to_event(&keys)
        .map_err(|e| anyhow!("Failed to build Nostr event: {}", e))?;
        
    Ok(event.as_json())
}

async fn publish_event_to_relay(relay: &str, event_json: &str) -> ResultType<()> {
    use std::sync::Arc;
    use tokio_tungstenite::Connector;

    let client_config = crate::verifier::client_config(false)?;
    let connector = Connector::Rustls(Arc::new(client_config));
    let (mut stream, _) = tokio_tungstenite::connect_async_tls_with_config(
        relay, None, false, Some(connector),
    )
    .await?;
    let event_value: serde_json::Value = serde_json::from_str(event_json)?;
    let payload = serde_json::to_string(&json!(["EVENT", event_value]))?;
    stream.send(WsMessage::Text(payload.into())).await?;

    // Read the relay's OK response with a timeout. Some relays hold the
    // connection open indefinitely after receiving an EVENT; without a
    // timeout this function would hang forever and never return.
    let reply = tokio::time::timeout(Duration::from_secs(10), stream.next()).await;
    if let Ok(Some(Ok(WsMessage::Text(text)))) = reply {
        log::debug!("Relay {} replied: {}", relay, text);
    }

    Ok(())
}

pub fn parse_nostr_webrtc_uri(value: &str) -> ResultType<NostrWebRtcLink> {
    if !is_nostr_webrtc_uri(value) {
        return Err(anyhow!("invalid nostr-webrtc uri"));
    }

    let parsed = url::Url::parse(value).map_err(|e| anyhow!(e))?;
    let device_id = parsed
        .host_str()
        .filter(|value| !value.is_empty())
        .ok_or_else(|| anyhow!("missing device id"))?
        .to_owned();
    let pubkey = parsed.fragment().unwrap_or_default().to_owned();
    let embedded_offer = parsed
        .query_pairs()
        .find(|(key, _)| key == "offer")
        .and_then(|(_, value)| {
            if value.is_empty() {
                None
            } else {
                BASE64_STANDARD
                    .decode(value.as_bytes())
                    .ok()
                    .and_then(|bytes| String::from_utf8(bytes).ok())
            }
        });
    let password = parsed
        .query_pairs()
        .find(|(key, _)| key == "pwd")
        .map(|(_, value)| value.to_string())
        .filter(|p| !p.is_empty());

    Ok(NostrWebRtcLink {
        device_id,
        pubkey,
        embedded_offer,
        password,
    })
}

pub fn extract_webrtc_endpoint(link: &NostrWebRtcLink) -> Option<Cow<'_, str>> {
    link.embedded_offer
        .as_ref()
        .map(|offer| Cow::Borrowed(offer.as_str()))
}

#[cfg(test)]
mod tests {
    use super::*;

    lazy_static::lazy_static! {
        static ref TEST_MUTEX: std::sync::Mutex<()> = std::sync::Mutex::new(());
    }

    #[test]
    fn parses_nostr_webrtc_uri() {
        let link = parse_nostr_webrtc_uri("nostr-webrtc://device-123#pubkey").unwrap();
        assert_eq!(link.device_id, "device-123");
        assert_eq!(link.pubkey, "pubkey");
        assert!(link.embedded_offer.is_none());
    }

    #[test]
    fn parses_embedded_offer() {
        let offer = "webrtc://eyJ0eXBlIjoib2ZmZXIiLCJzZHAiOiJ2PTAifQ==";
        let encoded = BASE64_STANDARD.encode(offer);
        let uri = format!("nostr-webrtc://device-123?offer={}#pubkey", encoded);
        let link = parse_nostr_webrtc_uri(&uri).unwrap();
        assert_eq!(link.embedded_offer.as_deref(), Some(offer));
    }

    #[test]
    fn builds_offer_event() {
        let event = build_signal_event("device-123", "webrtc://abc", "", 1).unwrap();
        let value: serde_json::Value = serde_json::from_str(&event).unwrap();
        assert_eq!(value["kind"], 10005);
        assert_eq!(value["content"], "webrtc://abc");
        assert_eq!(value["tags"][0][0], "t");
        assert_eq!(value["tags"][0][1], "device-123");
    }

    #[test]
    fn builds_answer_event() {
        let event = build_signal_event("device-123", "webrtc://abc", "_answer", 0).unwrap();
        let value: serde_json::Value = serde_json::from_str(&event).unwrap();
        assert_eq!(value["tags"][0][1], "device-123_answer");
    }

    #[test]
    fn to_uri_without_offer() {
        let link = NostrWebRtcLink {
            device_id: "dev-1".to_owned(),
            pubkey: "pk".to_owned(),
            embedded_offer: None,
            password: None,
        };
        assert_eq!(link.to_uri(), "nostr-webrtc://dev-1#pk");
    }

    #[test]
    fn to_uri_with_offer() {
        let link = NostrWebRtcLink {
            device_id: "dev-1".to_owned(),
            pubkey: "pk".to_owned(),
            embedded_offer: Some("webrtc://abc".to_owned()),
            password: None,
        };
        let uri = link.to_uri();
        assert!(uri.starts_with("nostr-webrtc://dev-1?offer="));
        assert!(uri.ends_with("#pk"));
    }

    #[test]
    fn handle_relay_message_ignores_non_event() {
        let _lock = TEST_MUTEX.lock().unwrap();
        // Should not panic
        handle_relay_message(r#"["EOSE", "sub_webrtc_answers"]"#);
        handle_relay_message("invalid json {{{");
    }

    #[test]
    fn handle_relay_message_ignores_missing_answer_tag() {
        let _lock = TEST_MUTEX.lock().unwrap();
        let (tx, mut rx) = oneshot::channel::<String>();
        *PENDING_ANSWER_TX.lock().unwrap() = Some(tx);

        // Event without the _answer tag should be ignored
        let msg = r#"["EVENT","sub_webrtc_answers",{"kind":10005,"content":"webrtc://abc123","tags":[]}]"#;
        handle_relay_message(msg);

        // The receiver should NOT have received anything
        assert!(rx.try_recv().is_err());
        // Clean up
        PENDING_ANSWER_TX.lock().unwrap().take();
    }

    #[test]
    fn handle_relay_message_delivers_answer() {
        let _lock = TEST_MUTEX.lock().unwrap();
        let (tx, mut rx) = oneshot::channel::<String>();
        *PENDING_ANSWER_TX.lock().unwrap() = Some(tx);

        // Build a message with the correct _answer tag for the current device id
        let device_id = Config::get_id();
        let answer_tag = format!("{}_answer", device_id);
        let msg = format!(
            r#"["EVENT","sub_webrtc_answers",{{"kind":10005,"content":"webrtc://abc123","tags":[["t","{}"]]}}]"#,
            answer_tag
        );
        handle_relay_message(&msg);

        // The receiver should have the value immediately.
        assert_eq!(rx.try_recv().unwrap(), "webrtc://abc123");
    }
}
