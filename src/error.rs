use std::{
    io::{self, ErrorKind},
    process::ExitCode,
};

use thiserror::Error;

#[derive(Debug, Error)]
pub enum Error {
    #[error("failed to write")]
    Write(#[source] io::Error),
}

impl Error {
    pub fn exit_code(&self) -> ExitCode {
        match self {
            Self::Write(e) if e.kind() == ErrorKind::BrokenPipe => ExitCode::SUCCESS,
            Self::Write(_) => ExitCode::FAILURE,
        }
    }
}
