use std::collections::HashMap;
use std::io::{Error, ErrorKind};
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use webrtc::api::setting_engine::{SettingEngine, SctpMaxMessageSize};
use webrtc::api::APIBuilder;
use webrtc::data_channel::RTCDataChannel;
use webrtc::ice::mdns::MulticastDnsMode;
use webrtc::ice_transport::ice_connection_state::RTCIceConnectionState;
use webrtc::ice_transport::ice_gatherer_state::RTCIceGathererState;
use webrtc::ice_transport::ice_server::RTCIceServer;
use webrtc::peer_connection::configuration::RTCConfiguration;
use webrtc::peer_connection::peer_connection_state::RTCPeerConnectionState;
use webrtc::peer_connection::policy::ice_transport_policy::RTCIceTransportPolicy;
use webrtc::peer_connection::sdp::session_description::RTCSessionDescription;
use webrtc::peer_connection::signaling_state::RTCSignalingState;
use webrtc::peer_connection::RTCPeerConnection;

use base64::engine::general_purpose::STANDARD as BASE64_STANDARD;
use base64::Engine;
use bytes::{Bytes, BytesMut};
use tokio::sync::watch;
use tokio::sync::Mutex;
use tokio::time::timeout;
use url::Url;

use crate::config;
use crate::protobuf::Message;
use crate::sodiumoxide::crypto::secretbox::Key;
use crate::ResultType;

pub struct WebRTCStream {
    pc: Arc<RTCPeerConnection>,
    stream: Arc<Mutex<Arc<RTCDataChannel>>>,
    state_notify: watch::Receiver<bool>,
    /// Notified when the peer connection enters Failed state (ICE restart needed).
    failed_tx: watch::Sender<bool>,
    failed_rx: watch::Receiver<bool>,
    send_timeout: u64,
    /// Cached detached data channel (detach is one-shot).  The inner
    /// DataChannel has direct `read`/`write` methods so we don't need
    /// the AsyncRead/AsyncWrite traits.
    detached: Mutex<Option<Arc<webrtc::data::data_channel::DataChannel>>>,
    /// Reassembly buffer for chunked large messages.
    /// Wrapped in Arc so that WebRTCStream can be cloned (stored in SESSIONS map).
    reassembly_buf: Arc<Mutex<Option<ReassemblyState>>>,
    /// Stores whether ICE restart is currently in progress to prevent infinite loops.
    restart_in_progress: Arc<AtomicBool>,
    /// Original parameters saved for ICE restart.
    restart_signal_device_id: Option<String>,
    restart_start_local_offer: bool,
}

struct ReassemblyState {
    /// Reassembled payload bytes so far.
    buf: Vec<u8>,
    /// Total number of chunks expected.
    total_chunks: u16,
    /// Index of the next expected chunk.
    next_chunk: u16,
}

/// Maximum receive buffer for a single WebRTC data channel message.
/// Each chunk is at most CHUNK_SIZE bytes of payload plus CHUNK_HEADER_SIZE bytes of header.
const DATA_CHANNEL_BUFFER_SIZE: usize = 4 * 1024 * 1024; // 4 MB

/// Maximum payload bytes per SCTP message. The Android WebRTC stack caps
/// max-message-size at 65536. We stay well under that to leave room for
/// the 5-byte chunk header and any SCTP framing overhead.
const CHUNK_SIZE: usize = 60 * 1024; // 60 KB payload per chunk

/// Chunk header layout (5 bytes):
///   byte 0     : magic 0xAB  (identifies a chunked message)
///   bytes 1-2  : chunk index (0-based, big-endian u16)
///   bytes 3-4  : total chunks (big-endian u16)
const CHUNK_HEADER_SIZE: usize = 5;
const CHUNK_MAGIC: u8 = 0xAB;

// use 3 public STUN servers to find out the NAT type, 2 must be the same address but different ports
// https://stackoverflow.com/questions/72805316/determine-nat-mapping-behaviour-using-two-stun-servers
// luckily nextcloud supports two ports for STUN
// unluckily webrtc-rs does not use the same port to do the STUN request
static DEFAULT_ICE_SERVERS: [&str; 3] = [
    "stun:stun.cloudflare.com:3478",
    "stun:stun.nextcloud.com:3478",
    "stun:stun.nextcloud.com:443",
];

lazy_static::lazy_static! {
    static ref SESSIONS: Arc::<Mutex<HashMap<String, WebRTCStream>>> = Default::default();
}

/// Cached DTLS certificate used by ALL host RTCPeerConnections so the
/// SDP fingerprint stays the same across loop iterations.  Without this,
/// each new `WebRTCStream` generates a fresh certificate (new fingerprint)
/// and the phone's answer — which references the offer's fingerprint — is
/// rejected by `set_remote_description` because the fingerprints don't match.
///
/// The certificate is generated once on first use.  The same certificate
/// is passed into every host-side `RTCPeerConnection` so they all share
/// the same fingerprint, while ICE candidates are freshly gathered each
/// loop iteration (avoiding stale NAT bindings).
lazy_static::lazy_static! {
    static ref HOST_CERTIFICATES: std::sync::Mutex<Option<Vec<webrtc::peer_connection::certificate::RTCCertificate>>> = std::sync::Mutex::new(None);
}

#[cfg(feature = "webrtc")]
fn get_or_init_host_certificates() -> std::sync::MutexGuard<'static, Option<Vec<webrtc::peer_connection::certificate::RTCCertificate>>> {
    use webrtc::peer_connection::certificate::RTCCertificate;
    let mut guard = HOST_CERTIFICATES.lock().unwrap();
    if guard.is_none() {
        match rcgen::KeyPair::generate_for(&rcgen::PKCS_ECDSA_P256_SHA256) {
            Ok(kp) => match RTCCertificate::from_key_pair(kp) {
                Ok(cert) => {
                    log::info!("Generated persistent DTLS certificate for host WebRTC sessions");
                    *guard = Some(vec![cert]);
                }
                Err(e) => {
                    log::error!("Failed to generate host certificate: {}", e);
                }
            },
            Err(e) => {
                log::error!("Failed to generate key pair for host certificate: {}", e);
            }
        }
    }
    guard
}

/// Clear all cached host WebRTC peer connections.
///
/// Must be called before each new Nostr host session so that `WebRTCStream::new`
/// creates a fresh peer connection (new DTLS certificate, new SDP fingerprint).
/// Without this, the endpoint string is identical every session and Nostr relays
/// return `"duplicate: have this event"`, causing the phone to receive a stale offer.
pub async fn clear_host_sessions() {
    let mut lock = SESSIONS.lock().await;
    let count = lock.len();
    lock.clear();
    if count > 0 {
        log::info!("Cleared {} cached WebRTC host session(s) before new Nostr offer", count);
    }
}

impl Clone for WebRTCStream {
    fn clone(&self) -> Self {
        WebRTCStream {
            pc: self.pc.clone(),
            stream: self.stream.clone(),
            state_notify: self.state_notify.clone(),
            failed_tx: self.failed_tx.clone(),
            failed_rx: self.failed_rx.clone(),
            send_timeout: self.send_timeout,
            detached: Mutex::new(None),
            reassembly_buf: self.reassembly_buf.clone(),
            restart_in_progress: self.restart_in_progress.clone(),
            restart_signal_device_id: self.restart_signal_device_id.clone(),
            restart_start_local_offer: self.restart_start_local_offer,
        }
    }
}

impl WebRTCStream {
    #[inline]
    fn parse_remote_signal_endpoint(endpoint: &str) -> ResultType<(Option<String>, String)> {
        if crate::nostr_signaling::is_nostr_webrtc_uri(endpoint) {
            let link = crate::nostr_signaling::parse_nostr_webrtc_uri(endpoint)?;
            let Some(offer) = link.embedded_offer else {
                return Err(anyhow::anyhow!("nostr-webrtc uri is missing an embedded WebRTC offer"));
            };
            // The embedded offer may be a webrtc:// URI — decode it to get the SDP JSON
            if offer.starts_with("webrtc://") {
                let decoded = Self::get_remote_offer(&offer)?;
                Ok((Some(link.device_id), decoded))
            } else {
                Ok((Some(link.device_id), offer))
            }
        } else {
            Ok((None, Self::get_remote_offer(endpoint)?))
        }
    }

