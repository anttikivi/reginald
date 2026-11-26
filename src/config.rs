use std::{
    env, fs,
    io::{self, ErrorKind},
    path::PathBuf,
    result,
};

use log::{LevelFilter, info, trace, warn};
use thiserror::Error;

use crate::{cli::Cli, logger};

const DIRECTORY_NAME: &str = "reginald";
const FILE_NAME: &str = "reginald.toml";
const IN_DIRECTORY_FILE_NAME: &str = "config.toml";

pub type Result<T> = result::Result<T, Error>;

/// The configuration options for the current run.
#[derive(Debug)]
pub struct Invocation {
    /// Manually configured config file. When it is `None`, we will look for the
    /// config file from default locations.
    pub config_file: Option<PathBuf>,
    pub log_level_filter: LevelFilter,
    pub working_directories: Vec<PathBuf>,
}

impl Invocation {
    pub fn new(cli: &Cli) -> Result<Self> {
        let mut wd = cli.working_directories.clone();
        if wd.is_empty()
            && let Some(s) = env::var_os("REGINALD_CHDIR").filter(|v| !v.is_empty())
        {
            wd = vec![s.into()]
        }

        let config_file = cli.config_file.clone().or_else(|| {
            env::var_os("REGINALD_CONFIG_FILE")
                .filter(|v| !v.is_empty())
                .map(PathBuf::from)
        });

        let mut level_filter = LevelFilter::Warn;
        if let Some(l) = logger::filter_from_flags(cli.log_level, cli.verbose, cli.quiet) {
            level_filter = l;
        } else if let Ok(s) = env::var("REGINALD_LOG_LEVEL")
            && !s.is_empty()
        {
            level_filter =
                logger::filter_from_str(&s).map_err(|e| Error::EnvironmentVariableValue {
                    name: "REGINALD_LOG_LEVEL",
                    reason: e,
                })?;
        }

        Ok(Self {
            config_file,
            log_level_filter: level_filter,
            working_directories: wd,
        })
    }
}

#[derive(Error, Debug)]
pub enum Error {
    #[error("failed to parse {name}: {reason}")]
    EnvironmentVariableValue { name: &'static str, reason: String },
    #[error("failed to open config file at \"{}\"", .path.display())]
    FileNotFound {
        path: PathBuf,
        #[source]
        source: io::Error,
    },
    #[error("no config file found, searched:{}", .searched.iter().map(|p| format!("\n  {}", p.display())).collect::<String>())]
    NoFile { searched: Vec<PathBuf> },
    #[error("failed to read config file {}", .path.display())]
    Read {
        path: PathBuf,
        #[source]
        source: io::Error,
    },
}

pub fn read_file(path: Option<PathBuf>) -> Result<(String, PathBuf)> {
    if let Some(p) = path {
        trace!("trying user-supplied config file {}", p.display());
        return match fs::read_to_string(&p) {
            Ok(s) => {
                info!("read config file from {}", p.display());
                Ok((s, p))
            }
            Err(e) if e.kind() == ErrorKind::NotFound => {
                Err(Error::FileNotFound { path: p, source: e })
            }
            Err(e) => Err(Error::Read { path: p, source: e }),
        };
    }

    let paths = search_paths();
    let mut result = None;
    let mut found = Vec::new();
    for path in &paths {
        trace!("trying config file {}", path.display());
        if result.is_none() {
            let s = fs::read_to_string(path);
            match s {
                Ok(s) => {
                    result = Some(s);
                    found.push(path);
                    info!("read config file from {}", path.display())
                }
                Err(e) if e.kind() == ErrorKind::NotFound => {}
                Err(e) if e.kind() == ErrorKind::PermissionDenied => {
                    warn!("failed to open config file at {}: {e}", path.display())
                }
                Err(e) => {
                    return Err(Error::Read {
                        path: path.to_path_buf(),
                        source: e,
                    });
                }
            }
        } else {
            match fs::exists(path) {
                Ok(true) => {
                    found.push(path);
                    info!("found config file at {}", path.display())
                }
                Ok(false) => {}
                Err(e) => {
                    warn!("failed to open config file at {}: {e}", path.display())
                }
            }
        }
    }

    if found.len() > 1 {
        warn!(
            "multiple config files found:{}",
            found
                .iter()
                .map(|p| format!("\n  {}", p.display()))
                .collect::<String>()
        );
        warn!(
            "using config file with the highest precedence: {}",
            found[0].display()
        );
    }

    if let Some(s) = result {
        Ok((s, found[0].to_path_buf()))
    } else {
        Err(Error::NoFile { searched: paths })
    }
}

/// Creates a [`Vec`] of the default paths to look for the config file.
///
/// Currently assumes that everything that is not a Windows platform should
/// behave like a Linux or Unix platform, except macOS that is allowed to use
/// `~/Library/Application Support` in addition to the "standard" directories.
fn search_paths() -> Vec<PathBuf> {
    let mut paths = Vec::new();

    // XDG_CONFIG_HOME is given highest precedence and must also be absolute
    // according to the spec.
    let xdg = env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .filter(|p| p.is_absolute());
    if let Some(d) = xdg {
        paths.push(d.join(DIRECTORY_NAME).join(IN_DIRECTORY_FILE_NAME));
        paths.push(d.join(FILE_NAME));
    }

    let home = env::home_dir();

    // The platform-specific directories are next. It feels like a logical
    // choice.
    if cfg!(windows) {
        let localappdata = env::var_os("LOCALAPPDATA").map(PathBuf::from);
        if let Some(d) = localappdata {
            paths.push(d.join(DIRECTORY_NAME).join(IN_DIRECTORY_FILE_NAME));
        }

        let appdata = env::var_os("APPDATA").map(PathBuf::from);
        if let Some(d) = appdata {
            paths.push(d.join(DIRECTORY_NAME).join(IN_DIRECTORY_FILE_NAME));
        }
    } else if cfg!(target_os = "macos")
        && let Some(d) = &home
    {
        paths.push(
            d.join("Library")
                .join("Application Support")
                .join(DIRECTORY_NAME)
                .join(IN_DIRECTORY_FILE_NAME),
        );
    }

    // The final default is to look from the home directory. It conveniently
    // resolves to `%USERPROFILE%` on Windows, so we can use the same paths on
    // every platform.
    if let Some(d) = home {
        paths.push(
            d.join(".config")
                .join(DIRECTORY_NAME)
                .join(IN_DIRECTORY_FILE_NAME),
        );
        paths.push(d.join(".config").join(FILE_NAME));
        paths.push(d.join(".reginald.toml"));
    }

    let mut unique = Vec::with_capacity(paths.len());
    for p in paths {
        if !unique.contains(&p) {
            unique.push(p);
        }
    }

    unique
}
