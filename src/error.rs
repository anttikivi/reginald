use std::{fmt, process::ExitCode};

use crate::args;

#[derive(Debug)]
pub enum Error {
    Args(args::Error),
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Args(e) => e.fmt(f),
        }
    }
}

impl From<args::Error> for Error {
    fn from(value: args::Error) -> Self {
        Self::Args(value)
    }
}

impl std::error::Error for Error {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Args(e) => e.source(),
        }
    }
}

impl Error {
    pub fn exit_code(&self) -> ExitCode {
        match self {
            Self::Args(_) => ExitCode::from(2),
        }
    }
}