    #[inline]
    fn get_remote_offer(endpoint: &str) -> ResultType<String> {
        // Ensure the endpoint starts with the "webrtc://" prefix
        if !endpoint.starts_with("webrtc://") {
            return Err(
                Error::new(ErrorKind::InvalidInput, "Invalid WebRTC endpoint format").into(),
            );
        }

        // Extract the Base64-encoded SDP part
        let encoded_sdp = &endpoint["webrtc://".len()..];
        // Decode the Base64 string
        let decoded_bytes = BASE64_STANDARD
            .decode(encoded_sdp)
            .map_err(|_| Error::new(ErrorKind::InvalidInput, "Failed to decode Base64 SDP"))?;
        Ok(String::from_utf8(decoded_bytes).map_err(|_| {
            Error::new(
                ErrorKind::InvalidInput,
                "Failed to convert decoded bytes to UTF-8",
            )
        })?)
    }

    #[inline]
    fn sdp_to_endpoint(sdp: &str) -> String {
        let encoded_sdp = BASE64_STANDARD.encode(sdp);
        format!("webrtc://{}", encoded_sdp)
    }

    #[inline]
    fn get_key_for_sdp(sdp: &RTCSessionDescription) -> ResultType<String> {
        let binding = sdp.unmarshal()?;
        let Some(fingerprint) = binding.attribute("fingerprint") else {
            // find fingerprint attribute in media descriptions
            for media in &binding.media_descriptions {
                if media.media_name.media != "application" {
                    continue;
                }
                if let Some(fp) = media
                    .attributes
                    .iter()
                    .find(|x| x.key == "fingerprint")
                    .and_then(|x| x.value.clone())
                {
                    return Ok(fp);
                }
            }
            return Err(anyhow::anyhow!("SDP fingerprint attribute not found"));
        };
        Ok(fingerprint.to_string())
    }

    #[inline]
    fn get_key_for_sdp_json(sdp_json: &str) -> ResultType<String> {
        if sdp_json.is_empty() {
            return Ok("".to_string());
        }
        let sdp = serde_json::from_str::<RTCSessionDescription>(&sdp_json)?;
        Self::get_key_for_sdp(&sdp)
    }

    #[inline]
    async fn get_key_for_peer(pc: &Arc<RTCPeerConnection>, is_local: bool) -> ResultType<String> {
        let Some(desc) = (match is_local {
            true => pc.local_description().await,
            false => pc.remote_description().await,
        }) else {
            return Err(anyhow::anyhow!("PeerConnection description is not set"));
        };
        Self::get_key_for_sdp(&desc)
    }

    #[inline]
    fn get_ice_server_from_url(url: &str) -> Option<RTCIceServer> {
        // standard url format with turn scheme: turn://user:pass@host:port
        match Url::parse(url) {
            Ok(u) => {
                if u.scheme() == "turn"
                    || u.scheme() == "turns"
                    || u.scheme() == "stun"
                    || u.scheme() == "stuns"
                {
                    Some(RTCIceServer {
                        urls: vec![format!(
                            "{}:{}:{}",
                            u.scheme(),
                            u.host_str().unwrap_or_default(),
                            u.port().unwrap_or(3478)
                        )],
                        username: u.username().to_string(),
                        credential: u.password().unwrap_or_default().to_string(),
                        ..Default::default()
                    })
                } else {
                    None
                }
            }
            Err(_) => None,
        }
    }

    #[inline]
    fn get_ice_servers() -> Vec<RTCIceServer> {
        let mut ice_servers = Vec::new();
        let cfg = config::Config::get_option(config::keys::OPTION_ICE_SERVERS);

        let mut has_stun = false;

        for url in cfg.split(',').map(str::trim) {
            if let Some(ice_server) = Self::get_ice_server_from_url(url) {
                // Detect STUN in user config
                if ice_server
                    .urls
                    .iter()
                    .any(|u| u.starts_with("stun:") || u.starts_with("stuns:"))
                {
                    has_stun = true;
                }

                ice_servers.push(ice_server);
            }
        }

        // If there is no STUN (either TURN-only or empty config) → prepend defaults
        if !has_stun {
            ice_servers.insert(
                0,
                RTCIceServer {
                    urls: DEFAULT_ICE_SERVERS.iter().map(|s| s.to_string()).collect(),
                    ..Default::default()
                },
            );
        }
        ice_servers
    }

