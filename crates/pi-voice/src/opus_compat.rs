//! Small Android-only Opus wrapper.
//!
//! Termux provides libopus as a shared library, while `audiopus_sys` 0.2.2
//! does not compile for `aarch64-linux-android`: its build script leaves its
//! default-linking helper without a return value on Android. Keep the native
//! voice path intact by binding only the encoder/decoder operations used by
//! the live transport instead of forking the whole generated binding.

use std::{
    ffi::{c_int, CStr},
    fmt,
    ptr::NonNull,
};

const OPUS_OK: c_int = 0;
const OPUS_APPLICATION_VOIP: c_int = 2_048;
const OPUS_SET_INBAND_FEC_REQUEST: c_int = 4_012;

#[repr(C)]
struct OpusEncoder {
    _private: [u8; 0],
}

#[repr(C)]
struct OpusDecoder {
    _private: [u8; 0],
}

unsafe extern "C" {
    fn opus_encoder_create(
        sample_rate: c_int,
        channels: c_int,
        application: c_int,
        error: *mut c_int,
    ) -> *mut OpusEncoder;
    fn opus_encoder_destroy(encoder: *mut OpusEncoder);
    fn opus_encoder_ctl(encoder: *mut OpusEncoder, request: c_int, ...) -> c_int;
    fn opus_encode_float(
        encoder: *mut OpusEncoder,
        pcm: *const f32,
        frame_size: c_int,
        data: *mut u8,
        max_data_bytes: c_int,
    ) -> c_int;
    fn opus_decoder_create(
        sample_rate: c_int,
        channels: c_int,
        error: *mut c_int,
    ) -> *mut OpusDecoder;
    fn opus_decoder_destroy(decoder: *mut OpusDecoder);
    fn opus_decode_float(
        decoder: *mut OpusDecoder,
        data: *const u8,
        len: c_int,
        pcm: *mut f32,
        frame_size: c_int,
        decode_fec: c_int,
    ) -> c_int;
    fn opus_strerror(error: c_int) -> *const std::ffi::c_char;
}

#[derive(Clone, Copy, Debug)]
pub enum Application {
    Voip,
}

impl Application {
    const fn raw(self) -> c_int {
        match self {
            Self::Voip => OPUS_APPLICATION_VOIP,
        }
    }
}

#[derive(Clone, Copy, Debug)]
pub enum Channels {
    Mono,
}

impl Channels {
    const fn raw(self) -> c_int {
        match self {
            Self::Mono => 1,
        }
    }
}

#[derive(Clone, Copy, Debug)]
pub(crate) struct OpusError {
    operation: &'static str,
    code: c_int,
}

impl OpusError {
    const fn new(operation: &'static str, code: c_int) -> Self {
        Self { operation, code }
    }
}

impl fmt::Display for OpusError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        let description = unsafe { opus_strerror(self.code) };
        let description = if description.is_null() {
            "unknown Opus error"
        } else {
            unsafe { CStr::from_ptr(description) }
                .to_str()
                .unwrap_or("invalid Opus error")
        };
        write!(formatter, "{} ({}, code {})", description, self.operation, self.code)
    }
}

impl std::error::Error for OpusError {}

pub struct Encoder {
    ptr: NonNull<OpusEncoder>,
}

// The encoder is owned by one tokio task and never shared concurrently.
unsafe impl Send for Encoder {}

impl Encoder {
    pub fn new(
        sample_rate: u32,
        channels: Channels,
        application: Application,
    ) -> Result<Self, OpusError> {
        let sample_rate = c_int::try_from(sample_rate)
            .map_err(|_| OpusError::new("opus_encoder_create", -1))?;
        let mut error = OPUS_OK;
        let ptr = unsafe {
            opus_encoder_create(sample_rate, channels.raw(), application.raw(), &mut error)
        };
        NonNull::new(ptr)
            .map(|ptr| Self { ptr })
            .ok_or_else(|| OpusError::new("opus_encoder_create", error))
    }

    pub fn set_inband_fec(&mut self, enabled: bool) -> Result<(), OpusError> {
        let value: c_int = if enabled { 1 } else { 0 };
        let code = unsafe { opus_encoder_ctl(self.ptr.as_ptr(), OPUS_SET_INBAND_FEC_REQUEST, value) };
        if code == OPUS_OK {
            Ok(())
        } else {
            Err(OpusError::new("opus_encoder_ctl(OPUS_SET_INBAND_FEC)", code))
        }
    }

    pub fn encode_float(&mut self, input: &[f32], output: &mut [u8]) -> Result<usize, OpusError> {
        let frame_size = c_int::try_from(input.len())
            .map_err(|_| OpusError::new("opus_encode_float", -1))?;
        let max_data_bytes = c_int::try_from(output.len())
            .map_err(|_| OpusError::new("opus_encode_float", -1))?;
        let code = unsafe {
            opus_encode_float(
                self.ptr.as_ptr(),
                input.as_ptr(),
                frame_size,
                output.as_mut_ptr(),
                max_data_bytes,
            )
        };
        if code >= 0 {
            Ok(code as usize)
        } else {
            Err(OpusError::new("opus_encode_float", code))
        }
    }
}

impl Drop for Encoder {
    fn drop(&mut self) {
        unsafe { opus_encoder_destroy(self.ptr.as_ptr()) };
    }
}

pub struct Decoder {
    ptr: NonNull<OpusDecoder>,
}

// The decoder is owned by one tokio task and never shared concurrently.
unsafe impl Send for Decoder {}

impl Decoder {
    pub fn new(sample_rate: u32, channels: Channels) -> Result<Self, OpusError> {
        let sample_rate = c_int::try_from(sample_rate)
            .map_err(|_| OpusError::new("opus_decoder_create", -1))?;
        let mut error = OPUS_OK;
        let ptr = unsafe { opus_decoder_create(sample_rate, channels.raw(), &mut error) };
        NonNull::new(ptr)
            .map(|ptr| Self { ptr })
            .ok_or_else(|| OpusError::new("opus_decoder_create", error))
    }

    pub fn decode_float(
        &mut self,
        input: &[u8],
        output: &mut [f32],
        decode_fec: bool,
    ) -> Result<usize, OpusError> {
        let len = c_int::try_from(input.len())
            .map_err(|_| OpusError::new("opus_decode_float", -1))?;
        let frame_size = c_int::try_from(output.len())
            .map_err(|_| OpusError::new("opus_decode_float", -1))?;
        let data = input
            .is_empty()
            .then_some(std::ptr::null())
            .unwrap_or(input.as_ptr());
        let code = unsafe {
            opus_decode_float(
                self.ptr.as_ptr(),
                data,
                len,
                output.as_mut_ptr(),
                frame_size,
                if decode_fec { 1 } else { 0 },
            )
        };
        if code >= 0 {
            Ok(code as usize)
        } else {
            Err(OpusError::new("opus_decode_float", code))
        }
    }
}

impl Drop for Decoder {
    fn drop(&mut self) {
        unsafe { opus_decoder_destroy(self.ptr.as_ptr()) };
    }
}
