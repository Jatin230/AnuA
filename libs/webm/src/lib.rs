pub mod mux {
    #[derive(Clone, Copy, Debug)]
    pub enum VideoCodecId {
        VP8,
        VP9,
        AV1,
    }

    pub struct Writer<W> {
        #[allow(dead_code)]
        inner: W,
    }

    impl<W> Writer<W> {
        pub fn new(inner: W) -> Self {
            Self { inner }
        }
    }

    pub struct Segment<W> {
        #[allow(dead_code)]
        writer: W,
        next_track_number: u64,
    }

    impl<W> Segment<W> {
        pub fn new(writer: W) -> Option<Self> {
            Some(Self {
                writer,
                next_track_number: 1,
            })
        }

        pub fn add_video_track(
            &mut self,
            width: u64,
            height: u64,
            _codec_private: Option<&[u8]>,
            codec: VideoCodecId,
        ) -> VideoTrack {
            let track_number = self.next_track_number;
            self.next_track_number += 1;
            VideoTrack {
                track_number,
                width,
                height,
                codec,
            }
        }

        pub fn set_codec_private(&mut self, _track_number: u64, _codec_private: &[u8]) -> bool {
            true
        }

        pub fn finalize(self, _footer: Option<&[u8]>) -> bool {
            true
        }
    }

    pub trait Track {
        fn track_number(&self) -> u64;
        fn add_frame(&mut self, data: &[u8], pts: u64, key: bool) -> bool;
    }

    pub struct VideoTrack {
        track_number: u64,
        #[allow(dead_code)]
        width: u64,
        #[allow(dead_code)]
        height: u64,
        #[allow(dead_code)]
        codec: VideoCodecId,
    }

    impl VideoTrack {
        pub fn track_number(&self) -> u64 {
            self.track_number
        }

        pub fn add_frame(&mut self, _data: &[u8], _pts: u64, _key: bool) -> bool {
            true
        }
    }

    impl Track for VideoTrack {
        fn track_number(&self) -> u64 {
            self.track_number()
        }

        fn add_frame(&mut self, data: &[u8], pts: u64, key: bool) -> bool {
            self.add_frame(data, pts, key)
        }
    }
}