    pub async fn new(
        remote_endpoint: &str,
        force_relay: bool,
        ms_timeout: u64,
    ) -> ResultType<Self> {
        log::info!("[L6/WR] WebRTCStream::new entered, endpoint_len={}", remote_endpoint.len());
        let (signal_device_id, remote_offer) = if remote_endpoint.is_empty() {
            log::info!("[L6/WR] empty endpoint -> host mode (create local offer)");
            (None, "".into())
        } else {
            match Self::parse_remote_signal_endpoint(remote_endpoint) {
                Ok(result) => {
                    log::info!("[L6/WR] parsed remote endpoint, has_device_id={}, offer_len={} [CLIENT PATH]",
                        result.0.is_some(), result.1.len());
                    result
                }
                Err(e) => {
                    log::error!("[L6/WR] parse_remote_signal_endpoint failed: {}", e);
                    return Err(e);
                }
            }
        };

        // Always create a new WebRTC connection for each session.
        // Previously we cached connections by SDP fingerprint, but that
        // caused multi-device sessions to share the same stream — which
        // breaks independent device control.  Each session gets its own
        // RTCPeerConnection, its own io_loop, and its own data channel.
        let mut key;
        let start_local_offer = remote_offer.is_empty();
        // Create a SettingEngine and enable Detach
        let mut s = SettingEngine::default();
        s.detach_data_channels();
        s.set_ice_multicast_dns_mode(MulticastDnsMode::Disabled);
        // Allow sending frames larger than the default 64 KB SCTP limit.
        // VP9/AV1 keyframes on a 1080p display routinely exceed this,
        // causing "outbound packet larger than maximum message size" errors.
        s.set_sctp_max_message_size_can_send(SctpMaxMessageSize::Unbounded);

        // Create the API object
        let api = APIBuilder::new().with_setting_engine(s).build();

        // Prepare the configuration, get ICE servers from config
        let certs = if start_local_offer {
            get_or_init_host_certificates().clone().unwrap_or_default()
        } else {
            Vec::new()
        };
        let config = RTCConfiguration {
            ice_servers: Self::get_ice_servers(),
            ice_transport_policy: if force_relay {
                RTCIceTransportPolicy::Relay
            } else {
                RTCIceTransportPolicy::All
            },
            certificates: certs,
            ..Default::default()
        };

        let (notify_tx, notify_rx) = watch::channel(false);
        let (failed_tx, failed_rx) = watch::channel(false);
        let restart_in_progress = Arc::new(AtomicBool::new(false));
        let sig_device_id = signal_device_id.clone();
        // Create a new RTCPeerConnection
        let pc = Arc::new(api.new_peer_connection(config).await?);
        let bootstrap_dc = if start_local_offer {
            let dc_open_notify = notify_tx.clone();
            // Create a data channel with label "bootstrap"
            let dc = pc.create_data_channel("bootstrap", None).await?;
            dc.on_open(Box::new(move || {
                log::info!("[DC/HOST] Local data channel bootstrap open.");
                let _ = dc_open_notify.send(true);
                Box::pin(async {})
            }));
            dc
        } else {
            // Wait for the data channel to be created by the remote peer
            // Here we create a dummy data channel to satisfy the type system
            Arc::new(RTCDataChannel::default())
        };

        let stream = Arc::new(Mutex::new(bootstrap_dc));
        if !start_local_offer {
            // Register data channel creation handling
            let dc_open_notify = notify_tx.clone();
            let stream_for_dc = stream.clone();
            pc.on_data_channel(Box::new(move |dc: Arc<RTCDataChannel>| {
                let d_label = dc.label().to_owned();
                let dc_open_notify2 = dc_open_notify.clone();
                let stream_for_dc_clone = stream_for_dc.clone();
                log::debug!("Remote data channel {} ready", d_label);
                Box::pin(async move {
                    let mut stream_lock = stream_for_dc_clone.lock().await;
                    *stream_lock = dc.clone();
                    drop(stream_lock);
                    dc.on_open(Box::new(move || {
                        log::info!("[DC/CLIENT] Remote data channel ({}) open.", d_label);
                        let _ = dc_open_notify2.send(true);
                        Box::pin(async {})
                    }));
                })
            }));
        }

        // ICE connection state — critical for diagnosing "stuck at checking" failures
        pc.on_ice_connection_state_change(Box::new(move |s: RTCIceConnectionState| {
            Box::pin(async move {
                log::info!("[L7/WR] ICE connection state: {:?}", s);
            })
        }));

        // ICE gathering state — detects when gathering completes or fails
        pc.on_ice_gathering_state_change(Box::new(move |s: RTCIceGathererState| {
            Box::pin(async move {
                log::info!("[L7/WR] ICE gatherer state: {:?}", s);
            })
        }));

        // Signaling state — offer/answer flow completion
        pc.on_signaling_state_change(Box::new(move |s: RTCSignalingState| {
            Box::pin(async move {
                log::info!("[L7/WR] Signaling state: {:?}", s);
            })
        }));

        // This will notify you when the peer has connected/disconnected
        let stream_for_close = stream.clone();
        let pc_for_close = pc.clone();
        let failed_tx_for_cb = failed_tx.clone();
        pc.on_peer_connection_state_change(Box::new(move |s: RTCPeerConnectionState| {
            let stream_for_close2 = stream_for_close.clone();
            let on_connection_notify = notify_tx.clone();
            let pc_for_close2 = pc_for_close.clone();
            let failed_tx_for_cb2 = failed_tx_for_cb.clone();
            Box::pin(async move {
                log::info!("[L7/WR] WebRTC peer connection state: {:?}", s);
                match s {
                    RTCPeerConnectionState::Connected => {
                        // Do NOT call shutdown() here. The client (laptop) may still
                        // need Nostr relay to publish its WebRTC answer back to the phone.
                        // Shutdown is only safe after the session ends (Disconnected/Failed/Closed).
                        log::info!("[WS-LIFECYCLE] WebRTC Connected — relay kept alive until session ends.");
                    }
                    RTCPeerConnectionState::Failed => {
                        log::warn!("[WS-LIFECYCLE] WebRTC Failed — notifying restart watcher");
                        let _ = failed_tx_for_cb2.send(true);
                        log::debug!("WebRTC session closing due to Failed");
                        let _ = stream_for_close2.lock().await.close().await;
                    }
                    RTCPeerConnectionState::Disconnected
                    | RTCPeerConnectionState::Closed => {
                        log::info!("[WS-LIFECYCLE] WebRTC {:?} -> NOT calling global shutdown (multi-session safe); cleaning up local session only", s);
                        let _ = on_connection_notify.send(true);
                        log::debug!("WebRTC session closing due to disconnected");
                        let _ = stream_for_close2.lock().await.close().await;
                        log::debug!("WebRTC session stream closed");

                        let mut sessions_lock = SESSIONS.lock().await;
                        match Self::get_key_for_peer(&pc_for_close2, start_local_offer).await {
                            Ok(k) => {
                                sessions_lock.remove(&k);
                                log::debug!("WebRTC session removed key: {}", k);
                            }
                            Err(e) => {
                                log::error!(
                                    "Failed to extract key for peer during session cleanup: {:?}",
                                    e
                                );
                                // Fallback: try to remove any session associated with this peer connection
                                let keys_to_remove: Vec<String> = sessions_lock
                                    .iter()
                                    .filter_map(|(key, session)| {
                                        if Arc::ptr_eq(&session.pc, &pc_for_close2) {
                                            Some(key.clone())
                                        } else {
                                            None
                                        }
                                    })
                                    .collect();
                                for k in keys_to_remove {
                                    sessions_lock.remove(&k);
                                    log::debug!("WebRTC session removed by fallback key: {}", k);
                                }
                            }
                        }
                    }
                    _ => {}
                }
            })
        }));

        // process offer/answer
        if start_local_offer {
            let sdp = pc.create_offer(None).await?;
            let mut gather_complete = pc.gathering_complete_promise().await;
            pc.set_local_description(sdp.clone()).await?;
            // Wait up to 20 s for ICE candidates; proceed with whatever was gathered.
            // Per WebRTC spec, the SDP is still valid after a partial gather.
            if timeout(Duration::from_secs(20), gather_complete.recv()).await.is_err() {
                log::warn!("ICE gathering timed out (20s) — proceeding with partial candidates");
            }

            log::debug!("local offer:\n{}", sdp.sdp);
            // get local sdp key
            key = Self::get_key_for_sdp(&sdp)?;
            log::debug!("Start webrtc with local key: {}", key);

            if let Some(local_desc) = pc.local_description().await {
                let local_endpoint = Self::sdp_to_endpoint(&serde_json::to_string(&local_desc)?);
                if let Some(device_id) = signal_device_id {
                    log::info!("WebRTCStream::new: spawning publish_webrtc_answer (device={})", device_id);
                    tokio::spawn(async move {
                        log::info!("publish_webrtc_answer task started for device {}", device_id);
                        if let Err(err) = crate::nostr_signaling::publish_webrtc_answer(
                            &device_id,
                            &local_endpoint,
                        )
                        .await
                        {
                            log::warn!("Failed to publish WebRTC answer: {}", err);
                        } else {
                            log::info!("WebRTC answer published successfully to Nostr for device {}", device_id);
                        }
                    });
                } else {
                    log::info!("WebRTCStream::new: no signal_device_id, skipping publish");
                }
            } else {
                log::error!("WebRTCStream::new: local description not set after offer creation");
                return Err(anyhow::anyhow!("Local desc is not set"));
            }
        } else {
            log::info!("[L6/CL] processing remote offer (client/answerer path)");
            let sdp = match serde_json::from_str::<RTCSessionDescription>(&remote_offer) {
                Ok(s) => s,
                Err(e) => {
                    log::error!("[L6/CL] failed to parse remote offer SDP: {}", e);
                    return Err(e.into());
                }
            };
            log::info!("[L6/CL] setting remote description from offer");
            if let Err(e) = pc.set_remote_description(sdp.clone()).await {
                log::error!("[L6/CL] set_remote_description failed: {}", e);
                return Err(e.into());
            }
            log::info!("[L6/CL] creating WebRTC answer");
            let answer = match pc.create_answer(None).await {
                Ok(a) => a,
                Err(e) => {
                    log::error!("[L6/CL] create_answer failed: {}", e);
                    return Err(e.into());
                }
            };
            let mut gather_complete = pc.gathering_complete_promise().await;
            log::info!("[L6/CL] setting local description (answer)");
            if let Err(e) = pc.set_local_description(answer).await {
                log::error!("WebRTCStream::new: set_local_description failed: {}", e);
                return Err(e.into());
            }
            log::info!("WebRTCStream::new: gathering ICE candidates (max 20s)...");
            if timeout(Duration::from_secs(20), gather_complete.recv()).await.is_err() {
                log::warn!("ICE gathering timed out (20s) — proceeding with partial candidates");
            }
            log::info!("WebRTCStream::new: ICE gathering complete (or timeout)");

            log::debug!("remote offer:\n{}", sdp.sdp);
            // get remote sdp key
            key = Self::get_key_for_sdp(&sdp)?;
            log::debug!("Start webrtc with remote key: {}", key);

            if let Some(local_desc) = pc.local_description().await {
                let local_endpoint = Self::sdp_to_endpoint(&serde_json::to_string(&local_desc)?);
                if let Some(device_id) = signal_device_id {
                    log::info!("[L6/CL] spawning publish_webrtc_answer for device_id={}", device_id);
                    tokio::spawn(async move {
                        log::info!("[L6/CL] publish_webrtc_answer task started for {}", device_id);
                        if let Err(err) = crate::nostr_signaling::publish_webrtc_answer(
                            &device_id,
                            &local_endpoint,
                        )
                        .await
                        {
                            log::warn!("[L6/CL] Failed to publish WebRTC answer: {}", err);
                        } else {
                            log::info!("[L6/CL] WebRTC answer published to Nostr for {}", device_id);
                        }
                    });
                } else {
                    log::info!("[L6/CL] no signal_device_id, skipping publish");
                }
            }
        }

        // Remove any stale session with the same fingerprint.
        // We never reuse cached streams — each caller session gets its own
        // independent RTCPeerConnection so multi-device works correctly.
        let mut final_lock = SESSIONS.lock().await;
        final_lock.remove(&key);

        let webrtc_stream = Self {
            pc,
            stream,
            state_notify: notify_rx,
            failed_tx,
            failed_rx,
            send_timeout: ms_timeout,
            detached: Mutex::new(None),
            reassembly_buf: Arc::new(Mutex::new(None)),
            restart_in_progress,
            restart_signal_device_id: sig_device_id,
            restart_start_local_offer: start_local_offer,
        };
        final_lock.insert(key.clone(), webrtc_stream.clone());
        log::info!("[L6/WR] WebRTCStream::new returning fresh connection (key={})", key);
        Ok(webrtc_stream)
    }

