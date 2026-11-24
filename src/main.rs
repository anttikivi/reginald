mod args;
mod error;

use std::{
    env, fmt,
    io::{self, Write},
    process::ExitCode,
};

use semver::{BuildMetadata, Version};

use crate::error::Error;

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            report(&e);
            e.exit_code()
        }
    }
}

fn run() -> Result<(), Error> {
    let version = Version::parse(env!("REGINALD_VERSION")).unwrap_or_else(|e| {
        panic!(
            "failed to parse the embedded version; Reginald must be built with a valid version: {e}"
        )
    });

    let args = args::parse(env::args_os().skip(1))?;

    if args.help.unwrap_or(false) {
        println!("{}", args::HELP_MESSAGE);
        return Ok(());
    }

    if args.version.unwrap_or(false) {
        let commit_hash = option_env!("REGINALD_VERSION_COMMIT_HASH");
        let commit_short_hash = option_env!("REGINALD_VERSION_COMMIT_SHORT_HASH");
        let commit_date = option_env!("REGINALD_VERSION_COMMIT_DATE");
        let release = Version {
            build: BuildMetadata::EMPTY,
            ..version.clone()
        };

        match commit_short_hash.zip(commit_date) {
            Some((hash, date)) => print_line(format_args!("versolve {release} ({hash} {date})"))?,
            None => print_line(format_args!("versolve {release}"))?,
        }

        if args.verbose.unwrap_or(false) {
            print_line("binary: versolve")?;
            print_line(format_args!(
                "commit-hash: {}",
                commit_hash.unwrap_or("unknown")
            ))?;
            print_line(format_args!(
                "commit-date: {}",
                commit_date.unwrap_or("unknown")
            ))?;
            print_line(format_args!("host: {}", env!("REGINALD_HOST")))?;
            print_line(format_args!("release: {version}"))?;
        }
    }

    Ok(())
}

fn report(e: &dyn std::error::Error) {
    use std::fmt::Write;

    let mut line = e.to_string();
    let mut cur = e.source();
    while let Some(e) = cur {
        let _ = write!(line, ": {e}");
        cur = e.source();
    }
    eprintln!("{line}");
}

fn print_line(line: impl fmt::Display) -> Result<(), Error> {
    writeln!(io::stdout().lock(), "{line}").map_err(|e| e.into())
}
