use super::{common_enum, get_wstr_bytes, is_name_equal};
use hbb_common::{bail, log, ResultType};
use std::{io, ptr::null_mut, time::Duration};
use winapi::ctypes::c_void;
use winapi::{
    shared::{
        minwindef::{BOOL, DWORD, FALSE, LPBYTE, LPDWORD, MAX_PATH},
        ntdef::{DWORDLONG, LPCWSTR},
        winerror::{ERROR_UNKNOWN_PRINTER_DRIVER, S_OK},
    },
    um::{
        winspool::{
            DeletePrinterDriverExW, DeletePrinterDriverPackageW, EnumPrinterDriversW,
            InstallPrinterDriverFromPackageW, UploadPrinterDriverPackageW, DPD_DELETE_ALL_FILES,
            DRIVER_INFO_6W, DRIVER_INFO_8W, IPDFP_COPY_ALL_FILES, UPDP_SILENT_UPLOAD,
            UPDP_UPLOAD_ALWAYS,
        },
        winuser::GetForegroundWindow,
    },
};
use windows_strings::PCWSTR;

const HRESULT_ERR_ELEMENT_NOT_FOUND: u32 = 0x80070490;

// The v4 driver catalog is signed with this self-signed "Anuvadini" certificate.
// On a machine that does not trust the certificate, UploadPrinterDriverPackageW
// fails with CERT_E_UNTRUSTEDROOT (0x800B0109). Install the certificate into the
// LocalMachine "Root" store before uploading so the driver package can be verified.
const ANUVADINI_CERT_DER: &[u8] = &[
    0x30, 0x82, 0x02, 0xF8, 0x30, 0x82, 0x01, 0xE0, 0xA0, 0x03, 0x02, 0x01, 0x02, 0x02, 0x10, 0x51,
    0x70, 0x2A, 0x58, 0xB0, 0x80, 0x5F, 0xBA, 0x4F, 0x4F, 0xAF, 0xFA, 0x55, 0xED, 0xF8, 0xA6, 0x30,
    0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0B, 0x05, 0x00, 0x30, 0x14,
    0x31, 0x12, 0x30, 0x10, 0x06, 0x03, 0x55, 0x04, 0x03, 0x0C, 0x09, 0x41, 0x6E, 0x75, 0x76, 0x61,
    0x64, 0x69, 0x6E, 0x69, 0x30, 0x1E, 0x17, 0x0D, 0x32, 0x36, 0x30, 0x37, 0x33, 0x30, 0x30, 0x39,
    0x34, 0x32, 0x30, 0x37, 0x5A, 0x17, 0x0D, 0x33, 0x31, 0x30, 0x37, 0x33, 0x30, 0x30, 0x39, 0x35,
    0x32, 0x30, 0x35, 0x5A, 0x30, 0x14, 0x31, 0x12, 0x30, 0x10, 0x06, 0x03, 0x55, 0x04, 0x03, 0x0C,
    0x09, 0x41, 0x6E, 0x75, 0x76, 0x61, 0x64, 0x69, 0x6E, 0x69, 0x30, 0x82, 0x01, 0x22, 0x30, 0x0D,
    0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01, 0x05, 0x00, 0x03, 0x82, 0x01,
    0x0F, 0x00, 0x30, 0x82, 0x01, 0x0A, 0x02, 0x82, 0x01, 0x01, 0x00, 0xDB, 0x9B, 0x2F, 0x46, 0x1B,
    0x68, 0x0F, 0x54, 0xE3, 0x2D, 0xD5, 0xC8, 0xEE, 0x36, 0x77, 0xBB, 0x20, 0xCA, 0x65, 0xDD, 0xBC,
    0xD1, 0x91, 0x37, 0x13, 0x43, 0xA2, 0x6F, 0xC8, 0xEA, 0x69, 0x01, 0x5E, 0xBA, 0x25, 0xA7, 0x1B,
    0xF8, 0x16, 0x18, 0x2D, 0xAA, 0x7E, 0xEE, 0xF6, 0x63, 0x21, 0x5E, 0x38, 0x70, 0x27, 0xE9, 0xEE,
    0x67, 0x77, 0x14, 0x99, 0x62, 0x50, 0xD6, 0x24, 0x62, 0x8B, 0x97, 0x73, 0x25, 0x08, 0x84, 0x7C,
    0x7E, 0x9F, 0xE8, 0xF5, 0x2B, 0x6F, 0x4D, 0x44, 0x77, 0x3D, 0x55, 0xD5, 0x34, 0x1F, 0x79, 0x7C,
    0x1C, 0x2A, 0x88, 0x71, 0xF9, 0x91, 0xAB, 0x69, 0xA7, 0x89, 0x6B, 0x5D, 0x93, 0x6D, 0xE4, 0x23,
    0xED, 0x39, 0xCD, 0xED, 0x04, 0x65, 0xC7, 0xC4, 0x2A, 0x5D, 0xC3, 0x2F, 0xE7, 0x6D, 0x29, 0xA6,
    0x62, 0xFE, 0x31, 0x36, 0xAA, 0xCC, 0xBF, 0xFD, 0xDC, 0xD9, 0xEC, 0xB3, 0x22, 0x8A, 0x37, 0x3F,
    0x6F, 0xAC, 0x66, 0x07, 0x1B, 0x09, 0xE9, 0x2E, 0x1B, 0xE5, 0xF4, 0x7B, 0x0B, 0xD0, 0x17, 0x0B,
    0xE2, 0x0A, 0x08, 0xA0, 0xBB, 0xE6, 0xD9, 0xC2, 0x37, 0x7F, 0x22, 0x93, 0xBA, 0x30, 0xE5, 0xA2,
    0x1C, 0xFF, 0x06, 0xF8, 0x91, 0x02, 0x5E, 0x9C, 0x30, 0x3F, 0xDB, 0x3E, 0x1B, 0x55, 0x31, 0xEC,
    0x75, 0x30, 0x19, 0x1F, 0x13, 0x0F, 0xCD, 0x7A, 0xAE, 0x63, 0x88, 0xD4, 0x3C, 0x07, 0xC5, 0xCE,
    0xA7, 0xF3, 0x0E, 0x18, 0xEF, 0x21, 0xFD, 0x0D, 0x23, 0x10, 0x92, 0xC8, 0x6A, 0xED, 0x32, 0xB1,
    0x05, 0xA1, 0x58, 0xF1, 0x37, 0xC1, 0x24, 0x67, 0x48, 0xE2, 0xB4, 0xB8, 0x03, 0x92, 0xD6, 0xD3,
    0x8A, 0x9B, 0x8D, 0x6E, 0x9E, 0x2C, 0x41, 0x84, 0xB1, 0x6E, 0x29, 0x85, 0x3C, 0x13, 0xE7, 0x87,
    0xC6, 0x67, 0x63, 0x4D, 0xB9, 0xC9, 0x45, 0xB4, 0x2D, 0xCC, 0x11, 0x02, 0x03, 0x01, 0x00, 0x01,
    0xA3, 0x46, 0x30, 0x44, 0x30, 0x0E, 0x06, 0x03, 0x55, 0x1D, 0x0F, 0x01, 0x01, 0xFF, 0x04, 0x04,
    0x03, 0x02, 0x07, 0x80, 0x30, 0x13, 0x06, 0x03, 0x55, 0x1D, 0x25, 0x04, 0x0C, 0x30, 0x0A, 0x06,
    0x08, 0x2B, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x03, 0x30, 0x1D, 0x06, 0x03, 0x55, 0x1D, 0x0E,
    0x04, 0x16, 0x04, 0x14, 0x70, 0xB0, 0xA5, 0x6B, 0x94, 0xD1, 0x82, 0xC0, 0x0B, 0x4B, 0x17, 0xEC,
    0xE2, 0xE0, 0xE6, 0x27, 0x1E, 0x17, 0x38, 0xEE, 0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86,
    0xF7, 0x0D, 0x01, 0x01, 0x0B, 0x05, 0x00, 0x03, 0x82, 0x01, 0x01, 0x00, 0xB0, 0xB0, 0x5D, 0xE6,
    0x21, 0x19, 0x8B, 0xE6, 0xFB, 0x4F, 0xA3, 0x37, 0xFC, 0x56, 0x54, 0x0E, 0x3A, 0xAA, 0x8F, 0xA8,
    0x55, 0xDE, 0x38, 0x50, 0xA1, 0x82, 0x29, 0x09, 0xC6, 0x10, 0xAC, 0xB1, 0x5D, 0x0A, 0x33, 0xC0,
    0xB8, 0x40, 0xC4, 0x7E, 0x72, 0x82, 0xD3, 0x48, 0xB5, 0xFB, 0xCA, 0xBB, 0x29, 0x44, 0x73, 0xF6,
    0xA5, 0x0E, 0xBF, 0x65, 0xEB, 0xE4, 0x10, 0xEC, 0x22, 0x03, 0x5C, 0xD5, 0x77, 0x77, 0xDB, 0xFC,
    0x0B, 0xD2, 0xF1, 0xCE, 0x67, 0x67, 0xEA, 0x43, 0x59, 0xA2, 0x79, 0x04, 0x6B, 0x1A, 0xCB, 0x04,
    0x67, 0xC7, 0x7E, 0xC7, 0x3F, 0x26, 0xA7, 0xE6, 0x54, 0x4A, 0xA7, 0x37, 0x74, 0xD7, 0x2A, 0x5A,
    0xB8, 0xE0, 0xD9, 0xF9, 0xD2, 0x52, 0x08, 0xBE, 0x47, 0x38, 0xAA, 0x11, 0x2D, 0xCF, 0xF6, 0x59,
    0xDA, 0xAC, 0xEF, 0xF5, 0x70, 0x7E, 0x9D, 0xFB, 0x72, 0x8A, 0x87, 0xDE, 0xFC, 0x1B, 0xE9, 0xE1,
    0x14, 0xC4, 0xBD, 0x8D, 0xCA, 0xAC, 0x65, 0x0F, 0x67, 0x59, 0xA1, 0xD1, 0xD6, 0x88, 0x8D, 0x33,
    0x04, 0xD1, 0x02, 0x58, 0xF3, 0xB8, 0x56, 0x88, 0x76, 0x44, 0xCC, 0x36, 0xB5, 0x2C, 0xB9, 0x26,
    0x59, 0x31, 0xD1, 0x8E, 0x05, 0x28, 0x37, 0x06, 0x56, 0x11, 0xD2, 0x1F, 0x3E, 0xAF, 0x2F, 0xB7,
    0x30, 0x57, 0xB4, 0xDA, 0x49, 0xC0, 0x5F, 0x39, 0xC4, 0xF6, 0x24, 0xCD, 0x8C, 0xBE, 0x71, 0xB2,
    0x0A, 0x36, 0x48, 0x22, 0x89, 0xA3, 0x86, 0xB9, 0xBD, 0x96, 0x35, 0xD4, 0x53, 0x9F, 0x32, 0xEC,
    0x36, 0x21, 0x85, 0xDC, 0x7F, 0x19, 0x0C, 0xB3, 0xE4, 0xFD, 0x4D, 0xE1, 0x19, 0x3E, 0x9C, 0x9B,
    0xEE, 0x2B, 0xEA, 0x6F, 0x7B, 0x06, 0xB9, 0x5C, 0x1C, 0x48, 0x22, 0xCC, 0xAA, 0xF0, 0x5B, 0x68,
    0x56, 0x1A, 0xBA, 0x5F, 0x8B, 0x3B, 0xEE, 0x9A, 0x23, 0x16, 0x5C, 0xA8,
];

fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(Some(0)).collect()
}

fn cert_in_store(store_name: &str) -> bool {
    use winapi::um::wincrypt::*;
    unsafe {
        let name = wide(store_name);
        let store = CertOpenStore(
            CERT_STORE_PROV_SYSTEM,
            0,
            0,
            CERT_SYSTEM_STORE_LOCAL_MACHINE | CERT_STORE_OPEN_EXISTING_FLAG,
            name.as_ptr() as *const c_void,
        );
        if store.is_null() {
            return false;
        }
        let ctx = CertCreateCertificateContext(
            X509_ASN_ENCODING,
            ANUVADINI_CERT_DER.as_ptr(),
            ANUVADINI_CERT_DER.len() as DWORD,
        );
        if ctx.is_null() {
            CertCloseStore(store, 0);
            return false;
        }
        let found = CertFindCertificateInStore(
            store,
            X509_ASN_ENCODING,
            0,
            CERT_FIND_EXISTING,
            ctx as *const c_void,
            null_mut(),
        );
        if !found.is_null() {
            CertFreeCertificateContext(found);
        }
        CertFreeCertificateContext(ctx);
        CertCloseStore(store, 0);
        !found.is_null()
    }
}

fn add_cert_to_store(store_name: &str) -> bool {
    use winapi::um::wincrypt::*;
    unsafe {
        let name = wide(store_name);
        let store = CertOpenStore(
            CERT_STORE_PROV_SYSTEM,
            0,
            0,
            CERT_SYSTEM_STORE_LOCAL_MACHINE | CERT_STORE_OPEN_EXISTING_FLAG,
            name.as_ptr() as *const c_void,
        );
        if store.is_null() {
            return false;
        }
        let ok = CertAddEncodedCertificateToStore(
            store,
            X509_ASN_ENCODING,
            ANUVADINI_CERT_DER.as_ptr(),
            ANUVADINI_CERT_DER.len() as DWORD,
            CERT_STORE_ADD_REPLACE_EXISTING,
            null_mut(),
        ) != FALSE;
        CertCloseStore(store, 0);
        ok
    }
}

