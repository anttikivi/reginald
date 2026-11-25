mod cli;
mod error;
mod logger;
mod version;

use std::process::ExitCode;

use clap::Parser;
use log::{debug, info};

use crate::{cli::Cli, error::Error};

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) if e.exit_code() == ExitCode::SUCCESS => e.exit_code(),
        Err(e) => {
            report(&e);
            e.exit_code()
        }
    }
}

fn run() -> Result<(), Error> {
    let cli = Cli::parse();

    if cli.version {
        return version::print(cli.verbose > 0).map_err(Error::Write);
    }

    let level = logger::resolve_level_filter(cli.log_level.clone(), cli.verbose, cli.quiet);
    logger::init(level);

    debug!("parsed arguments: {cli:?}");
    info!("running reginald {}", version::VERSION);

    if let Some(date) = version::COMMIT_DATE {
        debug!("commit date: {date}");
    }

    if let Some(hash) = version::COMMIT_DATE {
        debug!("commit: {hash}");
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
