mod args;
mod error;

use std::{env, process::ExitCode};

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
    let args = args::parse(env::args_os().skip(1))?;

    if args.help.unwrap_or(false) {
        println!("{}", args::HELP_MESSAGE);
        return Ok(());
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