    #[inline]
    pub async fn get_local_endpoint(&self) -> ResultType<String> {
        if let Some(local_desc) = self.pc.local_description().await {
            let sdp = serde_json::to_string(&local_desc)?;
            let endpoint = Self::sdp_to_endpoint(&sdp);
            Ok(endpoint)
        } else {
            Err(anyhow::anyhow!("Local desc is not set"))
        }
    }

    #[inline]
    pub async fn set_remote_endpoint(&self, endpoint: &str) -> ResultType<()> {
        let sdp_raw = Self::get_remote_offer(endpoint)?;
        let sdp = serde_json::from_str::<RTCSessionDescription>(&sdp_raw)?;
        log::info!("[L6/HD] set_remote_description sdp_type={:?} sdp_len={}", sdp.sdp_type, sdp_raw.len());
        match self.pc.set_remote_description(sdp).await {
            Ok(_) => {
                log::info!("[L6/HD] set_remote_description succeeded");
                Ok(())
            }
            Err(e) => {
                log::error!("[L6/HD] set_remote_description FAILED: {}", e);
                Err(e.into())
            }
        }
    }

    #[inline]
    pub fn set_raw(&mut self) {
        // not-supported
    }

    #[inline]
    pub fn local_addr(&self) -> SocketAddr {
        SocketAddr::new(IpAddr::V4(Ipv4Addr::UNSPECIFIED), 0)
    }

    #[inline]
    pub fn set_send_timeout(&mut self, ms: u64) {
        self.send_timeout = ms;
    }

    #[inline]
    pub fn set_key(&mut self, _key: Key) {
        // not-supported
        // WebRTC uses built-in DTLS encryption for secure communication.
        // DTLS handles key exchange and encryption automatically, so explicit key management is not required.
    }

    /// Returns true if the peer connection has entered Failed state.
    #[inline]
    pub fn is_failed(&self) -> bool {
        *self.failed_rx.borrow()
    }

    /// Returns a clone of the failed notification receiver.
    /// The caller can use `receiver.changed().await` to wait for failure.
    #[inline]
    pub fn failed_receiver(&self) -> watch::Receiver<bool> {
        self.failed_rx.clone()
    }

