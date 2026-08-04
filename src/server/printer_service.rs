use super::service::{EmptyExtraFieldService, GenericService, Service};
use hbb_common::{bail, dlopen::symbor::Library, log, ResultType};
use std::{
    path::PathBuf,
    sync::{Arc, Mutex},
    thread,
    time::Duration,
};

pub const NAME: &'static str = "remote-printer";

#[cfg(target_os = "windows")]
const LIB_NAME_PRINTER_DRIVER_ADAPTER: &str = "printer_driver_adapter";

#[cfg(target_os = "windows")]
// Return 0 if success, otherwise return error code.
pub type Init = fn(tag_name: *const i8) -> i32;
#[cfg(target_os = "windows")]
pub type Uninit = fn();
#[cfg(target_os = "windows")]
// dur_mills: Get the file generated in the last `dur_mills` milliseconds.
// data: The raw prn data, xps format.
// data_len: The length of the raw prn data.
pub type GetPrnData = fn(dur_mills: u32, data: *mut *mut i8, data_len: *mut u32);
#[cfg(target_os = "windows")]
// Free the prn data allocated by GetPrnData().
pub type FreePrnData = fn(data: *mut i8);

#[cfg(target_os = "windows")]
macro_rules! make_lib_wrapper {
    ($($field:ident : $tp:ty),+) => {
        struct LibWrapper {
            _lib: Option<Library>,
            $($field: Option<$tp>),+
        }

        impl LibWrapper {
            fn new() -> Self {
                let lib_name = match get_lib_name() {
                    Ok(name) => name,
                    Err(e) => {
                        log::warn!("Failed to get lib name, {}", e);
                        return Self {
                            _lib: None,
                            $( $field: None ),+
                        };
                    }
                };
                let lib = match Library::open(&lib_name) {
                    Ok(lib) => Some(lib),
                    Err(e) => {
                        log::warn!("Failed to load library {}, {}", &lib_name, e);
                        None
                    }
                };

                $(let $field = if let Some(lib) = &lib {
                    match unsafe { lib.symbol::<$tp>(stringify!($field)) } {
                        Ok(m) => {
                            Some(*m)
                        },
                        Err(e) => {
                            log::warn!("Failed to load func {}, {}", stringify!($field), e);
                            None
                        }
                    }
                } else {
                    None
                };)+

                Self {
                    _lib: lib,
                    $( $field ),+
                }
            }
        }

        impl Default for LibWrapper {
            fn default() -> Self {
                Self::new()
            }
        }
    }
}

#[cfg(target_os = "windows")]
make_lib_wrapper!(
    init: Init,
    uninit: Uninit,
    get_prn_data: GetPrnData,
    free_prn_data: FreePrnData
);

#[cfg(target_os = "windows")]
lazy_static::lazy_static! {
    static ref LIB_WRAPPER: Arc<Mutex<LibWrapper>> = Default::default();
}

#[cfg(target_os = "windows")]
fn get_lib_name() -> ResultType<String> {
    let exe_file = std::env::current_exe()?;
    if let Some(cur_dir) = exe_file.parent() {
        let dll_name = format!("{}.dll", LIB_NAME_PRINTER_DRIVER_ADAPTER);
        let full_path = cur_dir.join(dll_name);
        if !full_path.exists() {
            bail!("{} not found", full_path.to_string_lossy().as_ref());
        } else {
            Ok(full_path.to_string_lossy().into_owned())
        }
    } else {
        bail!(
            "Invalid exe parent for {}",
            exe_file.to_string_lossy().as_ref()
        );
    }
}

pub fn init(app_name: &str) -> ResultType<()> {
    #[cfg(target_os = "windows")]
    {
        let lib_wrapper = LIB_WRAPPER.lock().unwrap();
        let Some(fn_init) = lib_wrapper.init.as_ref() else {
            bail!("Failed to load func init");
        };
        let tag_name = std::ffi::CString::new(app_name)?;
        let ret = fn_init(tag_name.as_ptr());
        if ret != 0 {
            bail!("Failed to init printer driver");
        }
    }
    #[cfg(any(target_os = "macos", target_os = "linux"))]
    {
        let spool_dir = get_spool_dir(app_name);
        std::fs::create_dir_all(&spool_dir)?;
        log::info!("Printer service initialized, spool dir: {:?}", spool_dir);
    }
    Ok(())
}