fn add_cert_elevated() -> ResultType<()> {
    let path = std::env::temp_dir().join("anuvadini_cert.cer");
    std::fs::write(&path, ANUVADINI_CERT_DER)?;
    let res = runas::Command::new("certutil.exe")
        .args(&["-addstore", "Root", &path.to_string_lossy()])
        .show(false)
        .status();
    let _ = std::fs::remove_file(&path);
    match res {
        Ok(status) if status.success() => Ok(()),
        Ok(status) => bail!("certutil -addstore Root failed with exit status {}", status),
        Err(e) => bail!("Failed to run certutil elevated: {}", e),
    }
}

// Install the self-signed certificate into the LocalMachine trusted root store so
// that UploadPrinterDriverPackageW can verify the driver package signature.
pub fn ensure_cert_trusted() -> ResultType<()> {
    if cert_in_store("Root") {
        return Ok(());
    }
    if add_cert_to_store("Root") {
        return Ok(());
    }
    add_cert_elevated()?;
    if !cert_in_store("Root") {
        bail!("The Anuvadini driver certificate could not be installed into the trusted root store");
    }
    Ok(())
}

fn enum_printer_driver(
    level: DWORD,
    p_driver_info: LPBYTE,
    cb_buf: DWORD,
    pcb_needed: LPDWORD,
    pc_returned: LPDWORD,
) -> BOOL {
    unsafe {
        // https://learn.microsoft.com/en-us/windows/win32/printdocs/enumprinterdrivers
        // This is a blocking or synchronous function and might not return immediately.
        // How quickly this function returns depends on run-time factors
        // such as network status, print server configuration, and printer driver implementation factors that are difficult to predict when writing an application.
        // Calling this function from a thread that manages interaction with the user interface could make the application appear to be unresponsive.
        EnumPrinterDriversW(
            null_mut(),
            null_mut(),
            level,
            p_driver_info,
            cb_buf,
            pcb_needed,
            pc_returned,
        )
    }
}

