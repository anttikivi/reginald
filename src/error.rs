use std::{
    io::{self, ErrorKind},
    path::PathBuf,
    process::ExitCode,
};

use thiserror::Error;

use crate::config;

#[derive(Debug, Error)]
pub enum Error {
    #[error("failed to change current directory to \"{path}\"")]
    Chdir {
        path: PathBuf,
        #[source]
        source: io::Error,
    },
    #[error(transparent)]
    Config(#[from] config::Error),
    #[error("failed to write")]
    Write(#[source] io::Error),
}

impl Error {
    pub fn exit_code(&self) -> ExitCode {
        match self {
            Self::Chdir { path: _, source: _ } => ExitCode::from(2),
            Self::Config(_) => ExitCode::from(2),
            Self::Write(e) if e.kind() == ErrorKind::BrokenPipe => ExitCode::SUCCESS,
            Self::Write(_) => ExitCode::FAILURE,
        }
    }
}