pub fn uninit() {
    #[cfg(target_os = "windows")]
    {
        let lib_wrapper = LIB_WRAPPER.lock().unwrap();
        if let Some(fn_uninit) = lib_wrapper.uninit.as_ref() {
            fn_uninit();
        }
    }
}

#[cfg(target_os = "windows")]
fn get_prn_data(dur_mills: u32) -> ResultType<Vec<u8>> {
    let lib_wrapper = LIB_WRAPPER.lock().unwrap();
    if let Some(fn_get_prn_data) = lib_wrapper.get_prn_data.as_ref() {
        let mut data = std::ptr::null_mut();
        let mut data_len = 0u32;
        fn_get_prn_data(dur_mills, &mut data, &mut data_len);
        if data.is_null() || data_len == 0 {
            return Ok(Vec::new());
        }
        let bytes =
            Vec::from(unsafe { std::slice::from_raw_parts(data as *const u8, data_len as usize) });
        lib_wrapper.free_prn_data.map(|f| f(data));
        Ok(bytes)
    } else {
        bail!("Failed to load func get_prn_file");
    }
}

fn get_spool_dir(app_name: &str) -> PathBuf {
    std::env::var("HOME")
        .map(|h| PathBuf::from(h).join(format!(".local/share/{}/printjobs", app_name)))
        .unwrap_or_else(|_| {
            std::env::temp_dir().join(format!("{}/printjobs", app_name))
        })
}

#[cfg(any(target_os = "macos", target_os = "linux"))]
fn get_prn_data_from_spool(app_name: &str) -> ResultType<Vec<u8>> {
    let spool_dir = get_spool_dir(app_name);
    if !spool_dir.exists() {
        return Ok(Vec::new());
    }
    let mut entries: Vec<_> = std::fs::read_dir(&spool_dir)?
        .filter_map(|e| e.ok())
        .filter(|e| e.path().extension().map_or(false, |ext| ext == "pdf"))
        .collect();
    // Sort by modification time (oldest first)
    entries.sort_by_key(|e| e.metadata().ok().and_then(|m| m.modified().ok()));
    if let Some(entry) = entries.first() {
        let path = entry.path();
        let data = std::fs::read(&path)?;
        std::fs::remove_file(&path)?;
        log::info!("Got printer data from spool: {:?}, size: {}", path, data.len());
        Ok(data)
    } else {
        Ok(Vec::new())
    }
}

pub fn new(name: String) -> GenericService {
    let svc = EmptyExtraFieldService::new(name, false);
    GenericService::run(&svc.clone(), run);
    svc.sp
}

fn run(sp: EmptyExtraFieldService) -> ResultType<()> {
    let app_name = crate::get_app_name();
    #[cfg(target_os = "windows")]
    {
        while sp.ok() {
            let bytes = get_prn_data(1000)?;
            if !bytes.is_empty() {
                log::info!("Got prn data, data len: {}", bytes.len());
                crate::server::on_printer_data(bytes);
            }
            thread::sleep(Duration::from_millis(300));
        }
    }
    #[cfg(any(target_os = "macos", target_os = "linux"))]
    {
        let spool_dir = get_spool_dir(&app_name);
        std::fs::create_dir_all(&spool_dir).ok();
        log::info!("Printer service polling spool: {:?}", spool_dir);
        while sp.ok() {
            let bytes = get_prn_data_from_spool(&app_name)?;
            if !bytes.is_empty() {
                crate::server::on_printer_data(bytes);
            }
            thread::sleep(Duration::from_millis(500));
        }
    }
    #[cfg(not(any(target_os = "windows", target_os = "macos", target_os = "linux")))]
    {
        log::warn!("Printer service not supported on this platform");
        while sp.ok() {
            thread::sleep(Duration::from_secs(1));
        }
    }
    Ok(())
}