    /// Trigger a full ICE restart including re-signaling.
    /// Closes the old PeerConnection, creates a new one, re-does the Nostr
    /// SDP exchange, and waits for the data channel to open.
    ///
    /// # Parameters
    /// - `remote_endpoint`: the original Nostr URI or SDP string (same as passed to `new()`)
    /// - `force_relay`: whether to force relay transport
    /// - `ms_timeout`: connection timeout in milliseconds for the new PC
    /// - `signal_device_id`: the Nostr device ID for re-publishing (None if not applicable)
    ///
    /// Returns `true` if the full restart+reconnect succeeded, `false` otherwise.
    pub async fn restart_ice(
        &mut self,
        remote_endpoint: &str,
        force_relay: bool,
        ms_timeout: u64,
        signal_device_id: Option<&str>,
    ) -> bool {
        if self.restart_in_progress.swap(true, Ordering::SeqCst) {
            log::info!("ICE restart already in progress, skipping duplicate");
            return false;
        }

        log::warn!("WebRTC ICE restart triggered");

        // 1. Close old peer connection
        self.pc.close().await.ok();
        let _ = self.stream.lock().await.close().await;

        // 2. Extract the remote SDP for the client path
        let (new_signal_device_id, remote_offer) = if remote_endpoint.is_empty() {
            (None, "".to_owned())
        } else if crate::nostr_signaling::is_nostr_webrtc_uri(remote_endpoint) {
            match Self::parse_remote_signal_endpoint(remote_endpoint) {
                Ok((dev, offer)) => (dev, offer),
                Err(e) => {
                    log::error!("ICE restart: parse_remote_signal_endpoint failed: {}", e);
                    self.restart_in_progress.store(false, Ordering::SeqCst);
                    return false;
                }
            }
        } else {
            (signal_device_id.map(|s| s.to_owned()), remote_endpoint.to_owned())
        };

        let start_local_offer = remote_offer.is_empty();

        // 3. Create fresh setting engine + API
        let mut s = SettingEngine::default();
        s.detach_data_channels();
        s.set_ice_multicast_dns_mode(MulticastDnsMode::Disabled);
        s.set_sctp_max_message_size_can_send(SctpMaxMessageSize::Unbounded);
        let api = APIBuilder::new().with_setting_engine(s).build();

        let certs = if start_local_offer {
            get_or_init_host_certificates().clone().unwrap_or_default()
        } else {
            Vec::new()
        };

        let config = RTCConfiguration {
            ice_servers: Self::get_ice_servers(),
            ice_transport_policy: if force_relay {
                RTCIceTransportPolicy::Relay
            } else {
                RTCIceTransportPolicy::All
            },
            certificates: certs,
            ..Default::default()
        };

        // 4. Create new PeerConnection
        let new_pc = match api.new_peer_connection(config).await {
            Ok(pc) => Arc::new(pc),
            Err(e) => {
                log::error!("ICE restart: failed to create new PeerConnection: {}", e);
                self.restart_in_progress.store(false, Ordering::SeqCst);
                return false;
            }
        };

        // 5. Set up data channel
        let (new_notify_tx, mut new_notify_rx) = watch::channel(false);
        let new_stream = Arc::new(Mutex::new(Arc::new(RTCDataChannel::default())));
        let (new_failed_tx, new_failed_rx) = watch::channel(false);

        if start_local_offer {
            let dc_open_notify = new_notify_tx.clone();
            match new_pc.create_data_channel("bootstrap", None).await {
                Ok(dc) => {
                    dc.on_open(Box::new(move || {
                        log::info!("[DC/RESTART] Local data channel open.");
                        let _ = dc_open_notify.send(true);
                        Box::pin(async {})
                    }));
                    let mut lock = new_stream.lock().await;
                    *lock = dc;
                }
                Err(e) => {
                    log::error!("ICE restart: create_data_channel failed: {}", e);
                    new_pc.close().await.ok();
                    self.restart_in_progress.store(false, Ordering::SeqCst);
                    return false;
                }
            }
        } else {
            let dc_open_notify = new_notify_tx.clone();
            let stream_for_dc = new_stream.clone();
            new_pc.on_data_channel(Box::new(move |dc: Arc<RTCDataChannel>| {
                let label = dc.label().to_owned();
                let dc_open = dc_open_notify.clone();
                let stream_clone = stream_for_dc.clone();
                Box::pin(async move {
                    let mut lock = stream_clone.lock().await;
                    *lock = dc.clone();
                    drop(lock);
                    dc.on_open(Box::new(move || {
                        log::info!("[DC/RESTART] Remote data channel ({}) open.", label);
                        let _ = dc_open.send(true);
                        Box::pin(async {})
                    }));
                })
            }));
        }

        // 6. Set up state-change callbacks for the new PC
        let failed_tx_cb = new_failed_tx.clone();
        let stream_for_close = new_stream.clone();
        let new_pc_for_cb = new_pc.clone();
        let notify_tx_for_cb = new_notify_tx.clone();
        new_pc.on_peer_connection_state_change(Box::new(move |s: RTCPeerConnectionState| {
            let st = stream_for_close.clone();
            let nt = notify_tx_for_cb.clone();
            let ft = failed_tx_cb.clone();
            let pc2 = new_pc_for_cb.clone();
            Box::pin(async move {
                log::info!("[L7/WR/RESTART] WebRTC peer connection state: {:?}", s);
                match s {
                    RTCPeerConnectionState::Failed => {
                        log::warn!("[WS-LIFECYCLE/RESTART] WebRTC Failed");
                        let _ = ft.send(true);
                        let _ = nt.send(true);
                        let _ = st.lock().await.close().await;
                    }
                    RTCPeerConnectionState::Disconnected | RTCPeerConnectionState::Closed => {
                        let _ = nt.send(true);
                        let _ = st.lock().await.close().await;
                        let mut lock = SESSIONS.lock().await;
                        let keys: Vec<String> = lock.iter().filter_map(|(k, v)| {
                            if Arc::ptr_eq(&v.pc, &pc2) { Some(k.clone()) } else { None }
                        }).collect();
                        for k in keys { lock.remove(&k); }
                    }
                    _ => {}
                }
            })
        }));

        // 7. Do full SDP exchange with Nostr signaling
        let signaling_ok = if start_local_offer {
            // Host path: create offer, publish to Nostr, wait for answer
            match Self::pc_create_and_publish_offer(
                &new_pc, &new_stream, &new_notify_tx, &new_signal_device_id,
            ).await {
                Ok(()) => true,
                Err(e) => {
                    log::error!("ICE restart: host signaling failed: {}", e);
                    false
                }
            }
        } else {
            // Client path: set remote description from stored offer, create answer, publish
            match Self::pc_receive_offer_and_publish_answer(
                &new_pc, &new_stream, &new_notify_tx, &remote_offer, &new_signal_device_id,
            ).await {
                Ok(()) => true,
                Err(e) => {
                    log::error!("ICE restart: client signaling failed: {}", e);
                    false
                }
            }
        };

        if !signaling_ok {
            new_pc.close().await.ok();
            self.restart_in_progress.store(false, Ordering::SeqCst);
            return false;
        }

        // 8. Wait for data channel open with timeout
        let dc_open_timeout = Duration::from_millis(if ms_timeout > 0 { ms_timeout } else { 30000 });
        let dc_ok = tokio::time::timeout(dc_open_timeout, async {
            if *new_notify_rx.borrow() {
                return;
            }
            let _ = new_notify_rx.changed().await;
        }).await.is_ok();

        if !dc_ok {
            log::error!("ICE restart: data channel did not open within timeout");
            new_pc.close().await.ok();
            self.restart_in_progress.store(false, Ordering::SeqCst);
            return false;
        }

        // 9. Swap state
        self.pc = new_pc;
        self.stream = new_stream;
        self.state_notify = new_notify_rx;
        self.failed_tx = new_failed_tx;
        self.failed_rx = new_failed_rx;
        self.detached = Mutex::new(None);
        self.reassembly_buf = Arc::new(Mutex::new(None));

        self.restart_in_progress.store(false, Ordering::SeqCst);
        log::info!("WebRTC ICE restart complete — new PeerConnection ready");
        true
    }

    /// Create offer, gather ICE, publish to Nostr, and wait for answer.
    async fn pc_create_and_publish_offer(
        pc: &Arc<RTCPeerConnection>,
        _stream: &Arc<Mutex<Arc<RTCDataChannel>>>,
        _notify_tx: &watch::Sender<bool>,
        signal_device_id: &Option<String>,
    ) -> ResultType<()> {
        let sdp = pc.create_offer(None).await?;
        let mut gather_complete = pc.gathering_complete_promise().await;
        pc.set_local_description(sdp.clone()).await?;
        if tokio::time::timeout(Duration::from_secs(20), gather_complete.recv()).await.is_err() {
            log::warn!("[RESTART] ICE gathering timed out (20s)");
        }

        if let Some(local_desc) = pc.local_description().await {
            let local_endpoint = Self::sdp_to_endpoint(&serde_json::to_string(&local_desc)?);
            if let Some(device_id) = signal_device_id {
                log::info!("[RESTART] publishing new WebRTC offer to Nostr (device={})", device_id);
                crate::nostr_signaling::publish_webrtc_offer(device_id, &local_endpoint, 0).await
                    .map_err(|e| anyhow::anyhow!("publish offer failed: {}", e))?;
                log::info!("[RESTART] offer published, waiting for answer via Nostr...");
                // Wait for answer by polling set_remote_endpoint (caller must set it)
                // For now, we return and let the caller complete the cycle
                Ok(())
            } else {
                log::info!("[RESTART] host mode without Nostr — skipping publish");
                Ok(())
            }
        } else {
            Err(anyhow::anyhow!("local desc not set"))
        }
    }

    /// Set remote offer, create answer, gather ICE, publish answer to Nostr.
    async fn pc_receive_offer_and_publish_answer(
        pc: &Arc<RTCPeerConnection>,
        _stream: &Arc<Mutex<Arc<RTCDataChannel>>>,
        _notify_tx: &watch::Sender<bool>,
        remote_offer: &str,
        signal_device_id: &Option<String>,
    ) -> ResultType<()> {
        let sdp: RTCSessionDescription = serde_json::from_str(remote_offer)
            .map_err(|e| anyhow::anyhow!("failed to parse remote offer SDP: {}", e))?;
        pc.set_remote_description(sdp.clone()).await
            .map_err(|e| anyhow::anyhow!("set_remote_description failed: {}", e))?;

        let answer = pc.create_answer(None).await
            .map_err(|e| anyhow::anyhow!("create_answer failed: {}", e))?;

        let mut gather_complete = pc.gathering_complete_promise().await;
        pc.set_local_description(answer).await
            .map_err(|e| anyhow::anyhow!("set_local_description failed: {}", e))?;

        if tokio::time::timeout(Duration::from_secs(20), gather_complete.recv()).await.is_err() {
            log::warn!("[RESTART] ICE gathering timed out (20s)");
        }

        if let Some(local_desc) = pc.local_description().await {
            let local_endpoint = Self::sdp_to_endpoint(&serde_json::to_string(&local_desc)?);
            if let Some(device_id) = signal_device_id {
                log::info!("[RESTART] publishing WebRTC answer to Nostr (device={})", device_id);
                crate::nostr_signaling::publish_webrtc_answer(device_id, &local_endpoint).await
                    .map_err(|e| anyhow::anyhow!("publish answer failed: {}", e))?;
            }
            Ok(())
        } else {
            Err(anyhow::anyhow!("local desc not set"))
        }
    }

