use std::io::{self, Write};

pub const PLUGIN_PROTOCOL: u32 = 0;

const VERSION: &str = env!("REGINALD_VERSION");
const TARGET: &str = env!("REGINALD_TARGET");
const BUILD_HOST: &str = env!("REGINALD_BUILD_HOST");
const COMMIT_HASH: Option<&str> = option_env!("REGINALD_COMMIT_HASH");
const COMMIT_DATE: Option<&str> = option_env!("REGINALD_COMMIT_DATE");

pub fn print(verbose: bool) -> io::Result<()> {
    let mut out = io::stdout().lock();
    let short_hash = COMMIT_HASH.map(|s| &s[..7]);

    match (short_hash, COMMIT_DATE) {
        (Some(hash), Some(date)) => writeln!(out, "reginald {VERSION} ({hash} {date})")?,
        (Some(hash), None) => writeln!(out, "reginald {VERSION} ({hash})")?,
        _ => writeln!(out, "reginald {VERSION}")?,
    }

    if !verbose {
        return Ok(());
    }

    if let Some(s) = COMMIT_HASH {
        writeln!(out, "commit-hash: {s}")?;
    }

    if let Some(d) = COMMIT_DATE {
        writeln!(out, "commit-date: {d}")?;
    }

    writeln!(out, "host: {TARGET}")?;

    if BUILD_HOST != TARGET {
        writeln!(out, "build-host: {BUILD_HOST}")?;
    }

    writeln!(out, "profile: {}", env!("REGINALD_PROFILE"))?;
    writeln!(out, "rustc: {}", env!("REGINALD_RUSTC_VERSION"))?;
    writeln!(out, "plugin-protocol: {PLUGIN_PROTOCOL}")

    // TODO: If we some day want to add runtime OS info:
    // writeln!(out, "os: {}", os_info::get())
}
