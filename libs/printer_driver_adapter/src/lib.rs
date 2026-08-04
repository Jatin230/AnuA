use std::ffi::CStr;
use std::fs;
use std::path::PathBuf;
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

static SPOOL_DIR: Mutex<Option<String>> = Mutex::new(None);
static INITIALIZED: AtomicBool = AtomicBool::new(false);
static JOB_COUNTER: AtomicU64 = AtomicU64::new(0);
static CURRENT_JOB: Mutex<Option<String>> = Mutex::new(None);

fn get_spool_dir() -> Option<PathBuf> {
    SPOOL_DIR.lock().ok()?.as_ref().map(|s| PathBuf::from(s))
}

// ======== Rust-side polling interface ========

#[no_mangle]
pub extern "C" fn init(tag_name: *const i8) -> i32 {
    if tag_name.is_null() {
        return 1;
    }
    let tag = match unsafe { CStr::from_ptr(tag_name) }.to_str() {
        Ok(s) => s,
        Err(_) => return 1,
    };
    let path = std::env::var("PROGRAMDATA")
        .ok()
        .map(|p| PathBuf::from(p).join(tag).join("printjobs"))
        .unwrap_or_else(|| {
            let mut p = std::env::temp_dir();
            p.push(tag);
            p.push("printjobs");
            p
        });
    if let Ok(mut guard) = SPOOL_DIR.lock() {
        *guard = Some(path.to_string_lossy().to_string());
    } else {
        return 1;
    }
    fs::create_dir_all(&path).ok();
    INITIALIZED.store(true, Ordering::SeqCst);
    0
}

#[no_mangle]
pub extern "C" fn uninit() {
    INITIALIZED.store(false, Ordering::SeqCst);
    if let Ok(mut guard) = SPOOL_DIR.lock() {
        *guard = None;
    }
}

#[no_mangle]
pub extern "C" fn get_prn_data(
    _dur_mills: u32,
    data: *mut *mut i8,
    data_len: *mut u32,
) {
    if data.is_null() || data_len.is_null() {
        return;
    }
    if !INITIALIZED.load(Ordering::SeqCst) {
        return;
    }
    let spool = match get_spool_dir() {
        Some(p) => p,
        None => return,
    };
    if !spool.exists() {
        return;
    }
    let mut entries: Vec<_> = match fs::read_dir(&spool) {
        Ok(e) => e.filter_map(|e| e.ok()).collect(),
        Err(_) => return,
    };
    entries.sort_by_key(|e| e.metadata().ok().and_then(|m| m.modified().ok()));
    let path = match entries.iter()
        .find(|e| e.path().extension().map_or(false, |ext| ext == "prn"))
        .map(|e| e.path())
    {
        Some(p) => p,
        None => return,
    };
    let bytes = match fs::read(&path) {
        Ok(b) => b,
        Err(_) => return,
    };
    fs::remove_file(&path).ok();
    if bytes.is_empty() {
        return;
    }
    unsafe {
        let ptr = libc::malloc(bytes.len()) as *mut u8;
        if ptr.is_null() {
            return;
        }
        std::ptr::copy_nonoverlapping(bytes.as_ptr(), ptr, bytes.len());
        *data = ptr as *mut i8;
        *data_len = bytes.len() as u32;
    }
}

#[no_mangle]
pub extern "C" fn free_prn_data(data: *mut i8) {
    if !data.is_null() {
        unsafe { libc::free(data as *mut libc::c_void); }
    }
}

// ======== Windows v4 Printer Driver ========

const PRINTER_EVENT_INITIALIZE: i32 = 0x1000;
const PRINTER_EVENT_ADD_PRINTER: i32 = 0x1001;
const PRINTER_EVENT_DELETE_PRINTER: i32 = 0x1002;
const PRINTER_EVENT_START_DOC: i32 = 0x1003;
const PRINTER_EVENT_WRITE_PRINTER: i32 = 0x1004;
const PRINTER_EVENT_END_DOC: i32 = 0x1005;

#[no_mangle]
pub extern "system" fn DrvPrinterEvent(
    _psz_printer_name: *const u16,
    us_event: i32,
    p_event_data: *mut std::ffi::c_void,
    cb_event_data: u32,
) -> i32 {
    match us_event {
        PRINTER_EVENT_INITIALIZE | PRINTER_EVENT_ADD_PRINTER | PRINTER_EVENT_DELETE_PRINTER => {}
        PRINTER_EVENT_START_DOC => {
            let spool = match get_spool_dir() {
                Some(p) => p,
                None => return 0,
            };
            fs::create_dir_all(&spool).ok();
            let now = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap_or_default()
                .as_nanos();
            let seq = JOB_COUNTER.fetch_add(1, Ordering::SeqCst);
            let tmp = spool.join(format!("job_{}_{}.tmp", now, seq));
            if let Ok(mut guard) = CURRENT_JOB.lock() {
                *guard = Some(tmp.to_string_lossy().to_string());
            }
        }
        PRINTER_EVENT_WRITE_PRINTER => {
            if p_event_data.is_null() || cb_event_data == 0 {
                return 0;
            }
            let tmp_path = match CURRENT_JOB.lock() {
                Ok(guard) => guard.clone(),
                Err(_) => return 0,
            };
            if let Some(ref path) = tmp_path {
                use std::io::Write;
                let data = unsafe {
                    std::slice::from_raw_parts(
                        p_event_data as *const u8,
                        cb_event_data as usize,
                    )
                };
                if let Ok(mut f) = fs::OpenOptions::new()
                    .create(true)
                    .append(true)
                    .open(path)
                {
                    let _ = f.write_all(data);
                }
            }
        }
        PRINTER_EVENT_END_DOC => {
            let tmp_path = match CURRENT_JOB.lock() {
                Ok(mut guard) => guard.take(),
                Err(_) => None,
            };
            if let Some(path) = tmp_path {
                let from = PathBuf::from(&path);
                let to = from.with_extension("prn");
                fs::rename(&from, &to).ok();
            }
        }
        _ => {}
    }
    0
}
