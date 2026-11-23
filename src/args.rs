use std::{ffi::OsString, fmt, path::PathBuf};

#[derive(Default)]
pub struct Args {
    help: Option<bool>,
    version: Option<bool>,
    working_dir: Option<PathBuf>,
}

#[derive(Debug)]
pub enum Error {
    UnknownArgument(OsString),
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::UnknownArgument(s) => {
                write!(f, "unknown command-line argument: {}", s.to_string_lossy())
            }
        }
    }
}

impl std::error::Error for Error {}

pub fn parse<I>(_argv: I) -> Result<Args, Error>
where
    I: IntoIterator<Item = OsString>,
{
    Err(Error::UnknownArgument("test-arg".into()))
}
