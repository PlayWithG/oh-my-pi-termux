use std::env;

fn main() {
    if env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("android") {
        // Termux ships libopus as a shared Bionic library. The upstream
        // audiopus_sys build script has no Android cfg branch and fails before
        // it can select a linker mode, so Android uses the stable C ABI directly.
        println!("cargo:rustc-link-lib=dylib=opus");
    }
}
