//! 把 `app.manifest` 嵌进最终的 exe（见清单文件里的注释：视觉样式与 DPI）。
//!
//! 只在 MSVC 链接器上做 —— CI 的真机构建就是 MSVC；开发机上的
//! `cargo check --target x86_64-pc-windows-gnu` 不链接，这些参数用不上，
//! GNU 的 ld 也不认 `/MANIFEST` 这种写法。

fn main() {
    let target_env = std::env::var("CARGO_CFG_TARGET_ENV").unwrap_or_default();
    if target_env == "msvc" {
        let manifest = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("app.manifest");
        println!("cargo:rustc-link-arg-bins=/MANIFEST:EMBED");
        println!("cargo:rustc-link-arg-bins=/MANIFESTINPUT:{}", manifest.display());
    }
    println!("cargo:rerun-if-changed=app.manifest");
}