pub fn get_installed_driver_version(name: &PCWSTR) -> ResultType<Option<DWORDLONG>> {
    common_enum(
        "EnumPrinterDriversW",
        enum_printer_driver,
        6,
        |info: &DRIVER_INFO_6W| {
            if is_name_equal(name, info.pName) {
                Some(info.dwlDriverVersion)
            } else {
                None
            }
        },
        || None,
    )
}

fn find_inf(name: &PCWSTR) -> ResultType<Vec<u16>> {
    let r = common_enum(
        "EnumPrinterDriversW",
        enum_printer_driver,
        8,
        |info: &DRIVER_INFO_8W| {
            if is_name_equal(name, info.pName) {
                Some(get_wstr_bytes(info.pszInfPath))
            } else {
                None
            }
        },
        || None,
    )?;
    Ok(r.unwrap_or(vec![]))
}

fn delete_printer_driver(name: &PCWSTR) -> ResultType<()> {
    unsafe {
        // If the printer is used after the spooler service is started. E.g., printing a document through Anuvadini Printer.
        // `DeletePrinterDriverExW()` may fail with `ERROR_PRINTER_DRIVER_IN_USE`(3001, 0xBB9).
        // We can only ignore this error for now.
        // Though restarting the spooler service is a solution, it's not a good idea to restart the service.
        //
        // Deleting the printer driver after deleting the printer is a common practice.
        // No idea why `DeletePrinterDriverExW()` fails with `ERROR_UNKNOWN_PRINTER_DRIVER` after using the printer once.
        // https://github.com/ChromiumWebApps/chromium/blob/c7361d39be8abd1574e6ce8957c8dbddd4c6ccf7/cloud_print/virtual_driver/win/install/setup.cc#L422
        // AnyDesk printer driver and the simplest printer driver also have the same issue.
        if FALSE
            == DeletePrinterDriverExW(
                null_mut(),
                null_mut(),
                name.as_ptr() as _,
                DPD_DELETE_ALL_FILES,
                0,
            )
        {
            let err = io::Error::last_os_error();
            if err.raw_os_error() == Some(ERROR_UNKNOWN_PRINTER_DRIVER as _) {
                return Ok(());
            } else {
                bail!("Failed to delete the printer driver, {}", err)
            }
        }
    }
    Ok(())
}

