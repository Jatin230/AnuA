use std::borrow::Cow;
use std::convert::TryInto;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use base64::engine::general_purpose::STANDARD as BASE64_STANDARD;
use base64::Engine;
use futures_util::{SinkExt, StreamExt};
use serde_json::json;
use sha2::{Digest, Sha256};
use tokio::sync::{oneshot, watch};
use tokio_tungstenite::{connect_async, tungstenite::protocol::Message as WsMessage};

use crate::{anyhow::anyhow, config::Config, log, ResultType};

pub const DEFAULT_NOSTR_RELAYS: [&str; 3] = [
    "wss://relay.damus.io",
    "wss://nos.lol",
    "wss://relay.primal.net",
];

static STARTED: AtomicBool = AtomicBool::new(false);
lazy_static::lazy_static! {
    static ref SHUTDOWN_TX: std::sync::Mutex<Option<watch::Sender<bool>>> = Default::default();
    /// Holds a oneshot sender waiting for the next incoming WebRTC answer endpoint.
    static ref PENDING_ANSWER_TX: Mutex<Option<oneshot::Sender<String>>> = Default::default();
    /// Notifies when the host WebRTC offer is ready (URI includes embedded ?offer=).
    static ref OFFER_URI_TX: Mutex<Option<watch::Sender<String>>> = Default::default();
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NostrWebRtcLink {
    pub device_id: String,
    pub pubkey: String,
    pub embedded_offer: Option<String>,
}

impl NostrWebRtcLink {
    pub fn to_uri(&self) -> String {
        let offer = self
            .embedded_offer
            .as_ref()
            .map(|value| BASE64_STANDARD.encode(value))
            .unwrap_or_default();
        if offer.is_empty() {
            format!("nostr-webrtc://{}#{}", self.device_id, self.pubkey)
        } else {
            format!("nostr-webrtc://{}?offer={}#{}", self.device_id, offer, self.pubkey)
        }
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

pub async fn publish_webrtc_offer(device_id: &str, sdp_or_endpoint: &str) -> ResultType<()> {
    publish_signal(device_id, sdp_or_endpoint, "", "offer").await
}

pub async fn publish_webrtc_answer(device_id: &str, sdp_or_endpoint: &str) -> ResultType<()> {
    publish_signal(device_id, sdp_or_endpoint, "_answer", "answer").await
}

/// Generate a Nostr-WebRTC QR URI for the host.
///
/// Returns a `nostr-webrtc://<device_id>#<pubkey>` URI immediately so the UI can
/// show the QR code without delay. The actual WebRTC offer generation and
/// publishing to Nostr relays happens in the background.
pub async fn generate_host_nostr_webrtc_uri() -> ResultType<String> {
    let device_id = Config::get_id();
    let identity = Config::get_key_pair();
    let pubkey = hex::encode(identity.1.as_slice());

    let link = NostrWebRtcLink {
        device_id: device_id.clone(),
        pubkey: pubkey.clone(),
        embedded_offer: None,
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
        runtime.block_on(run_host_webrtc_background(device_id));
    });

    Ok(uri)
}

async fn run_host_webrtc_background(device_id: String) {
    log::info!("Starting background WebRTC host setup for Nostr...");
    // #region agent log
    crate::agent_debug_log::agent_debug_log(
        "N2",
        "nostr_signaling.rs:run_host_webrtc_background",
        "webrtc host setup started",
        serde_json::json!({ "device_id": device_id }),
    );
    // #endregion
    match crate::webrtc::WebRTCStream::new("", false, 30_000).await {
        Ok(stream) => match stream.get_local_endpoint().await {
            Ok(local_endpoint) => {
                let publish_result = publish_webrtc_offer(&device_id, &local_endpoint).await;
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

                let identity = Config::get_key_pair();
                let pubkey = hex::encode(identity.1.as_slice());
                let offer_uri = NostrWebRtcLink {
                    device_id: device_id.clone(),
                    pubkey,
                    embedded_offer: Some(local_endpoint),
                }
                .to_uri();
                if let Some(tx) = OFFER_URI_TX.lock().unwrap().as_ref() {
                    let _ = tx.send(offer_uri);
                }

                match wait_for_webrtc_answer(120_000).await {
                    Ok(answer_endpoint) => {
                        log::info!("Received WebRTC answer from client via Nostr");
                        if let Err(err) = stream.set_remote_endpoint(&answer_endpoint).await {
                            log::error!("Failed to apply client WebRTC answer: {}", err);
                        } else {
                            log::info!("WebRTC handshake complete for device {}", device_id);
                        }
                    }
                    Err(err) => {
                        log::warn!("No WebRTC answer received from client on Nostr: {}", err);
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
        }
    }
}

/// Wait (up to `timeout_ms`) for a WebRTC answer endpoint delivered via a Nostr relay.
///
/// Registers a one-shot receiver so that `relay_background_loop` can forward the
/// next incoming answer event directly here.  Only one waiter at a time is
/// supported; a second concurrent call will cancel the first.
pub async fn wait_for_webrtc_answer(timeout_ms: u64) -> ResultType<String> {
    let (tx, rx) = oneshot::channel::<String>();
    *PENDING_ANSWER_TX.lock().unwrap() = Some(tx);

    match tokio::time::timeout(Duration::from_millis(timeout_ms), rx).await {
        Ok(Ok(answer)) => Ok(answer),
        Ok(Err(_)) => Err(anyhow!("WebRTC answer channel was dropped")),
        Err(_) => {
            // Clean up the stale sender so it does not block future waiters.
            PENDING_ANSWER_TX.lock().unwrap().take();
            Err(anyhow!("Timed out waiting for WebRTC answer from Nostr"))
        }
    }
}

/// Called from `relay_background_loop` whenever a TEXT message arrives from a relay.
/// Parses Nostr `EVENT` messages and, if the content is a `webrtc://` endpoint,
/// delivers it to the pending waiter registered by `wait_for_webrtc_answer`.
fn handle_relay_message(text: &str) {
    // Nostr message format: ["EVENT", <subscription_id>, <event_object>]
    let Ok(arr) = serde_json::from_str::<serde_json::Value>(text) else {
        return;
    };
    if arr[0].as_str() != Some("EVENT") {
        return;
    }
    let content = match arr[2]["content"].as_str() {
        Some(c) if c.starts_with("webrtc://") => c.to_owned(),
        _ => return,
    };

    log::debug!("Nostr relay: received WebRTC answer endpoint");

    let mut guard = PENDING_ANSWER_TX.lock().unwrap();
    if let Some(tx) = guard.take() {
        let _ = tx.send(content);
    }
}

async fn relay_background_loop(relay: String, shutdown: &mut watch::Receiver<bool>) {
    loop {
        match crate::websocket::WsFramedStream::new(&relay, None, None, 15_000).await {
            Ok(mut stream) => {
                log::info!("Connected Nostr relay: {}", relay);

                // Subscribe to WebRTC answer events tagged with our device ID.
                let device_id = Config::get_id();
                let answer_tag = format!("{}_answer", device_id);
                let req = json!([
                    "REQ",
                    "sub_webrtc_answers",
                    {
                        "kinds": [20005],
                        "#t": [answer_tag],
                        "limit": 1
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
) -> ResultType<()> {
    let endpoint = normalize_webrtc_endpoint(sdp_or_endpoint);
    let event = build_signal_event(device_id, &endpoint, tag_suffix)?;
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

fn build_signal_event(device_id: &str, endpoint: &str, tag_suffix: &str) -> ResultType<String> {
    let identity = Config::get_key_pair();
    let secret_key_bytes: [u8; sodiumoxide::crypto::sign::SECRETKEYBYTES] = identity
        .0
        .as_slice()
        .try_into()
        .map_err(|_| anyhow!("invalid secret key length"))?;
    let secret_key = sodiumoxide::crypto::sign::SecretKey(secret_key_bytes);
    let public_key_hex = hex::encode(identity.1.as_slice());
    let created_at = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|err| anyhow!(err))?
        .as_secs() as i64;
    let tagged_device_id = if tag_suffix.is_empty() {
        device_id.to_owned()
    } else {
        format!("{}{}", device_id, tag_suffix)
    };
    let tags = vec![vec!["t".to_owned(), tagged_device_id]];
    let event_tags = tags.clone();
    let unsigned = json!([0, public_key_hex, created_at, 20005, tags, endpoint]);
    let unsigned_json = serde_json::to_string(&unsigned)?;
    let event_id_bytes = Sha256::digest(unsigned_json.as_bytes());
    let event_id_hex = hex::encode(event_id_bytes);
    let signature = sodiumoxide::crypto::sign::sign_detached(&event_id_bytes, &secret_key);

    serde_json::to_string(&json!({
        "id": event_id_hex,
        "pubkey": public_key_hex,
        "created_at": created_at,
        "kind": 20005,
        "tags": event_tags,
        "content": endpoint,
        "sig": hex::encode(signature.to_bytes()),
    }))
    .map_err(Into::into)
}

async fn publish_event_to_relay(relay: &str, event_json: &str) -> ResultType<()> {
    let (mut stream, _) = connect_async(relay).await?;
    let event_value: serde_json::Value = serde_json::from_str(event_json)?;
    let payload = serde_json::to_string(&json!(["EVENT", event_value]))?;
    stream.send(WsMessage::Text(payload.into())).await?;

    if let Some(reply) = stream.next().await {
        match reply {
            Ok(WsMessage::Text(text)) => {
                log::debug!("Relay {} replied: {}", relay, text);
            }
            Ok(WsMessage::Binary(_)) => {
                log::debug!("Relay {} returned a binary message", relay);
            }
            Ok(WsMessage::Close(_)) => {}
            Ok(_) => {}
            Err(err) => {
                log::warn!("Relay {} publish response error: {}", relay, err);
            }
        }
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

    Ok(NostrWebRtcLink {
        device_id,
        pubkey,
        embedded_offer,
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
        let event = build_signal_event("device-123", "webrtc://abc", "").unwrap();
        let value: serde_json::Value = serde_json::from_str(&event).unwrap();
        assert_eq!(value["kind"], 20005);
        assert_eq!(value["content"], "webrtc://abc");
        assert_eq!(value["tags"][0][0], "t");
        assert_eq!(value["tags"][0][1], "device-123");
    }

    #[test]
    fn builds_answer_event() {
        let event = build_signal_event("device-123", "webrtc://abc", "_answer").unwrap();
        let value: serde_json::Value = serde_json::from_str(&event).unwrap();
        assert_eq!(value["tags"][0][1], "device-123_answer");
    }

    #[test]
    fn to_uri_without_offer() {
        let link = NostrWebRtcLink {
            device_id: "dev-1".to_owned(),
            pubkey: "pk".to_owned(),
            embedded_offer: None,
        };
        assert_eq!(link.to_uri(), "nostr-webrtc://dev-1#pk");
    }

    #[test]
    fn to_uri_with_offer() {
        let link = NostrWebRtcLink {
            device_id: "dev-1".to_owned(),
            pubkey: "pk".to_owned(),
            embedded_offer: Some("webrtc://abc".to_owned()),
        };
        let uri = link.to_uri();
        assert!(uri.starts_with("nostr-webrtc://dev-1?offer="));
        assert!(uri.ends_with("#pk"));
    }

    #[test]
    fn handle_relay_message_ignores_non_event() {
        // Should not panic
        handle_relay_message(r#"["EOSE", "sub_webrtc_answers"]"#);
        handle_relay_message("invalid json {{{");
    }

    #[test]
    fn handle_relay_message_delivers_answer() {
        let (tx, rx) = oneshot::channel::<String>();
        *PENDING_ANSWER_TX.lock().unwrap() = Some(tx);

        let msg = r#"["EVENT","sub_webrtc_answers",{"kind":20005,"content":"webrtc://abc123"}]"#;
        handle_relay_message(msg);

        // The receiver should have the value immediately.
        assert_eq!(rx.try_recv().unwrap(), "webrtc://abc123");
    }
}