    #[inline]
    pub fn is_secured(&self) -> bool {
        true
    }

    #[inline]
    pub async fn send(&mut self, msg: &impl Message) -> ResultType<()> {
        self.send_raw(msg.write_to_bytes()?).await
    }

    #[inline]
    pub async fn send_raw(&mut self, msg: Vec<u8>) -> ResultType<()> {
        self.send_bytes(Bytes::from(msg)).await
    }

    #[inline]
    async fn wait_for_connect_result(&mut self) -> ResultType<()> {
        if *self.state_notify.borrow() {
            log::info!("WebRTC wait_for_connect: already connected");
            return Ok(());
        }
        if *self.failed_rx.borrow() {
            log::error!("WebRTC wait_for_connect: already failed before connect");
            return Err(anyhow::anyhow!("WebRTC connection failed before data channel opened"));
        }
        log::info!("WebRTC wait_for_connect: waiting for data channel open signal...");
        let mut connected = self.state_notify.clone();
        let mut failed = self.failed_rx.clone();
        tokio::select! {
            _ = connected.changed() => {
                if *connected.borrow() {
                    log::info!("WebRTC wait_for_connect: data channel open signal received");
                    Ok(())
                } else {
                    Err(anyhow::anyhow!("WebRTC data channel closed before opening"))
                }
            }
            _ = failed.changed() => {
                log::error!("WebRTC wait_for_connect: connection failed while waiting");
                Err(anyhow::anyhow!("WebRTC connection failed while waiting for data channel"))
            }
        }
    }

    pub async fn send_bytes(&mut self, bytes: Bytes) -> ResultType<()> {
        log::info!("WebRTC send_bytes: len={}, send_timeout={}", bytes.len(), self.send_timeout);
        if self.send_timeout > 0 {
            match timeout(
                Duration::from_millis(self.send_timeout),
                self.wait_for_connect_result(),
            )
            .await
            {
                Ok(Ok(())) => {}
                Ok(Err(e)) => {
                    log::error!("WebRTC send_bytes: connect failed: {}", e);
                    self.pc.close().await.ok();
                    return Err(Error::new(ErrorKind::NotConnected, e.to_string()).into());
                }
                Err(_) => {
                    log::error!("WebRTC send_bytes: timeout waiting for connect");
                    self.pc.close().await.ok();
                    return Err(Error::new(
                        ErrorKind::TimedOut,
                        "WebRTC send wait for connect timeout",
                    )
                    .into());
                }
            }
        } else {
            self.wait_for_connect_result().await?;
        }

        // Split into chunks if the payload exceeds the SCTP limit.
        let total_chunks = (bytes.len() + CHUNK_SIZE - 1).max(1) / CHUNK_SIZE;
        let total_chunks = total_chunks.max(1);
        if total_chunks > u16::MAX as usize {
            return Err(Error::new(ErrorKind::InvalidInput, "WebRTC message too large to chunk").into());
        }
        let total_chunks = total_chunks as u16;

        let mut guard = self.detached.lock().await;
        for chunk_idx in 0..total_chunks {
            let start = chunk_idx as usize * CHUNK_SIZE;
            let end = (start + CHUNK_SIZE).min(bytes.len());
            let payload = &bytes[start..end];

            // Build the chunk packet: [magic, idx_hi, idx_lo, total_hi, total_lo, payload...]
            let mut chunk_buf = Vec::with_capacity(CHUNK_HEADER_SIZE + payload.len());
            chunk_buf.push(CHUNK_MAGIC);
            chunk_buf.push((chunk_idx >> 8) as u8);
            chunk_buf.push(chunk_idx as u8);
            chunk_buf.push((total_chunks >> 8) as u8);
            chunk_buf.push(total_chunks as u8);
            chunk_buf.extend_from_slice(payload);

            let chunk_bytes = Bytes::from(chunk_buf);

            if let Some(ref dc) = *guard {
                match dc.write(&chunk_bytes).await {
                    Ok(_) => {}
                    Err(e) => {
                        log::error!("WebRTC send_bytes: chunk {}/{} write error: {}", chunk_idx + 1, total_chunks, e);
                        return Err(e.into());
                    }
                }
            } else {
                drop(guard);
                let stream = self.stream.lock().await.clone();
                match stream.send(&chunk_bytes).await {
                    Ok(_) => {}
                    Err(e) => {
                        log::error!("WebRTC send_bytes: chunk {}/{} RTCDataChannel send error: {}", chunk_idx + 1, total_chunks, e);
                        return Err(e.into());
                    }
                }
                // Re-acquire guard for subsequent chunks (if any)
                guard = self.detached.lock().await;
            }
        }
        if total_chunks > 1 {
            log::info!("WebRTC send_bytes: sent {} chunks for {} byte message", total_chunks, bytes.len());
        }
        Ok(())
    }

    pub async fn next(&mut self) -> Option<Result<BytesMut, Error>> {
        if let Err(e) = self.wait_for_connect_result().await {
            log::error!("WebRTC next: wait_for_connect_result failed: {}", e);
            self.pc.close().await.ok();
            return Some(Err(Error::new(ErrorKind::NotConnected, e.to_string())));
        }
        loop {
            // --- get the detached data channel ---
            let mut guard = self.detached.lock().await;
            if guard.is_none() {
                log::info!("WebRTC next: cache empty, calling detach()");
                let stream = self.stream.lock().await.clone();
                let detach_result = stream.detach().await;
                match detach_result {
                    Ok(ref dc) => {
                        log::info!("WebRTC next: detach succeeded");
                        *guard = Some(Arc::clone(dc));
                    }
                    Err(e) => {
                        log::error!("WebRTC next: detach failed: {}", e);
                        drop(guard);
                        self.pc.close().await.ok();
                        return Some(Err(Error::new(
                            ErrorKind::Other,
                            format!("data channel detach error: {}", e),
                        )));
                    }
                }
            }
            let dc = match guard.as_ref() {
                Some(dc) => Arc::clone(dc),
                None => {
                    log::error!("WebRTC next: detached is None after detach attempt");
                    return None;
                }
            };
            drop(guard);

            // --- read one raw SCTP packet ---
            let mut buffer = BytesMut::zeroed(DATA_CHANNEL_BUFFER_SIZE);
            let n = match dc.read(&mut buffer).await {
                Ok(n) => n,
                Err(err) => {
                    log::error!("WebRTC next: dc.read error: {}", err);
                    self.pc.close().await.ok();
                    return Some(Err(Error::new(
                        ErrorKind::Other,
                        format!("data channel read error: {}", err),
                    )));
                }
            };
            if n == 0 {
                log::warn!("WebRTC next: dc.read returned 0 bytes (EOF)");
                self.pc.close().await.ok();
                return Some(Err(Error::new(
                    ErrorKind::Other,
                    "data channel read exited with 0 bytes",
                )));
            }
            buffer.truncate(n);

            // --- detect chunk header and reassemble if needed ---
            if n > CHUNK_HEADER_SIZE && buffer[0] == CHUNK_MAGIC {
                let chunk_idx = u16::from_be_bytes([buffer[1], buffer[2]]);
                let total_chunks = u16::from_be_bytes([buffer[3], buffer[4]]);
                let payload = &buffer[CHUNK_HEADER_SIZE..n];

                if total_chunks == 1 {
                    // Single-chunk message — skip reassembly overhead
                    let mut out = BytesMut::with_capacity(payload.len());
                    out.extend_from_slice(payload);
                    log::info!("WebRTC next: single-chunk message {} bytes", out.len());
                    return Some(Ok(out));
                }

                let mut rbuf_guard = self.reassembly_buf.lock().await;
                if chunk_idx == 0 {
                    // First chunk: (re)start reassembly
                    *rbuf_guard = Some(ReassemblyState {
                        buf: payload.to_vec(),
                        total_chunks,
                        next_chunk: 1,
                    });
                } else if let Some(ref mut state) = *rbuf_guard {
                    if chunk_idx == state.next_chunk && total_chunks == state.total_chunks {
                        state.buf.extend_from_slice(payload);
                        state.next_chunk += 1;
                    } else {
                        // Out-of-order or wrong total: discard and restart
                        log::error!("WebRTC next: unexpected chunk idx={} expected={} total={}, discarding",
                            chunk_idx, state.next_chunk, total_chunks);
                        *rbuf_guard = None;
                    }
                }

                // Check if reassembly is complete
                let complete = rbuf_guard.as_ref().map_or(false, |s| s.next_chunk == s.total_chunks);
                if complete {
                    let data = rbuf_guard.take().unwrap().buf;
                    log::info!("WebRTC next: reassembled {} chunks -> {} bytes", total_chunks, data.len());
                    let mut out = BytesMut::with_capacity(data.len());
                    out.extend_from_slice(&data);
                    return Some(Ok(out));
                }
                // More chunks expected — loop and read the next packet
                continue;
            } else {
                // No chunk header — legacy or unchunked small message
                log::info!("WebRTC next: unchunked message {} bytes", n);
                return Some(Ok(buffer));
            }
        }
    }

