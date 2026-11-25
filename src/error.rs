use std::{
    io::{self, ErrorKind},
    process::ExitCode,
};

use thiserror::Error;

use crate::config;

#[derive(Debug, Error)]
pub enum Error {
    #[error(transparent)]
    Config(#[from] config::Error),
    #[error("failed to write")]
    Write(#[source] io::Error),
}

impl Error {
    pub fn exit_code(&self) -> ExitCode {
        match self {
            Self::Config(e) if matches!(e, config::Error::NoFile { searched: _ }) => {
                ExitCode::from(2) // essentially usage error
            }
            Self::Config(e) if matches!(e, config::Error::Read { path: _, source: _ }) => {
                ExitCode::FAILURE
            }
            Self::Config(_) => ExitCode::from(2), // essentially usage error
            Self::Write(e) if e.kind() == ErrorKind::BrokenPipe => ExitCode::SUCCESS,
            Self::Write(_) => ExitCode::FAILURE,
        }
    }
}
