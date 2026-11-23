use std::process::ExitCode;

enum Exit {
    Success = 0,
}

impl From<Exit> for ExitCode {
    fn from(value: Exit) -> Self {
        ExitCode::from(value as u8)
    }
}

enum Error {}

fn main() -> ExitCode {
    println!("Hello, world!");
    match run() {
        Ok(()) => Exit::Success,
    }
    .into()
}

fn run() -> Result<(), Error> {
    Ok(())
}
