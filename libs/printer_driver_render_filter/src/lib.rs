#![allow(non_snake_case)]
#![allow(private_interfaces)]

// XPSDrv render filter for the Anuvadini v4 printer driver.
//
// The print spooler loads this DLL from the driver store and instantiates the
// COM class identified by FILTER_CLSID (see *-PipelineConfig.xml). The filter
// is the first and only filter in the v4 render pipeline, so its input stream
// is the XPS document of the print job. StartOperation copies that stream to
// the spool directory that the app-side adapter (printer_driver_adapter.dll)
// polls, naming the completed file with a ".prn" extension.
//
// The filter is a terminal capture filter: it also mirrors the input into the
// declared output stream so the job completes normally for the port monitor.

use std::ffi::c_void;
use std::fs;
use std::io::Write;
use std::path::PathBuf;
use std::sync::atomic::{AtomicI32, AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

const TRACE_PATH: &str = "C:\\Windows\\Temp\\AnuvadiniFilterLog.txt";

fn trace(msg: &str) {
    let line = format!("{}\n", msg);
    if let Ok(mut f) = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(TRACE_PATH)
    {
        let _ = f.write_all(line.as_bytes());
    }
}

fn trace_ptr(label: &str, p: *const c_void) {
    trace(&format!("{}={:p}", label, p));
}

fn trace_vtbl(label: &str, p: *const c_void) {
    if p.is_null() {
        trace(&format!("{}: null", label));
        return;
    }
    unsafe {
        let vtbl = *(p as *const *const c_void);
        trace(&format!("{}: vtbl={:p}", label, vtbl));
        if !vtbl.is_null() {
            let slots = vtbl as *const *const c_void;
            for i in 0..5 {
                trace(&format!("  slot[{}]={:p}", i, *slots.offset(i)));
            }
        }
    }
}

fn trace_members(label: &str, p: *const c_void) {
    if p.is_null() {
        trace(&format!("{}: null", label));
        return;
    }
    unsafe {
        let q = p as *const *const c_void;
        trace(&format!("{}: p={:p} [0]={:p} [8]={:p} [10h]={:p} [18h]={:p}", label, p,
            *q, *q.offset(1), *q.offset(2), *q.offset(3)));
    }
}

fn trace_ptr_slots(label: &str, p: *const c_void) {
    if p.is_null() {
        trace(&format!("{}: null", label));
        return;
    }
    unsafe {
        let vtbl = *(p as *const *const c_void);
        trace(&format!("{}: obj vtbl={:p}", label, vtbl));
        if !vtbl.is_null() {
            let slots = vtbl as *const *const c_void;
            for i in 0..6 {
                trace(&format!("  {} vtbl[{}]={:p}", label, i, *slots.offset(i)));
            }
        }
    }
}

fn trace_bytes(label: &str, p: *const c_void, len: usize) {
    if p.is_null() {
        trace(&format!("{}: null", label));
        return;
    }
    unsafe {
        let b = p as *const u8;
        let mut hex = String::with_capacity(len * 3);
        let mut ascii = String::with_capacity(len);
        for i in 0..len {
            let byte = *b.offset(i as isize);
            hex.push_str(&format!("{:02X} ", byte));
            ascii.push(if byte >= 0x20 && byte < 0x7f { byte as char } else { '.' });
        }
        trace(&format!("{}: {} | {}", label, hex, ascii));
    }
}

// ======== HRESULTs ========
const S_OK: i32 = 0;
const S_FALSE: i32 = 1;
const E_NOINTERFACE: i32 = 0x8000_4002u32 as i32;
const E_POINTER: i32 = 0x8000_4003u32 as i32;
const CLASS_E_CLASSNOTAVAILABLE: i32 = 0x8004_0111u32 as i32;
const CLASS_E_NOAGGREGATION: i32 = 0x8004_0110u32 as i32;
const ERROR_ACCESS_DENIED: i32 = 0x8007_0005u32 as i32;
const ERROR_FILE_NOT_FOUND: i32 = 0x8007_0002u32 as i32;
const E_FAIL: i32 = 0x8000_4005u32 as i32;

// ======== GUIDs ========
#[repr(C)]
#[derive(Clone, Copy)]
struct Guid {
    data1: u32,
    data2: u16,
    data3: u16,
    data4: [u8; 8],
}

const FILTER_CLSID: Guid = Guid {
    data1: 0x7ADB3ADE,
    data2: 0x5818,
    data3: 0x4A67,
    data4: [0x9B, 0xA4, 0xA5, 0x16, 0xE8, 0x51, 0x40, 0x59],
};

const IID_IUNKNOWN: Guid = Guid {
    data1: 0,
    data2: 0,
    data3: 0,
    data4: [0xC0, 0, 0, 0, 0, 0, 0, 0x46],
};

const IID_ICLASSFACTORY: Guid = Guid {
    data1: 1,
    data2: 0,
    data3: 0,
    data4: [0xC0, 0, 0, 0, 0, 0, 0, 0x46],
};

const IID_IPRINT_PIPELINE_FILTER: Guid = Guid {
    data1: 0xCDB6_2FC0,
    data2: 0x8BED,
    data3: 0x434E,
    data4: [0x86, 0xFB, 0xA2, 0xCA, 0xE5, 0x5F, 0x19, 0xEA],
};

#[inline]
fn guid_eq(a: *const Guid, b: &Guid) -> bool {
    if a.is_null() {
        return false;
    }
    unsafe {
        let a = &*a;
        a.data1 == b.data1 && a.data2 == b.data2 && a.data3 == b.data3 && a.data4 == b.data4
    }
}

// ======== Spooler-provided interface vtables (we only call these) ========

#[repr(C)]
struct InterFilterCommunicatorVtbl {
    qe: unsafe extern "system" fn(*mut c_void, *const Guid, *mut *mut c_void) -> i32,
    ar: unsafe extern "system" fn(*mut c_void) -> u32,
    rel: unsafe extern "system" fn(*mut c_void) -> u32,
    request_reader: unsafe extern "system" fn(*mut c_void, *mut *mut c_void) -> i32,
    request_writer: unsafe extern "system" fn(*mut c_void, *mut *mut c_void) -> i32,
}

#[repr(C)]
struct PrintReadStreamVtbl {
    qe: unsafe extern "system" fn(*mut c_void, *const Guid, *mut *mut c_void) -> i32,
    ar: unsafe extern "system" fn(*mut c_void) -> u32,
    rel: unsafe extern "system" fn(*mut c_void) -> u32,
    seek: unsafe extern "system" fn(*mut c_void, i64, u32, *mut u64) -> i32,
    read_bytes: unsafe extern "system" fn(*mut c_void, *mut c_void, u32, *mut u32, *mut i32) -> i32,
}

#[repr(C)]
struct PrintWriteStreamVtbl {
    qe: unsafe extern "system" fn(*mut c_void, *const Guid, *mut *mut c_void) -> i32,
    ar: unsafe extern "system" fn(*mut c_void) -> u32,
    rel: unsafe extern "system" fn(*mut c_void) -> u32,
    write_bytes: unsafe extern "system" fn(*mut c_void, *const c_void, u32, *mut u32) -> i32,
    close: unsafe extern "system" fn(*mut c_void),
}

#[repr(C)]
struct PipelineManagerControlVtbl {
    qe: unsafe extern "system" fn(*mut c_void, *const Guid, *mut *mut c_void) -> i32,
    ar: unsafe extern "system" fn(*mut c_void) -> u32,
    rel: unsafe extern "system" fn(*mut c_void) -> u32,
    request_shutdown: unsafe extern "system" fn(*mut c_void, i32, *mut c_void) -> i32,
    filter_finished: unsafe extern "system" fn(*mut c_void) -> i32,
}

unsafe fn comm_add_ref(comm: *mut c_void) -> u32 {
    if comm.is_null() {
        return 0;
    }
    let vtbl = *(comm as *const *const InterFilterCommunicatorVtbl);
    ((*vtbl).ar)(comm)
}

unsafe fn comm_release(comm: *mut c_void) -> u32 {
    if comm.is_null() {
        return 0;
    }
    let vtbl = *(comm as *const *const InterFilterCommunicatorVtbl);
    ((*vtbl).rel)(comm)
}

unsafe fn obj_add_ref(obj: *mut c_void) -> u32 {
    if obj.is_null() {
        return 0;
    }
    let vtbl = *(obj as *const *const usize);
    let addref: unsafe extern "system" fn(*mut c_void) -> u32 =
        std::mem::transmute(*vtbl.offset(1) as *const c_void);
    addref(obj)
}

unsafe fn obj_release(obj: *mut c_void) -> u32 {
    if obj.is_null() {
        return 0;
    }
    let vtbl = *(obj as *const *const usize);
    let release: unsafe extern "system" fn(*mut c_void) -> u32 =
        std::mem::transmute(*vtbl.offset(2) as *const c_void);
    release(obj)
}

unsafe fn comm_request_reader(comm: *mut c_void, out: *mut *mut c_void) -> i32 {
    trace_ptr("  [req_reader] comm", comm);
    trace_bytes("  [req_reader] comm bytes", comm, 64);
    trace_bytes("  [req_reader] comm-16", (comm as isize - 16) as *const c_void, 64);
    trace_ptr_slots("  [req_reader] comm[0]", comm);
    if comm.is_null() {
        return E_POINTER;
    }
    unsafe {
        let second = (comm as *const *const c_void).offset(1);
        trace_ptr_slots("  [req_reader] comm[8]", *second);
    }
    let vtbl = *(comm as *const *const InterFilterCommunicatorVtbl);
    let hr = ((*vtbl).request_reader)(comm, out);
    trace(&format!("  [req_reader] hr=0x{:08X} reader={:p}", hr, *out));
    hr
}

unsafe fn comm_request_writer(comm: *mut c_void, out: *mut *mut c_void) -> i32 {
    trace_ptr("  [req_writer] comm", comm);
    trace_vtbl("  [req_writer] comm vtbl", comm);
    if comm.is_null() {
        return E_POINTER;
    }
    let vtbl = *(comm as *const *const InterFilterCommunicatorVtbl);
    let hr = ((*vtbl).request_writer)(comm, out);
    trace(&format!("  [req_writer] hr=0x{:08X} writer={:p}", hr, *out));
    hr
}

unsafe fn read_stream_read_bytes(
    stream: *mut c_void,
    buf: *mut c_void,
    requested: u32,
    read: *mut u32,
    eof: *mut i32,
) -> i32 {
    trace_ptr("  [read] stream", stream);
    if stream.is_null() {
        return E_POINTER;
    }
    let vtbl = *(stream as *const *const PrintReadStreamVtbl);
    let hr = ((*vtbl).read_bytes)(stream, buf, requested, read, eof);
    trace(&format!("  [read] hr=0x{:08X} read={} eof={}", hr, *read, *eof));
    hr
}

unsafe fn write_stream_write_bytes(
    stream: *mut c_void,
    buf: *const c_void,
    len: u32,
    written: *mut u32,
) -> i32 {
    trace_ptr("  [write] stream", stream);
    if stream.is_null() {
        return E_POINTER;
    }
    let vtbl = *(stream as *const *const PrintWriteStreamVtbl);
    let hr = ((*vtbl).write_bytes)(stream, buf, len, written);
    trace(&format!("  [write] hr=0x{:08X} written={}", hr, *written));
    hr
}

unsafe fn write_stream_close(stream: *mut c_void) {
    trace_ptr("  [close] stream", stream);
    if stream.is_null() {
        return;
    }
    let vtbl = *(stream as *const *const PrintWriteStreamVtbl);
    ((*vtbl).close)(stream);
    trace("  [close] done");
}

unsafe fn pipeline_control_filter_finished(control: *mut c_void) -> i32 {
    trace_ptr("  [filter_finished] control", control);
    if control.is_null() {
        return E_POINTER;
    }
    let vtbl = *(control as *const *const PipelineManagerControlVtbl);
    let hr = ((*vtbl).filter_finished)(control);
    trace(&format!("  [filter_finished] hr=0x{:08X}", hr));
    hr
}

// ======== The filter object ========

#[repr(C)]
struct Filter {
    vtbl: *const FilterVtbl,
    refs: AtomicI32,
    comm: *mut c_void,
    property_bag: *mut c_void,
    control: *mut c_void,
    reader: *mut c_void,
    writer: *mut c_void,
}

#[repr(C)]
struct FilterVtbl {
    query_interface: unsafe extern "system" fn(*mut Filter, *const Guid, *mut *mut c_void) -> i32,
    add_ref: unsafe extern "system" fn(*mut Filter) -> u32,
    release: unsafe extern "system" fn(*mut Filter) -> u32,
    initialize_filter: unsafe extern "system" fn(*mut Filter, *mut c_void, *mut c_void, *mut c_void) -> i32,
    shutdown_operation: unsafe extern "system" fn(*mut Filter) -> i32,
    start_operation: unsafe extern "system" fn(*mut Filter) -> i32,
}

static FILTER_VTBL: FilterVtbl = FilterVtbl {
    query_interface: filter_query_interface,
    add_ref: filter_add_ref,
    release: filter_release,
    initialize_filter: filter_initialize,
    shutdown_operation: filter_shutdown,
    start_operation: filter_start_operation,
};

static JOB_COUNTER: AtomicU64 = AtomicU64::new(0);

fn spool_dir() -> Option<PathBuf> {
    let program_data = std::env::var("PROGRAMDATA")
        .ok()
        .filter(|p| !p.is_empty())
        .unwrap_or_else(|| "C:\\ProgramData".to_string());
    Some(PathBuf::from(program_data).join("Anuvadini").join("printjobs"))
}

unsafe extern "system" fn filter_query_interface(
    this: *mut Filter,
    riid: *const Guid,
    ppv: *mut *mut c_void,
) -> i32 {
    if ppv.is_null() {
        return E_POINTER;
    }
    *ppv = std::ptr::null_mut();
    if this.is_null() {
        return E_POINTER;
    }
    if guid_eq(riid, &IID_IUNKNOWN) || guid_eq(riid, &IID_IPRINT_PIPELINE_FILTER) {
        (*this).refs.fetch_add(1, Ordering::Relaxed);
        *ppv = this as *mut c_void;
        return S_OK;
    }
    E_NOINTERFACE
}

unsafe extern "system" fn filter_add_ref(this: *mut Filter) -> u32 {
    if this.is_null() {
        return 0;
    }
    let n = (*this).refs.fetch_add(1, Ordering::Relaxed) + 1;
    n as u32
}

unsafe extern "system" fn filter_release(this: *mut Filter) -> u32 {
    if this.is_null() {
        return 0;
    }
    let remaining = (*this).refs.fetch_sub(1, Ordering::Relaxed) - 1;
    if remaining <= 0 {
        drop(Box::from_raw(this));
        return 0;
    }
    remaining as u32
}

unsafe extern "system" fn filter_initialize(
    this: *mut Filter,
    negotiation: *mut c_void,
    property_bag: *mut c_void,
    control: *mut c_void,
) -> i32 {
    if this.is_null() {
        return E_POINTER;
    }
    let f = &mut *this;
    trace("filter_initialize called");
    trace_ptr("  negotiation", negotiation);
    trace_ptr("  property_bag", property_bag);
    trace_ptr("  control", control);
    trace_ptr_slots("  [init] negotiation vtbl", negotiation);
    trace_ptr_slots("  [init] property_bag vtbl", property_bag);
    trace_ptr_slots("  [init] control vtbl", control);
    f.comm = negotiation;
    f.property_bag = property_bag;
    f.control = control;
    if !negotiation.is_null() {
        comm_add_ref(negotiation);
    }
    if !property_bag.is_null() {
        obj_add_ref(property_bag);
    }
    if !control.is_null() {
        obj_add_ref(control);
    }
    trace("  addref'd negotiation/property_bag/control");

    let mut reader: *mut c_void = std::ptr::null_mut();
    let rhr = comm_request_reader(negotiation, &mut reader);
    trace(&format!("  [init] RequestReader hr=0x{:08X} reader={:p}", rhr, reader));
    if rhr == S_OK {
        f.reader = reader;
    } else {
        f.reader = std::ptr::null_mut();
        return rhr;
    }

    let mut writer: *mut c_void = std::ptr::null_mut();
    let whr = comm_request_writer(negotiation, &mut writer);
    trace(&format!("  [init] RequestWriter hr=0x{:08X} writer={:p}", whr, writer));
    if whr == S_OK && !writer.is_null() {
        f.writer = writer;
    } else {
        f.writer = std::ptr::null_mut();
    }

    trace("  init streams acquired");
    S_OK
}

unsafe extern "system" fn filter_shutdown(this: *mut Filter) -> i32 {
    if this.is_null() {
        return E_POINTER;
    }
    let f = &mut *this;
    trace("filter_shutdown called");
    if !f.comm.is_null() {
        comm_release(f.comm);
    }
    if !f.property_bag.is_null() {
        obj_release(f.property_bag);
    }
    if !f.control.is_null() {
        obj_release(f.control);
    }
    f.comm = std::ptr::null_mut();
    f.property_bag = std::ptr::null_mut();
    f.control = std::ptr::null_mut();
    f.reader = std::ptr::null_mut();
    f.writer = std::ptr::null_mut();
    trace("  released interfaces");
    S_OK
}

unsafe extern "system" fn filter_start_operation(this: *mut Filter) -> i32 {
    if this.is_null() {
        return E_POINTER;
    }
    let f = &*this;

    trace("filter_start_operation called");
    trace_ptr("  comm", f.comm);
    trace_ptr("  control", f.control);

    let dir = match spool_dir() {
        Some(d) => d,
        None => return ERROR_FILE_NOT_FOUND,
    };
    if let Err(_) = fs::create_dir_all(&dir) {
        return ERROR_ACCESS_DENIED;
    }

    let reader = f.reader;
    if reader.is_null() {
        trace("  [startop] reader is null");
        return E_FAIL;
    }
    let writer = f.writer;
    let has_writer = !writer.is_null();

    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let seq = JOB_COUNTER.fetch_add(1, Ordering::Relaxed);
    let tmp_path = dir.join(format!("job_{}_{}.tmp", now, seq));
    let prn_path = dir.join(format!("job_{}_{}.prn", now, seq));

    let mut file = match fs::File::create(&tmp_path) {
        Ok(f) => f,
        Err(_) => return ERROR_ACCESS_DENIED,
    };

    let mut buf = [0u8; 65536];
    let mut hr: i32;
    let mut iters: u32 = 0;
    loop {
        let mut read: u32 = 0;
        let mut eof: i32 = 0;
        iters += 1;
        if iters % 64 == 1 {
            trace(&format!("  [loop] iter {}", iters));
        }
        hr = read_stream_read_bytes(
            reader,
            buf.as_mut_ptr() as *mut c_void,
            buf.len() as u32,
            &mut read,
            &mut eof,
        );
        if hr != S_OK {
            break;
        }
        if read > 0 {
            use std::io::Write;
            if let Err(_) = file.write_all(&buf[..read as usize]) {
                hr = ERROR_ACCESS_DENIED;
                break;
            }
            if has_writer {
                let mut written: u32 = 0;
                let whr = write_stream_write_bytes(writer, buf.as_ptr() as *const c_void, read, &mut written);
                if whr != S_OK {
                    hr = whr;
                    break;
                }
            }
        }
        if eof != 0 || read == 0 {
            break;
        }
    }
    drop(file);

    trace(&format!("  [startop] loop ended iters={} hr=0x{:08X}", iters, hr));
    if hr == S_OK {
        let rn = fs::rename(&tmp_path, &prn_path);
        trace(&format!("  [startop] rename ok={}", rn.is_ok()));
        if has_writer {
            write_stream_close(writer);
        }
        let _ = pipeline_control_filter_finished(f.control);
    } else {
        let _ = fs::remove_file(&tmp_path);
    }
    trace(&format!("  [startop] returning hr=0x{:08X}", hr));
    hr
}

// ======== Class factory ========

#[repr(C)]
struct ClassFactory {
    vtbl: *const FactoryVtbl,
    refs: AtomicI32,
}

#[repr(C)]
struct FactoryVtbl {
    query_interface: unsafe extern "system" fn(*mut ClassFactory, *const Guid, *mut *mut c_void) -> i32,
    add_ref: unsafe extern "system" fn(*mut ClassFactory) -> u32,
    release: unsafe extern "system" fn(*mut ClassFactory) -> u32,
    create_instance: unsafe extern "system" fn(*mut ClassFactory, *mut c_void, *const Guid, *mut *mut c_void) -> i32,
    lock_server: unsafe extern "system" fn(*mut ClassFactory, i32) -> i32,
}

static FACTORY_VTBL: FactoryVtbl = FactoryVtbl {
    query_interface: factory_query_interface,
    add_ref: factory_add_ref,
    release: factory_release,
    create_instance: factory_create_instance,
    lock_server: factory_lock_server,
};

unsafe extern "system" fn factory_query_interface(
    this: *mut ClassFactory,
    riid: *const Guid,
    ppv: *mut *mut c_void,
) -> i32 {
    if ppv.is_null() {
        return E_POINTER;
    }
    *ppv = std::ptr::null_mut();
    if this.is_null() {
        return E_POINTER;
    }
    if guid_eq(riid, &IID_IUNKNOWN) || guid_eq(riid, &IID_ICLASSFACTORY) {
        (*this).refs.fetch_add(1, Ordering::Relaxed);
        *ppv = this as *mut c_void;
        return S_OK;
    }
    E_NOINTERFACE
}

unsafe extern "system" fn factory_add_ref(this: *mut ClassFactory) -> u32 {
    if this.is_null() {
        return 0;
    }
    ((*this).refs.fetch_add(1, Ordering::Relaxed) + 1) as u32
}

unsafe extern "system" fn factory_release(this: *mut ClassFactory) -> u32 {
    if this.is_null() {
        return 0;
    }
    let remaining = (*this).refs.fetch_sub(1, Ordering::Relaxed) - 1;
    if remaining <= 0 {
        drop(Box::from_raw(this));
        return 0;
    }
    remaining as u32
}

unsafe extern "system" fn factory_create_instance(
    this: *mut ClassFactory,
    outer: *mut c_void,
    riid: *const Guid,
    ppv: *mut *mut c_void,
) -> i32 {
    if ppv.is_null() {
        return E_POINTER;
    }
    *ppv = std::ptr::null_mut();
    if this.is_null() {
        return E_POINTER;
    }
    if !outer.is_null() {
        return CLASS_E_NOAGGREGATION;
    }
    let filter = Box::new(Filter {
        vtbl: &FILTER_VTBL,
        refs: AtomicI32::new(1),
        comm: std::ptr::null_mut(),
        property_bag: std::ptr::null_mut(),
        control: std::ptr::null_mut(),
        reader: std::ptr::null_mut(),
        writer: std::ptr::null_mut(),
    });
    let ptr = Box::into_raw(filter);
    if guid_eq(riid, &IID_IUNKNOWN) || guid_eq(riid, &IID_IPRINT_PIPELINE_FILTER) {
        (*ptr).refs.fetch_add(1, Ordering::Relaxed);
        *ppv = ptr as *mut c_void;
        S_OK
    } else {
        drop(Box::from_raw(ptr));
        E_NOINTERFACE
    }
}

unsafe extern "system" fn factory_lock_server(this: *mut ClassFactory, _lock: i32) -> i32 {
    if this.is_null() {
        return E_POINTER;
    }
    S_OK
}

// ======== DLL exports ========

#[no_mangle]
pub unsafe extern "system" fn DllGetClassObject(
    rclsid: *const Guid,
    riid: *const Guid,
    ppv: *mut *mut c_void,
) -> i32 {
    if ppv.is_null() {
        return E_POINTER;
    }
    *ppv = std::ptr::null_mut();
    trace("DllGetClassObject called");
    trace_ptr("  rclsid", rclsid as *const c_void);
    trace_ptr("  riid", riid as *const c_void);
    if rclsid.is_null() || !guid_eq(rclsid, &FILTER_CLSID) {
        return CLASS_E_CLASSNOTAVAILABLE;
    }
    let factory = Box::new(ClassFactory {
        vtbl: &FACTORY_VTBL,
        refs: AtomicI32::new(1),
    });
    let ptr = Box::into_raw(factory);
    if guid_eq(riid, &IID_IUNKNOWN) || guid_eq(riid, &IID_ICLASSFACTORY) {
        (*ptr).refs.fetch_add(1, Ordering::Relaxed);
        *ppv = ptr as *mut c_void;
        S_OK
    } else {
        drop(Box::from_raw(ptr));
        E_NOINTERFACE
    }
}

#[no_mangle]
pub extern "system" fn DllCanUnloadNow() -> i32 {
    S_FALSE
}
