use std::fmt;

pub mod pixel_format {
    #[derive(Clone, Copy, Debug)]
    pub struct RgbAFormat;
}

pub mod utils {
    #[derive(Clone, Copy, Debug)]
    pub enum ApiBackend {
        Auto,
    }

    #[derive(Clone, Debug, PartialEq, Eq)]
    pub enum CameraIndex {
        Index(u32),
    }

    #[derive(Clone, Copy, Debug)]
    pub enum RequestedFormatType {
        None,
        AbsoluteHighestResolution,
    }

    #[derive(Clone, Debug)]
    pub struct RequestedFormat;

    impl RequestedFormat {
        pub fn new<T>(_format_type: RequestedFormatType) -> Self {
            let _ = std::marker::PhantomData::<T>;
            Self
        }
    }
}

#[derive(Clone, Debug)]
pub struct CameraInfo {
    index: utils::CameraIndex,
    human_name: String,
}

impl CameraInfo {
    pub fn index(&self) -> &utils::CameraIndex {
        &self.index
    }

    pub fn human_name(&self) -> &String {
        &self.human_name
    }
}

#[derive(Clone, Debug)]
pub struct Resolution {
    width: u32,
    height: u32,
}

impl Resolution {
    pub fn width(&self) -> u32 {
        self.width
    }

    pub fn height(&self) -> u32 {
        self.height
    }
}

#[derive(Clone, Debug)]
pub struct Camera;

impl Camera {
    pub fn new(
        _index: utils::CameraIndex,
        _format: utils::RequestedFormat,
    ) -> Result<Self, String> {
        Ok(Self)
    }

    pub fn resolution(&self) -> Resolution {
        Resolution {
            width: 1280,
            height: 720,
        }
    }

    pub fn is_stream_open(&self) -> bool {
        false
    }

    pub fn open_stream(&mut self) -> Result<(), String> {
        Ok(())
    }

    pub fn frame(&mut self) -> Result<FrameBuffer, String> {
        Err("camera capture not available in stub".to_string())
    }
}

#[derive(Clone, Debug)]
pub struct FrameBuffer;

impl FrameBuffer {
    pub fn decode_image<T>(&self) -> Result<DecodedImage, String> {
        let _ = std::marker::PhantomData::<T>;
        Ok(DecodedImage {
            data: vec![],
            width: 1280,
            height: 720,
        })
    }
}

#[derive(Clone, Debug)]
pub struct DecodedImage {
    data: Vec<u8>,
    width: u32,
    height: u32,
}

impl DecodedImage {
    pub fn as_raw(&self) -> &[u8] {
        &self.data
    }

    pub fn width(&self) -> u32 {
        self.width
    }

    pub fn height(&self) -> u32 {
        self.height
    }
}

pub fn query(_backend: utils::ApiBackend) -> Result<Vec<CameraInfo>, String> {
    Ok(vec![])
}

impl fmt::Display for utils::CameraIndex {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            utils::CameraIndex::Index(index) => write!(f, "{}", index),
        }
    }
}