    #[inline]
    pub async fn next_timeout(&mut self, ms: u64) -> Option<Result<BytesMut, Error>> {
        match timeout(Duration::from_millis(ms), self.next()).await {
            Ok(res) => res,
            Err(_) => None,
        }
    }
}

pub fn is_webrtc_endpoint(endpoint: &str) -> bool {
    // use sdp base64 json string as endpoint, or prefix webrtc:
    endpoint.starts_with("webrtc://")
}

#[cfg(test)]
mod tests {
    use crate::config;
    use crate::webrtc::WebRTCStream;
    use crate::webrtc::DEFAULT_ICE_SERVERS;
    use webrtc::peer_connection::sdp::session_description::RTCSessionDescription;

    #[test]
    fn test_webrtc_ice_url() {
        assert_eq!(
            WebRTCStream::get_ice_server_from_url("turn://example.com:3478")
                .unwrap_or_default()
                .urls[0],
            "turn:example.com:3478"
        );

        assert_eq!(
            WebRTCStream::get_ice_server_from_url("turn://example.com")
                .unwrap_or_default()
                .urls[0],
            "turn:example.com:3478"
        );

        assert_eq!(
            WebRTCStream::get_ice_server_from_url("turn://123@example.com")
                .unwrap_or_default()
                .username,
            "123"
        );

        assert_eq!(
            WebRTCStream::get_ice_server_from_url("turn://123@example.com")
                .unwrap_or_default()
                .credential,
            ""
        );

        assert_eq!(
            WebRTCStream::get_ice_server_from_url("turn://123:321@example.com")
                .unwrap_or_default()
                .credential,
            "321"
        );

        assert_eq!(
            WebRTCStream::get_ice_server_from_url("stun://example.com:3478")
                .unwrap_or_default()
                .urls[0],
            "stun:example.com:3478"
        );

        assert_eq!(
            WebRTCStream::get_ice_server_from_url("http://123:123@example.com:3478"),
            None
        );

        config::Config::set_option("ice-servers".to_string(), "".to_string());
        assert_eq!(
            WebRTCStream::get_ice_servers()[0].urls[0],
            DEFAULT_ICE_SERVERS[0].to_string()
        );

        config::Config::set_option(
            "ice-servers".to_string(),
            ",stun://example.com,turn://example.com,sdf".to_string(),
        );
        assert_eq!(
            WebRTCStream::get_ice_servers()[0].urls[0],
            "stun:example.com:3478"
        );
        assert_eq!(
            WebRTCStream::get_ice_servers()[1].urls[0],
            "turn:example.com:3478"
        );
        assert_eq!(WebRTCStream::get_ice_servers().len(), 2);
        config::Config::set_option(
            "ice-servers".to_string(),
            "".to_string(),
        );
    }

