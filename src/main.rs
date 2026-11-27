mod cli;
mod config;
mod error;
mod logger;
mod version;

use std::{env, process::ExitCode};

use clap::Parser;
use log::{debug, info, warn};

use crate::{cli::Cli, config::Config, error::Error};

fn main() -> ExitCode {
    logger::init();
    let result = run();
    logger::finish_buffering();
    match result {
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

    debug!("parsed arguments: {cli:#?}");

    if cli.version {
        return version::print(cli.verbose > 0).map_err(Error::Write);
    }

    for wd in config::working_directories(&cli, |s| env::var_os(s)) {
        debug!("changing directory to {}", wd.display());
        env::set_current_dir(&wd).map_err(|e| Error::Chdir {
            path: wd.clone(),
            source: e,
        })?;
    }

    info!("running reginald {}", version::VERSION);

    match env::current_dir() {
        Ok(p) => info!("current directory is {}", p.display()),
        Err(e) => warn!("failed to read the current directory: {e}"),
    }

    if let Some(date) = version::COMMIT_DATE {
        debug!("commit date: {date}");
    }

    if let Some(hash) = version::COMMIT_HASH {
        debug!("commit: {hash}");
    }

    debug!("plugin protocol version: {}", version::PLUGIN_PROTOCOL);

    let (config_data, config_path) = config::read_file(config::file(&cli, |s| env::var_os(s)))?;
    let config = Config::new(&config_data, &config_path, &cli, |name| env::var_os(name))?;

    debug!("parsed config: {config:#?}");

    logger::set_level(config.log_level);

    logger::finish_buffering();

    Ok(())
}

fn report(e: &dyn std::error::Error) {
    use std::fmt::Write;

    let mut line = e.to_string();
    let mut cur = e.source();
    while let Some(source) = cur {
        let _ = write!(line, ": {source}");
        cur = source.source();
    }
    eprintln!("{line}");
}
