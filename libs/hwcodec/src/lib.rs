pub const DEFAULT_FPS: u32 = 30;

pub mod android {
    pub fn ffmpeg_set_java_vm(_java_vm: *mut core::ffi::c_void) {}
}

pub mod common {
    #[derive(Clone, Copy, Debug, PartialEq, Eq)]
    pub enum DataFormat {
        H264,
        H265,
        Unknown,
    }

    pub fn get_gpu_signature() -> String {
        String::new()
    }

    pub fn setup_parent_death_signal() {}

    pub fn child_exit_when_parent_exit(_pid: u32) {}
}

pub mod ffmpeg_ram {
    #[derive(Clone, Debug)]
    pub struct CodecInfo;
}

pub mod mux {
    #[derive(Clone, Debug)]
    pub struct MuxContext;

    #[derive(Clone, Debug)]
    pub struct Muxer;
}

pub mod vram {
    #[derive(Clone, Debug)]
    pub struct FeatureContext;

    #[derive(Clone, Debug)]
    pub struct DecodeContext;
}

#[derive(Clone, Debug)]
pub struct HwCodecConfig;

impl HwCodecConfig {
    pub fn get() -> Self {
        Self
    }

    pub fn already_set() -> bool {
        false
    }

    pub fn set(_value: Self) {}

    pub fn get_set_value() -> Result<Self, ()> {
        Ok(Self)
    }

    pub fn vram_encode(&self) -> Vec<vram::FeatureContext> {
        Vec::new()
    }

    pub fn vram_decode(&self) -> Vec<vram::DecodeContext> {
        Vec::new()
    }
}

#[derive(Clone, Debug)]
pub struct HwRamEncoder;

#[derive(Clone, Debug)]
pub struct HwRamEncoderConfig;

#[derive(Clone, Debug)]
pub struct HwRamDecoder;

impl HwRamEncoder {
    pub fn try_get(_format: common::DataFormat) -> Option<Self> {
        None
    }

    pub fn calc_bitrate(_width: u32, _height: u32, _ratio: u32, _h264: bool) -> u32 {
        0
    }
}

impl HwRamDecoder {
    pub fn try_get(_format: common::DataFormat) -> Option<Self> {
        None
    }
}

pub fn start_check_process() {}
pub fn check_available_hwcodec() -> bool {
    false
}