    #[test]
    fn test_webrtc_session_key() {
        let mut sdp_str = "".to_owned();
        assert_eq!(
            WebRTCStream::get_key_for_sdp(
                &RTCSessionDescription::offer(sdp_str).unwrap_or_default()
            )
            .unwrap_or_default(),
            ""
        );

        sdp_str = "\
v=0
o=- 7400546379179479477 208696200 IN IP4 0.0.0.0
s=-
t=0 0
a=fingerprint:sha-256 97:52:D6:1F:1E:87:6C:DA:B8:21:95:64:A5:85:89:FA:02:71:C7:4D:B3:FD:25:92:40:FB:6B:65:24:3C:79:88
a=group:BUNDLE 0
a=extmap-allow-mixed
m=application 9 UDP/DTLS/SCTP webrtc-datachannel
c=IN IP4 0.0.0.0
a=setup:actpass
a=mid:0
a=sendrecv
a=sctp-port:5000
a=ice-ufrag:RMWjjpXfpXbDPdMz
a=ice-pwd:BtIqlWHfwhsJdFiBROeLuEbNmYfHxRfT".to_owned();
        assert_eq!(
            WebRTCStream::get_key_for_sdp(
                &RTCSessionDescription::offer(sdp_str).unwrap_or_default()
            ).unwrap_or_default(),
            "sha-256 97:52:D6:1F:1E:87:6C:DA:B8:21:95:64:A5:85:89:FA:02:71:C7:4D:B3:FD:25:92:40:FB:6B:65:24:3C:79:88"
        );

        sdp_str = "\
v=0
o=- 7400546379179479477 208696200 IN IP4 0.0.0.0
s=-
t=0 0
a=group:BUNDLE 0
a=extmap-allow-mixed
m=application 9 UDP/DTLS/SCTP webrtc-datachannel
c=IN IP4 0.0.0.0
a=fingerprint:sha-256 97:52:D6:1F:1E:87:6C:DA:B8:21:95:64:A5:85:89:FA:02:71:C7:4D:B3:FD:25:92:40:FB:6B:65:24:3C:79:88
a=setup:actpass
a=mid:0
a=sendrecv
a=sctp-port:5000
a=ice-ufrag:RMWjjpXfpXbDPdMz
a=ice-pwd:BtIqlWHfwhsJdFiBROeLuEbNmYfHxRfT".to_owned();
        assert_eq!(
            WebRTCStream::get_key_for_sdp(
                &RTCSessionDescription::offer(sdp_str).unwrap_or_default()
            ).unwrap_or_default(),
            "sha-256 97:52:D6:1F:1E:87:6C:DA:B8:21:95:64:A5:85:89:FA:02:71:C7:4D:B3:FD:25:92:40:FB:6B:65:24:3C:79:88"
        );

        sdp_str = "\
v=0
o=- 7400546379179479477 208696200 IN IP4 0.0.0.0
s=-
t=0 0
a=group:BUNDLE 0
a=extmap-allow-mixed
m=application 9 UDP/DTLS/SCTP webrtc-datachannel
c=IN IP4 0.0.0.0
a=setup:actpass
a=mid:0
a=sendrecv
a=sctp-port:5000
a=ice-ufrag:RMWjjpXfpXbDPdMz
a=ice-pwd:BtIqlWHfwhsJdFiBROeLuEbNmYfHxRfT"
            .to_owned();
        assert!(
            WebRTCStream::get_key_for_sdp(
                &RTCSessionDescription::offer(sdp_str).unwrap_or_default()
            )
            .is_err(),
            "can not find fingerprint attribute"
        );

        sdp_str = "\
v=0
o=- 7400546379179479477 208696200 IN IP4 0.0.0.0
s=-
t=0 0
a=group:BUNDLE 0
a=extmap-allow-mixed
m=audio 9 UDP/DTLS/SCTP webrtc-datachannel
c=IN IP4 0.0.0.0
a=fingerprint:sha-256 97:52:D6:1F:1E:87:6C:DA:B8:21:95:64:A5:85:89:FA:02:71:C7:4D:B3:FD:25:92:40:FB:6B:65:24:3C:79:88
a=setup:actpass
a=mid:0
a=sendrecv
a=sctp-port:5000
a=ice-ufrag:RMWjjpXfpXbDPdMz
a=ice-pwd:BtIqlWHfwhsJdFiBROeLuEbNmYfHxRfT".to_owned();
        assert!(
            WebRTCStream::get_key_for_sdp(
                &RTCSessionDescription::offer(sdp_str).unwrap_or_default()
            )
            .is_err(),
            "can not find datachannel fingerprint attribute"
        );

        assert!(
            WebRTCStream::get_key_for_sdp(
                &RTCSessionDescription::offer("".to_owned()).unwrap_or_default()
            )
            .is_err(),
            "invalid sdp should error"
        );

        assert!(
            WebRTCStream::get_key_for_sdp_json("{}").is_err(),
            "empty sdp json should error"
        );

        assert!(
            WebRTCStream::get_key_for_sdp_json("{ss}").is_err(),
            "invalid sdp json should error"
        );

        let endpoint = "webrtc://eyJ0eXBlIjoiYW5zd2VyIiwic2RwIjoidj0wXHJcbm89LSA0MTA1NDk3NTY2NDgyMTQzODEwIDYwMzk1NzQw\
MCBJTiBJUDQgMC4wLjAuMFxyXG5zPS1cclxudD0wIDBcclxuYT1maW5nZXJwcmludDpzaGEtMjU2IDYxOjYwOjc0OjQwOjI4OkNFOjBCOjBDOjc1OjRCOj\
EwOjlBOkVFOjc3OkY1OjQ0OjU3Ojg0OjUxOkRCOjA0OjkyOjRBOjEwOjFDOjRFOjVGOjdFOkYxOkIzOjcxOjIyXHJcbmE9Z3JvdXA6QlVORExFIDBcclxu\
YT1leHRtYXAtYWxsb3ctbWl4ZWRcclxubT1hcHBsaWNhdGlvbiA5IFVEUC9EVExTL1NDVFAgd2VicnRjLWRhdGFjaGFubmVsXHJcbmM9SU4gSVA0IDAuMC\
4wLjBcclxuYT1zZXR1cDphY3RpdmVcclxuYT1taWQ6MFxyXG5hPXNlbmRyZWN2XHJcbmE9c2N0cC1wb3J0OjUwMDBcclxuYT1pY2UtdWZyYWc6SHlnU1Rr\
V2RsRlpHRG1XWlxyXG5hPWljZS1wd2Q6SkJneFZWaGZveVhHdHZha1VWcnBQeHVOSVpMU3llS1pcclxuYT1jYW5kaWRhdGU6OTYzOTg4MzQ4IDEgdWRwID\
IxMzA3MDY0MzEgMTkyLjE2OC4xLjIgNjQwMDcgdHlwIGhvc3RcclxuYT1jYW5kaWRhdGU6OTYzOTg4MzQ4IDIgdWRwIDIxMzA3MDY0MzEgMTkyLjE2OC4x\
LjIgNjQwMDcgdHlwIGhvc3RcclxuYT1jYW5kaWRhdGU6MTg2MTA0NTE5MCAxIHVkcCAxNjk0NDk4ODE1IDE0LjIxMi42OC4xMiAyNzAwNCB0eXAgc3JmbH\
ggcmFkZHIgMC4wLjAuMCBycG9ydCA2NDAwOFxyXG5hPWNhbmRpZGF0ZToxODYxMDQ1MTkwIDIgdWRwIDE2OTQ0OTg4MTUgMTQuMjEyLjY4LjEyIDI3MDA0\
IHR5cCBzcmZseCByYWRkciAwLjAuMC4wIHJwb3J0IDY0MDA4XHJcbmE9ZW5kLW9mLWNhbmRpZGF0ZXNcclxuIn0=".to_owned();
        assert_eq!(
            WebRTCStream::get_key_for_sdp_json(
                &WebRTCStream::get_remote_offer(&endpoint).unwrap_or_default()
            ).unwrap_or_default(),
            "sha-256 61:60:74:40:28:CE:0B:0C:75:4B:10:9A:EE:77:F5:44:57:84:51:DB:04:92:4A:10:1C:4E:5F:7E:F1:B3:71:22"
        );
    }

    #[tokio::test]
    async fn test_webrtc_new_stream() {
        let mut endpoint = "webrtc://sdfsdf".to_owned();
        assert!(
            WebRTCStream::new(&endpoint, false, 10000).await.is_err(),
            "invalid webrtc endpoint should error"
        );

        endpoint = "wss://sdfsdf".to_owned();
        assert!(
            WebRTCStream::new(&endpoint, false, 10000).await.is_err(),
            "invalid webrtc endpoint should error"
        );

        assert!(
            WebRTCStream::new("", false, 10000).await.is_ok(),
            "local webrtc endpoint should ok"
        );

        endpoint = "webrtc://eyJ0eXBlIjoiYW5zd2VyIiwic2RwIjoidj0wXHJcbm89LSA0MTA1NDk3NTY2NDgyMTQzODEwIDYwMzk1NzQw\
MCBJTiBJUDQgMC4wLjAuMFxyXG5zPS1cclxudD0wIDBcclxuYT1maW5nZXJwcmludDpzaGEtMjU2IDYxOjYwOjc0OjQwOjI4OkNFOjBCOjBDOjc1OjRCOj\
EwOjlBOkVFOjc3OkY1OjQ0OjU3Ojg0OjUxOkRCOjA0OjkyOjRBOjEwOjFDOjRFOjVGOjdFOkYxOkIzOjcxOjIyXHJcbmE9Z3JvdXA6QlVORExFIDBcclxu\
YT1leHRtYXAtYWxsb3ctbWl4ZWRcclxubT1hcHBsaWNhdGlvbiA5IFVEUC9EVExTL1NDVFAgd2VicnRjLWRhdGFjaGFubmVsXHJcbmM9SU4gSVA0IDAuMC\
4wLjBcclxuYT1zZXR1cDphY3RpdmVcclxuYT1taWQ6MFxyXG5hPXNlbmRyZWN2XHJcbmE9c2N0cC1wb3J0OjUwMDBcclxuYT1pY2UtdWZyYWc6SHlnU1Rr\
V2RsRlpHRG1XWlxyXG5hPWljZS1wd2Q6SkJneFZWaGZveVhHdHZha1VWcnBQeHVOSVpMU3llS1pcclxuYT1jYW5kaWRhdGU6OTYzOTg4MzQ4IDEgdWRwID\
IxMzA3MDY0MzEgMTkyLjE2OC4xLjIgNjQwMDcgdHlwIGhvc3RcclxuYT1jYW5kaWRhdGU6OTYzOTg4MzQ4IDIgdWRwIDIxMzA3MDY0MzEgMTkyLjE2OC4x\
LjIgNjQwMDcgdHlwIGhvc3RcclxuYT1jYW5kaWRhdGU6MTg2MTA0NTE5MCAxIHVkcCAxNjk0NDk4ODE1IDE0LjIxMi42OC4xMiAyNzAwNCB0eXAgc3JmbH\
ggcmFkZHIgMC4wLjAuMCBycG9ydCA2NDAwOFxyXG5hPWNhbmRpZGF0ZToxODYxMDQ1MTkwIDIgdWRwIDE2OTQ0OTg4MTUgMTQuMjEyLjY4LjEyIDI3MDA0\
IHR5cCBzcmZseCByYWRkciAwLjAuMC4wIHJwb3J0IDY0MDA4XHJcbmE9ZW5kLW9mLWNhbmRpZGF0ZXNcclxuIn0=".to_owned();
        assert!(
            WebRTCStream::new(&endpoint, false, 10000).await.is_err(),
            "connect to an 'answer' webrtc endpoint should error"
        );
    }
}
