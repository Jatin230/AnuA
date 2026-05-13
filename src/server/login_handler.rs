use super::connection::{Connection, LogonState, try_activate_screen};
use hbb_common::message_proto::{LoginResponse, Message, PeerInfo, SupportedResolutions, Features, SupportedEncoding};
use hbb_common::config::Config;
use crate::VERSION;
use super::connection::raii;
use crate::privacy_mode;
use scrap::camera;
use crate::server::display_service;
use crate::server::input_service;
use serde_json::json;

pub async fn setup_camera_logon(conn: &mut Connection, state: &mut LogonState) {
    let supported_encoding = scrap::codec::Encoder::supported_encoding();
    let se = SupportedEncoding {
        vp8: supported_encoding.vp8,
        av1: supported_encoding.av1,
        h264: supported_encoding.h264,
        h265: supported_encoding.h265,
        ..Default::default()
    };
    conn.last_supported_encoding = Some(se.clone());
    state.pi.encoding = Some(se).into();
    state.pi.displays = camera::Cameras::all_info().unwrap_or(Vec::new());
    state.pi.current_display = camera::PRIMARY_CAMERA_IDX as _;
    #[cfg(not(any(target_os = "android", target_os = "ios")))]
    {
        state.pi.resolutions = Some(SupportedResolutions {
            resolutions: camera::Cameras::get_camera_resolution(
                state.pi.current_display as usize,
            )
            .ok()
            .into_iter()
            .collect(),
            ..Default::default()
        })
        .into();
    }
    state.res.set_peer_info(state.pi.clone());
    conn.update_codec_on_login();
}

pub async fn setup_remote_logon(conn: &mut Connection, state: &mut LogonState) {
    let supported_encoding = scrap::codec::Encoder::supported_encoding();
    let se = SupportedEncoding {
        vp8: supported_encoding.vp8,
        av1: supported_encoding.av1,
        h264: supported_encoding.h264,
        h265: supported_encoding.h265,
        ..Default::default()
    };
    conn.last_supported_encoding = Some(se.clone());
    state.pi.encoding = Some(se).into();
    if let Some(msg_out) = display_service::is_inited_msg() {
        conn.send(msg_out).await;
    }
    try_activate_screen();
    match display_service::update_get_sync_displays_on_login().await {
        Err(err) => {
            state.res.set_error(format!("{}", err));
        }
        Ok(displays) => {
            #[cfg(target_os = "macos")]
            conn.retina.set_displays(&displays);
            state.pi.displays = displays;
            state.pi.current_display = conn.display_idx as _;
            #[cfg(not(any(target_os = "android", target_os = "ios")))]
            {
                state.pi.resolutions = Some(SupportedResolutions {
                    resolutions: state.pi.displays.get(conn.display_idx)
                        .map(|d| crate::platform::resolutions(&d.name))
                        .unwrap_or(vec![]),
                    ..Default::default()
                }).into();
            }
            state.res.set_peer_info(state.pi.clone());
            state.sub_service = true;
            #[cfg(target_os = "linux")]
            if input_service::wayland_use_rdp_input() {
                let _ = super::connection::setup_rdp_input().await;
            }
        }
    }
    conn.on_remote_authorized();
}

#[cfg(target_os = "linux")]
pub fn check_linux_remote_error() -> Option<String> {
    if crate::platform::linux::is_login_screen_wayland() {
        Some(crate::client::LOGIN_SCREEN_WAYLAND.to_owned())
    } else {
        let dtype = crate::platform::linux::get_display_server();
        if dtype != crate::platform::linux::DISPLAY_SERVER_X11
            && dtype != crate::platform::linux::DISPLAY_SERVER_WAYLAND
        {
            Some(format!(
                "Unsupported display server type \"{}\", x11 or wayland expected",
                dtype
            ))
        } else {
            None
        }
    }
}
