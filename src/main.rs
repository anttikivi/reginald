mod args;
mod error;

use std::{env, process::ExitCode};

use crate::error::Error;

fn main() -> ExitCode {
    println!("Hello, world!");
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            report(&e);
            e.exit_code()
        }
    }
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

fn run() -> Result<(), Error> {
    let _ = args::parse(env::args_os().skip(1))?;
    Ok(())
}