// https://github.com/dvalter/chromium-android-ext-dev/blob/dab74f7d5bc5a8adf303090ee25c611b4d54e2db/cloud_print/virtual_driver/win/install/setup.cc#L190
fn delete_printer_driver_package(inf: Vec<u16>) -> ResultType<()> {
    if inf.is_empty() {
        return Ok(());
    }
    let slen = if inf[inf.len() - 1] == 0 {
        inf.len() - 1
    } else {
        inf.len()
    };
    let inf_path = String::from_utf16_lossy(&inf[..slen]);
    if !std::path::Path::new(&inf_path).exists() {
        return Ok(());
    }

    let mut retries = 3;
    loop {
        unsafe {
            let res = DeletePrinterDriverPackageW(null_mut(), inf.as_ptr(), null_mut());
            if res == S_OK || res == HRESULT_ERR_ELEMENT_NOT_FOUND as i32 {
                return Ok(());
            }
            log::error!("Failed to delete the printer driver, result: {}", res);
        }
        retries -= 1;
        if retries <= 0 {
            bail!("Failed to delete the printer driver");
        }
        std::thread::sleep(Duration::from_secs(2));
    }
}

pub fn uninstall_driver(name: &PCWSTR) -> ResultType<()> {
    // Note: inf must be found before `delete_printer_driver()`.
    let inf = find_inf(name)?;
    delete_printer_driver(name)?;
    delete_printer_driver_package(inf)
}

pub fn install_driver(name: &PCWSTR, inf: LPCWSTR) -> ResultType<()> {
    // Log the INF path for debugging
    let inf_str = if !inf.is_null() {
        let len = (0..).take(2048).position(|i| unsafe { *inf.add(i) } == 0).unwrap_or(0);
        String::from_utf16_lossy(unsafe { std::slice::from_raw_parts(inf, len) })
    } else {
        "(null)".to_string()
    };
    log::info!("install_driver: INF path = '{}'", inf_str);

    // Verify files exist
    let base_dir = std::path::Path::new(&inf_str).parent().unwrap_or(std::path::Path::new("."));
    for f in &["printer_driver_adapter.dll", "anuvadiniprinterdriver.cat"] {
        let p = base_dir.join(f);
        log::info!("install_driver: {} exists = {}", p.display(), p.exists());
    }

    // The catalog is signed with the Anuvadini self-signed certificate. Make sure
    // it is trusted before uploading, otherwise the upload fails with
    // CERT_E_UNTRUSTEDROOT (0x800B0109).
    ensure_cert_trusted()?;

    let mut size = (MAX_PATH * 10) as u32;
    let mut package_path = [0u16; MAX_PATH * 10];
    unsafe {
        let mut res = UploadPrinterDriverPackageW(
            null_mut(),
            inf,
            null_mut(),
            UPDP_SILENT_UPLOAD | UPDP_UPLOAD_ALWAYS,
            null_mut(),
            package_path.as_mut_ptr(),
            &mut size as _,
        );
        if res != S_OK {
            log::error!(
                "Failed to upload the printer driver package to the driver cache silently, HRESULT=0x{:08X}. Will try with user UI.",
                res as u32
            );

            res = UploadPrinterDriverPackageW(
                null_mut(),
                inf,
                null_mut(),
                UPDP_UPLOAD_ALWAYS,
                GetForegroundWindow(),
                package_path.as_mut_ptr(),
                &mut size as _,
            );
            if res != S_OK {
                bail!(
                    "Failed to upload the printer driver package to the driver cache with UI, HRESULT=0x{:08X}",
                    res as u32
                );
            }
        }

        // https://learn.microsoft.com/en-us/windows/win32/printdocs/installprinterdriverfrompackage
        res = InstallPrinterDriverFromPackageW(
            null_mut(),
            package_path.as_ptr(),
            name.as_ptr(),
            null_mut(),
            IPDFP_COPY_ALL_FILES,
        );
        if res != S_OK {
            bail!("Failed to install the printer driver from package, {}", res);
        }
    }

    Ok(())
}
