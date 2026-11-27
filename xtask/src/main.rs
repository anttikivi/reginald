#![expect(clippy::exit, clippy::unwrap_used, reason = "dev tooling")]

use std::{
    env,
    path::Path,
    process::{self, Command},
};

const REUSE: &str = "--from=reuse[charset-normalizer]==6.3.0";

type Result<T = ()> = std::result::Result<T, Box<dyn std::error::Error>>;

fn main() {
    if let Err(e) = run() {
        eprintln!("xtask: {e}");
        process::exit(1)
    }
}

#[expect(
    clippy::single_match_else,
    reason = "subcommand dispatch will grow more arms"
)]
fn run() -> Result {
    let mut it = env::args().skip(1);
    match it.next().as_deref() {
        Some("reuse") => sh("uvx", &[REUSE, "reuse", "lint"]),
        _ => {
            eprintln!("usage: cargo xtask <reuse>");
            process::exit(2)
        }
    }
}

fn sh(prog: &str, args: &[&str]) -> Result {
    eprintln!("+ {prog} {}", args.join(" "));
    let status = Command::new(prog)
        .args(args)
        .current_dir(Path::new(env!("CARGO_MANIFEST_DIR")).parent().unwrap())
        .status()?;
    if !status.success() {
        return Err(format!("`{prog}` failed with {status}").into());
    }
    Ok(())
}
