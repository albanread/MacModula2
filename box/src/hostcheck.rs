//! m2-hostcheck TRIPLE LIBRARY OUTDIR FILE.mod...: each program compiled
//! by the box's front end and code generator for TRIPLE (as the box's JIT
//! makes code) into OUTDIR/NAME.o. box/hostcheck.sh runs it for the Intel
//! box's x86_64-unknown-linux-musl and checks the objects.
fn main() {
    let a: Vec<String> = std::env::args().collect();
    if a.len() < 5 {
        eprintln!("usage: m2-hostcheck TRIPLE LIBRARY OUTDIR FILE.mod...");
        std::process::exit(2);
    }
    let mut bad = 0;
    for f in &a[4..] {
        let p = std::path::Path::new(f);
        let out = std::path::Path::new(&a[3]).join(format!("{}.o", p.file_stem().unwrap().to_string_lossy()));
        match newm2_box::host_emit(p, std::path::Path::new(&a[2]), &a[1], &out) {
            Ok(()) => println!("ok {}", out.display()),
            Err(e) => {
                println!("FAIL {f}: {e}");
                bad += 1;
            }
        }
    }
    std::process::exit(if bad == 0 { 0 } else { 1 });
}
