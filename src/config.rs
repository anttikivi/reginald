use std::{
    env, fs,
    io::{self, ErrorKind},
    path::PathBuf,
    result,
};

use log::{info, trace};
use thiserror::Error;

const DIRECTORY_NAME: &str = "reginald";
const FILE_NAME: &str = "reginald.toml";
const IN_DIRECTORY_FILE_NAME: &str = "config.toml";

#[derive(Error, Debug)]
pub enum Error {
    #[error("no config file found, searched:{}", .searched.iter().map(|p| format!("\n  {}", p.display())).collect::<String>())]
    NoFile { searched: Vec<PathBuf> },
    #[error("failed to read config file {path}")]
    Read {
        path: PathBuf,
        #[source]
        source: io::Error,
    },
}

type Result<T> = result::Result<T, Error>;

pub fn read_file(path: Option<PathBuf>, cwd: PathBuf) -> Result<String> {
    if let Some(p) = path {
        trace!("trying user-supplied config file {}", p.display());
        let s = fs::read_to_string(&p).map_err(|e| Error::Read {
            path: p.clone(), // TODO: stupid clone?
            source: e,
        })?;
        info!("read config file from {}", p.display());
        return Ok(s);
    }

    let paths = search_paths(cwd);
    for path in &paths {
        trace!("trying config file {}", path.display());
        let s = fs::read_to_string(path);
        match s {
            Ok(s) => {
                info!("read config file from {}", path.display());
                return Ok(s);
            }
            Err(e) if e.kind() == ErrorKind::NotFound => {}
            Err(e) => {
                return Err(Error::Read {
                    path: path.to_path_buf(),
                    source: e,
                });
            }
        }
    }

    Err(Error::NoFile { searched: paths })
}

/// Creates a [`Vec`] of the defaults paths to look for the config file.
///
/// Currently assumes that everything that is not a Windows platform should
/// behave like a Linux or Unix platform.
fn search_paths(cwd: PathBuf) -> Vec<PathBuf> {
    let mut paths = vec![cwd.join(FILE_NAME)];

    // XDG_CONFIG_HOME must be absolute according to the spec.
    let xdg = env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .filter(|p| p.is_absolute());

    if let Some(xdg) = xdg {
        paths.push(xdg.join(DIRECTORY_NAME).join(IN_DIRECTORY_FILE_NAME));
        paths.push(xdg.join(FILE_NAME));
    }

    let home = env::var_os("HOME").map(PathBuf::from);

    if cfg!(windows) {
        let appdata = env::var_os("APPDATA").map(PathBuf::from);
        if let Some(appdata) = appdata {
            paths.push(appdata.join(DIRECTORY_NAME).join(IN_DIRECTORY_FILE_NAME));
        }
    } else if cfg!(target_os = "macos")
        && let Some(home) = &home
    {
        paths.push(
            home.join("Library")
                .join("Application Support")
                .join(DIRECTORY_NAME)
                .join(IN_DIRECTORY_FILE_NAME),
        );
    }

    if cfg!(windows) {
        let userprofile = env::var_os("USERPROFILE").map(PathBuf::from);
        if let Some(userprofile) = userprofile {
            paths.push(userprofile.join(".reginald.toml"));
        }
    } else if let Some(home) = home {
        paths.push(
            home.join(".config")
                .join(DIRECTORY_NAME)
                .join(IN_DIRECTORY_FILE_NAME),
        );
        paths.push(home.join(".config").join(FILE_NAME));
        paths.push(home.join(".reginald.toml"));
    }

    let mut unique = Vec::with_capacity(paths.len());
    for p in paths {
        if !unique.contains(&p) {
            unique.push(p);
        }
    }

    unique
}
