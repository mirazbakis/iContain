// Mac-side check of the guest pipeline: import an app, load a .p12, sign with it.
// cargo run --example sign_test -- <input> <dest dir> <p12> [password] [platform]
use std::ffi::{c_char, CStr, CString};
use std::ptr;

extern "C" {
    fn icontain_prepare_guest(
        input: *const c_char,
        dest: *const c_char,
        platform: u32,
        out: *mut *mut c_char,
    ) -> i32;
    fn icontain_identity_import_p12(
        path: *const c_char,
        password: *const c_char,
        out: *mut *mut c_char,
    ) -> i32;
    fn icontain_install_session_new() -> *mut std::ffi::c_void;
    fn icontain_sign_guest(
        s: *mut std::ffi::c_void,
        app: *const c_char,
        mode: i32,
        a: *const c_char,
        p: *const c_char,
        an: *const c_char,
        pc: *const std::ffi::c_void,
        pr: *const std::ffi::c_void,
        ctx: *mut std::ffi::c_void,
        out: *mut *mut c_char,
    ) -> i32;
}

fn take(p: *mut c_char) -> String {
    if p.is_null() {
        String::new()
    } else {
        unsafe { CStr::from_ptr(p).to_string_lossy().into_owned() }
    }
}

fn main() {
    let _ = icontain_ffi::touch;
    let args: Vec<String> = std::env::args().collect();
    let c = |s: &str| CString::new(s).unwrap();
    let (input, dest, p12) = (c(&args[1]), c(&args[2]), c(&args[3]));
    let password = c(args.get(4).map(String::as_str).unwrap_or(""));
    let platform: u32 = args.get(5).and_then(|s| s.parse().ok()).unwrap_or(7);
    unsafe {
        let mut out = ptr::null_mut();
        let rc = icontain_prepare_guest(input.as_ptr(), dest.as_ptr(), platform, &mut out);
        let info = take(out);
        println!("prepare: {rc} {info}");
        if rc != 0 {
            std::process::exit(1)
        }
        let app = serde_json::from_str::<serde_json::Value>(&info).unwrap()["appPath"]
            .as_str()
            .unwrap()
            .to_string();
        let mut out = ptr::null_mut();
        let rc = icontain_identity_import_p12(p12.as_ptr(), password.as_ptr(), &mut out);
        println!("p12: {rc} {}", take(out));
        if rc != 0 {
            std::process::exit(1)
        }
        let session = icontain_install_session_new();
        let mut out = ptr::null_mut();
        let rc = icontain_sign_guest(
            session,
            c(&app).as_ptr(),
            1,
            ptr::null(),
            ptr::null(),
            ptr::null(),
            ptr::null(),
            ptr::null(),
            ptr::null_mut(),
            &mut out,
        );
        println!("sign: {rc} {}", take(out));
        println!("app: {app}");
    }
}
