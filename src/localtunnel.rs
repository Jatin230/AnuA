use hbb_common::{
    allow_err,
    log,
    tokio,
    ResultType,
    uuid::Uuid,
    serde_json,
    Stream,
    lazy_static,
    bail,
};
use std::net::SocketAddr;
use std::sync::{Arc, Mutex};
use std::collections::HashMap;
use tokio::net::{TcpListener, TcpStream};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use serde_derive::{Deserialize, Serialize};

#[derive(Debug, Serialize, Deserialize)]
struct TunnelInfo {
    pub id: String,
    pub port: u16,
    pub max_conn_count: u32,
    pub url: String,
}

lazy_static::lazy_static! {
    static ref ACTIVE_TUNNEL: Arc<Mutex<Option<TunnelInfo>>> = Arc::new(Mutex::new(None));
    static ref STOP_SIGNAL: Arc<Mutex<bool>> = Arc::new(Mutex::new(false));
}

pub struct LocaltunnelHost;

impl LocaltunnelHost {
    pub async fn start(local_port: u16) -> ResultType<String> {
        // 1. Request tunnel from localtunnel.me
        let client = reqwest::Client::new();
        let res = client.get("https://localtunnel.me/?new")
            .send()
            .await?
            .json::<TunnelInfo>()
            .await?;
        
        let url = res.url.clone();
        let remote_port = res.port;
        let tunnel_id = res.id.clone();
        
        log::info!("Tunnel established: {} -> localhost:{}", url, local_port);
        *ACTIVE_TUNNEL.lock().unwrap() = Some(res);
        *STOP_SIGNAL.lock().unwrap() = false;

        // 2. Start proxy loop
        tokio::spawn(async move {
            if let Err(e) = run_tunnel_loop(tunnel_id, remote_port, local_port).await {
                log::error!("Tunnel loop error: {}", e);
            }
        });

        Ok(url)
    }

    pub fn stop() {
        *STOP_SIGNAL.lock().unwrap() = true;
        *ACTIVE_TUNNEL.lock().unwrap() = None;
    }
}

async fn run_tunnel_loop(id: String, remote_port: u16, local_port: u16) -> ResultType<()> {
    let remote_addr = format!("localtunnel.me:{}", remote_port);
    let local_addr = format!("127.0.0.1:{}", local_port);
    
    log::info!("Starting tunnel loop: {} -> {}", remote_addr, local_addr);
    
    // Localtunnel server expects multiple connections to be ready
    for i in 0..5 {
        let remote_addr = remote_addr.clone();
        let local_addr = local_addr.clone();
        tokio::spawn(async move {
            log::debug!("Tunnel worker {} started", i);
            while !*STOP_SIGNAL.lock().unwrap() {
                if let Ok(mut remote_stream) = TcpStream::connect(&remote_addr).await {
                    log::debug!("Connected to tunnel server, connecting to local...");
                    match TcpStream::connect(&local_addr).await {
                        Ok(mut local_stream) => {
                            log::debug!("Tunnel established for one connection");
                            let _ = tokio::io::copy_bidirectional(&mut remote_stream, &mut local_stream).await;
                        }
                        Err(e) => {
                            log::error!("Failed to connect to local port {}: {}", local_addr, e);
                            tokio::time::sleep(std::time::Duration::from_secs(2)).await;
                        }
                    }
                }
                tokio::time::sleep(std::time::Duration::from_millis(500)).await;
            }
        });
    }
    
    Ok(())
}

// FFI compatibility functions
pub fn start_host(port: u16) -> String {
    // This is a placeholder for actual FFI usage which will be handled in flutter_ffi.rs
    "".to_string()
}
