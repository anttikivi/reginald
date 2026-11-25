mod cli;
mod error;
mod logger;
mod version;

use std::process::ExitCode;

use clap::Parser;
use log::debug;

use crate::{cli::Cli, error::Error};

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(_e) => {
            ExitCode::FAILURE
            // report(&e);
            // e.exit_code()
        }
    }
}

fn run() -> Result<(), Box<dyn std::error::Error>> {
    let cli = Cli::parse();

    if cli.version {
        version::print(cli.verbose > 0)?;
        return Ok(());
    }

    // TODO: Cloning is stupid.
    let level = logger::resolve_level_filter(cli.log_level.clone(), cli.verbose, cli.quiet)?;
    logger::init(level);

    debug!("parsed arguments: {cli:?}");

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
