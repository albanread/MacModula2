//! Sprint L — ahead-of-time (`.exe`) build end-to-end tests.

use std::path::PathBuf;
use std::process::Command;

fn build_and_run(stem: &str, expect_success: bool) -> Result<String, String> {
    let driver = env!("CARGO_BIN_EXE_newm2-driver");
    let manifest = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let entry = manifest.join("../../Mod/tests").join(format!("{stem}.mod"));
    assert!(entry.is_file(), "fixture not found: {}", entry.display());

    let out_dir = std::env::temp_dir().join("newm2-aot-tests");
    std::fs::create_dir_all(&out_dir).expect("create temp out dir");
    let exe = out_dir.join(format!("{stem}.exe"));

    let build = Command::new(driver)
        .arg("build")
        .arg(&entry)
        .arg("--out")
        .arg(&exe)
        .output()
        .expect("spawn newm2 build");
    if !build.status.success() {
        let stderr = String::from_utf8_lossy(&build.stderr);
        if stderr.contains("could not locate the MSVC linker")
            || stderr.contains("newm2_runtime.lib not found")
        {
            return Err(format!("skipped — AOT toolchain unavailable: {stderr}"));
        }
        panic!("newm2 build {stem} failed:\n{stderr}");
    }

    let run = Command::new(&exe)
        .output()
        .unwrap_or_else(|e| panic!("run {}: {e}", exe.display()));
    if expect_success {
        assert!(
            run.status.success(),
            "{stem}.exe exited with {}",
            run.status
        );
    }
    Ok(String::from_utf8_lossy(&run.stdout).replace("\r\n", "\n"))
}

macro_rules! aot_test {
    ($name:ident, $stem:literal, $expected:literal) => {
        #[test]
        fn $name() {
            match build_and_run($stem, true) {
                Ok(out) => assert_eq!(out, $expected),
                Err(skip) => eprintln!("{skip}"),
            }
        }
    };
}

aot_test!(aot_const_arith, "t-10-010-const-arith", "42\n");
aot_test!(
    aot_inheritance,
    "t-90-060-inheritance",
    "1\n2\n4\n9\n1\n2\n"
);
aot_test!(
    aot_method_except,
    "t-90-100-method-except",
    "5\n-1\n-1\n42\n8\n2\n"
);

#[test]
fn aot_termination() {
    match build_and_run("t-61-070-conf-termination", false) {
        Ok(out) => assert_eq!(out, "before\nhalted\n"),
        Err(skip) => eprintln!("{skip}"),
    }
}

#[cfg(windows)]
aot_test!(aot_com_server, "t-90-110-com-server", "1201\n1\n41\n");

aot_test!(
    aot_native_callback,
    "t-90-120-native-callback",
    "1 2 4 5 8 \n8 5 4 2 1 \n"
);
