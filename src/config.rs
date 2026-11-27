use std::{
    env,
    ffi::OsString,
    fs,
    io::{self, ErrorKind},
    path::{Path, PathBuf},
    result,
};

use log::{LevelFilter, info, trace, warn};
use serde::Deserialize;
use thiserror::Error;

use crate::{cli::Cli, logger};

const DIRECTORY_NAME: &str = "reginald";
const FILE_NAME: &str = "reginald.toml";
const IN_DIRECTORY_FILE_NAME: &str = "config.toml";

type Result<T> = result::Result<T, Error>;

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "kebab-case")]
pub struct Config {
    #[serde(
        default = "default_log_level",
        deserialize_with = "logger::deserialize_level_filter"
    )]
    pub log_level: LevelFilter,
    // #[serde(default)]
    // pub plugin_paths: Vec<PathBuf>,
}

impl Config {
    pub fn new(
        data: &str,
        path: &Path,
        cli: &Cli,
        var: impl Fn(&str) -> Option<OsString>,
    ) -> Result<Self> {
        let mut config: Self = toml::from_str(data).map_err(|e| Error::Parse {
            path: path.to_path_buf(),
            source: e,
        })?;

        let var = |name: &str| var(name).filter(|v| !v.is_empty());

        if cli.quiet {
            config.log_level = LevelFilter::Error;
        } else if let Some(l) = match cli.verbose {
            0 => cli.log_level,
            1 => Some(LevelFilter::Info),
            2 => Some(LevelFilter::Debug),
            _ => Some(LevelFilter::Trace),
        } {
            config.log_level = l;
        } else {
            let name = "REGINALD_LOG_LEVEL";
            match var(name) {
                Some(s) => {
                    let s = s.to_str().ok_or_else(|| Error::EnvironmentVariableValue {
                        name,
                        reason: format!("value {s:?} is not valid Unicode"),
                    })?;
                    config.log_level = logger::parse_level_filter(s)
                        .map_err(|reason| Error::EnvironmentVariableValue { name, reason })?;
                }
                None => {}
            }
        }

        Ok(config)
    }
}

/// The configuration options for the current run.
#[derive(Debug)]
pub struct Invocation {
    /// Manually configured config file. When it is `None`, we will look for the
    /// config file from default locations.
    pub config_file: Option<PathBuf>,
    pub working_directories: Vec<PathBuf>,
}

impl Invocation {
    pub fn new(cli: &Cli) -> Result<Self> {
        Self::with_env(cli, |name| env::var_os(name))
    }

    /// Resolves the `Invocation` using `var` to look up environment variables.
    /// Empty values are treated as unset.
    fn with_env(cli: &Cli, var: impl Fn(&str) -> Option<OsString>) -> Result<Self> {
        let var = |name: &str| var(name).filter(|v| !v.is_empty());

        let mut wd = cli.working_directories.clone();
        if wd.is_empty()
            && let Some(s) = var("REGINALD_CHDIR")
        {
            wd = vec![s.into()]
        }

        let config_file = cli
            .config_file
            .clone()
            .or_else(|| var("REGINALD_CONFIG_FILE").map(PathBuf::from));

        Ok(Self {
            config_file,
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
    #[error("failed to parse config file {}", .path.display())]
    Parse {
        path: PathBuf,
        #[source]
        source: toml::de::Error,
    },
    #[error("failed to read config file {}", .path.display())]
    Read {
        path: PathBuf,
        #[source]
        source: io::Error,
    },
}

/// Reads the configuration file data as a string from the first valid
/// configuration file path it finds. Checks the user-supplied (via command-line
/// option or environment variable) value `path` first. If `path` is `Some`,
/// fails if a configuration file cannot be opened at that path. Otherwise,
/// checks the default paths and returns the first one that was found. The order
/// is determined by [`search_paths`].
///
/// If finding, opening, and reading the file is successful, returns a tuple
/// containing the contents of the file as a [`String`] and the path that was
/// used as a [`PathBuf`].
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

    read_first(search_paths(|name| env::var_os(name), env::home_dir()))
}

/// Reads the first readable file in `paths`, warning about the other existing
/// files that it shadows.
fn read_first(paths: Vec<PathBuf>) -> Result<(String, PathBuf)> {
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
fn search_paths(var: impl Fn(&str) -> Option<OsString>, home: Option<PathBuf>) -> Vec<PathBuf> {
    let mut paths = Vec::new();

    // Directories from the environment must be absolute. Otherwise an empty or
    // relative value would make us search relative to the current directory.
    let absolute_dir = |name: &str| var(name).map(PathBuf::from).filter(|p| p.is_absolute());

    // XDG_CONFIG_HOME is given highest precedence and must also be absolute
    // according to the spec.
    if let Some(d) = absolute_dir("XDG_CONFIG_HOME") {
        paths.push(d.join(DIRECTORY_NAME).join(IN_DIRECTORY_FILE_NAME));
        paths.push(d.join(FILE_NAME));
    }

    // The platform-specific directories are next. It feels like the logical
    // choice.
    if cfg!(windows) {
        if let Some(d) = absolute_dir("LOCALAPPDATA") {
            paths.push(d.join(DIRECTORY_NAME).join(IN_DIRECTORY_FILE_NAME));
        }

        if let Some(d) = absolute_dir("APPDATA") {
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

const fn default_log_level() -> LevelFilter {
    LevelFilter::Warn
}

#[cfg(test)]
mod tests {
    use std::path::Path;

    use clap::Parser;
    use tempfile::TempDir;

    use super::*;

    fn cli(args: &[&str]) -> Cli {
        Cli::try_parse_from(std::iter::once("reginald").chain(args.iter().copied())).unwrap()
    }

    fn fake_env<'a>(vars: &'a [(&str, &str)]) -> impl Fn(&str) -> Option<OsString> + 'a {
        move |name| {
            vars.iter()
                .find(|(k, _)| *k == name)
                .map(|(_, v)| OsString::from(v))
        }
    }

    fn invocation(args: &[&str], vars: &[(&str, &str)]) -> Result<Invocation> {
        Invocation::with_env(&cli(args), fake_env(vars))
    }

    fn write(dir: &Path, name: &str, content: &str) -> PathBuf {
        let path = dir.join(name);
        fs::write(&path, content).unwrap();
        path
    }

    #[test]
    fn invocation_defaults() {
        let inv = invocation(&[], &[]).unwrap();
        assert!(inv.working_directories.is_empty());
        assert_eq!(inv.config_file, None);
    }

    #[test]
    fn chdir_flag_overrides_env() {
        let inv = invocation(&["-C", "flag"], &[("REGINALD_CHDIR", "env")]).unwrap();
        assert_eq!(inv.working_directories, [PathBuf::from("flag")]);
    }

    #[test]
    fn chdir_env_is_used_without_flag() {
        let inv = invocation(&[], &[("REGINALD_CHDIR", "env")]).unwrap();
        assert_eq!(inv.working_directories, [PathBuf::from("env")]);
    }

    #[test]
    fn config_file_flag_overrides_env() {
        let vars = [("REGINALD_CONFIG_FILE", "env.toml")];
        let inv = invocation(&["-c", "flag.toml"], &vars).unwrap();
        assert_eq!(inv.config_file, Some("flag.toml".into()));
    }

    #[test]
    fn config_file_env_is_used_without_flag() {
        let inv = invocation(&[], &[("REGINALD_CONFIG_FILE", "env.toml")]).unwrap();
        assert_eq!(inv.config_file, Some("env.toml".into()));
    }

    #[test]
    fn empty_env_values_are_ignored() {
        let vars = [("REGINALD_CHDIR", ""), ("REGINALD_CONFIG_FILE", "")];
        let inv = invocation(&[], &vars).unwrap();
        assert!(inv.working_directories.is_empty());
        assert_eq!(inv.config_file, None);
    }

    fn config(data: &str, args: &[&str], vars: &[(&str, &str)]) -> Result<Config> {
        Config::new(data, Path::new("reginald.toml"), &cli(args), fake_env(vars))
    }

    fn log_level(data: &str, args: &[&str], vars: &[(&str, &str)]) -> LevelFilter {
        config(data, args, vars).unwrap().log_level
    }

    const DEBUG_FILE: &str = r#"log-level = "debug""#;

    #[test]
    fn log_level_defaults_to_warn() {
        assert_eq!(log_level("", &[], &[]), LevelFilter::Warn);
    }

    #[test]
    fn log_level_is_read_from_file() {
        assert_eq!(log_level(DEBUG_FILE, &[], &[]), LevelFilter::Debug);
    }

    #[test]
    fn invalid_log_level_in_file_is_a_parse_error() {
        for data in [r#"log-level = "loud""#, r#"log-level = "DEBUG""#] {
            let err = config(data, &[], &[]).unwrap_err();
            assert!(matches!(err, Error::Parse { .. }), "{data}: {err:?}");
        }
    }

    #[test]
    fn log_level_env_overrides_file() {
        let vars = [("REGINALD_LOG_LEVEL", "info")];
        assert_eq!(log_level(DEBUG_FILE, &[], &vars), LevelFilter::Info);
    }

    #[test]
    fn empty_log_level_env_is_ignored() {
        let vars = [("REGINALD_LOG_LEVEL", "")];
        assert_eq!(log_level(DEBUG_FILE, &[], &vars), LevelFilter::Debug);
    }

    #[test]
    fn log_level_flags_override_env_and_file() {
        let vars = [("REGINALD_LOG_LEVEL", "off")];
        for (args, level) in [
            (&["--log-level", "info"][..], LevelFilter::Info),
            (&["-q"], LevelFilter::Error),
            (&["-v"], LevelFilter::Info),
            (&["-vv"], LevelFilter::Debug),
            (&["-vvv"], LevelFilter::Trace),
        ] {
            assert_eq!(log_level(DEBUG_FILE, args, &vars), level, "{args:?}");
        }
    }

    #[test]
    fn verbose_count_saturates_at_trace() {
        assert_eq!(log_level("", &["-vvvvv"], &[]), LevelFilter::Trace);
    }

    #[test]
    fn invalid_log_level_env_is_an_error() {
        let err = config("", &[], &[("REGINALD_LOG_LEVEL", "loud")]).unwrap_err();
        assert!(matches!(
            err,
            Error::EnvironmentVariableValue {
                name: "REGINALD_LOG_LEVEL",
                ..
            }
        ));
    }

    #[test]
    fn invalid_log_level_env_is_ignored_when_flag_is_given() {
        let vars = [("REGINALD_LOG_LEVEL", "loud")];
        assert_eq!(log_level("", &["-v"], &vars), LevelFilter::Info);
    }

    #[cfg(unix)]
    #[test]
    fn non_unicode_log_level_env_is_an_error() {
        use std::os::unix::ffi::OsStringExt;

        let var = |name: &str| {
            (name == "REGINALD_LOG_LEVEL").then(|| OsString::from_vec(b"de\xffbug".to_vec()))
        };
        let err = Config::new("", Path::new("reginald.toml"), &cli(&[]), var).unwrap_err();
        assert!(matches!(
            err,
            Error::EnvironmentVariableValue {
                name: "REGINALD_LOG_LEVEL",
                ..
            }
        ));
    }

    /// The paths that are searched in the home directory, in order, including
    /// the platform-specific ones.
    fn home_paths(home: &Path) -> Vec<PathBuf> {
        let mut paths = Vec::new();
        if cfg!(target_os = "macos") {
            paths.push(home.join("Library/Application Support/reginald/config.toml"));
        }
        paths.extend([
            home.join(".config/reginald/config.toml"),
            home.join(".config/reginald.toml"),
            home.join(".reginald.toml"),
        ]);
        paths
    }

    fn absolute(path: &str) -> PathBuf {
        if cfg!(windows) {
            PathBuf::from(format!("C:{path}"))
        } else {
            PathBuf::from(path)
        }
    }

    #[test]
    fn search_paths_without_home_or_env_is_empty() {
        assert!(search_paths(fake_env(&[]), None).is_empty());
    }

    #[test]
    fn search_paths_use_home() {
        let home = absolute("/home/u");
        assert_eq!(
            search_paths(fake_env(&[]), Some(home.clone())),
            home_paths(&home)
        );
    }

    #[test]
    fn search_paths_put_xdg_config_home_first() {
        let home = absolute("/home/u");
        let xdg = absolute("/xdg");
        let vars = [("XDG_CONFIG_HOME", xdg.to_str().unwrap())];

        let mut expected = vec![xdg.join("reginald/config.toml"), xdg.join("reginald.toml")];
        expected.extend(home_paths(&home));
        assert_eq!(search_paths(fake_env(&vars), Some(home)), expected);
    }

    #[test]
    fn search_paths_ignore_relative_xdg_config_home() {
        let home = absolute("/home/u");
        let vars = [("XDG_CONFIG_HOME", "relative")];
        assert_eq!(
            search_paths(fake_env(&vars), Some(home.clone())),
            home_paths(&home)
        );
    }

    #[test]
    fn search_paths_are_unique() {
        let home = absolute("/home/u");
        let xdg = home.join(".config");
        let vars = [("XDG_CONFIG_HOME", xdg.to_str().unwrap())];

        let mut expected = vec![
            home.join(".config/reginald/config.toml"),
            home.join(".config/reginald.toml"),
        ];
        if cfg!(target_os = "macos") {
            expected.push(home.join("Library/Application Support/reginald/config.toml"));
        }
        expected.push(home.join(".reginald.toml"));
        assert_eq!(search_paths(fake_env(&vars), Some(home)), expected);
    }

    #[cfg(windows)]
    #[test]
    fn search_paths_use_app_data_on_windows() {
        let vars = [("LOCALAPPDATA", r"C:\local"), ("APPDATA", r"C:\roaming")];
        assert_eq!(
            search_paths(fake_env(&vars), None),
            [
                PathBuf::from(r"C:\local\reginald\config.toml"),
                PathBuf::from(r"C:\roaming\reginald\config.toml"),
            ]
        );
    }

    #[cfg(windows)]
    #[test]
    fn search_paths_ignore_empty_and_relative_app_data_on_windows() {
        for vars in [
            [("LOCALAPPDATA", ""), ("APPDATA", "")],
            [("LOCALAPPDATA", "local"), ("APPDATA", "roaming")],
        ] {
            assert!(search_paths(fake_env(&vars), None).is_empty(), "{vars:?}");
        }
    }

    #[test]
    fn read_first_reports_all_searched_paths() {
        let dir = TempDir::new().unwrap();
        let paths = vec![dir.path().join("a.toml"), dir.path().join("b.toml")];
        match read_first(paths.clone()) {
            Err(Error::NoFile { searched }) => assert_eq!(searched, paths),
            r => panic!("unexpected result: {r:?}"),
        }
    }

    #[test]
    fn read_first_skips_missing_files() {
        let dir = TempDir::new().unwrap();
        let b = write(dir.path(), "b.toml", "b");
        let (s, p) = read_first(vec![dir.path().join("a.toml"), b.clone()]).unwrap();
        assert_eq!((s.as_str(), p), ("b", b));
    }

    #[test]
    fn read_first_uses_the_highest_precedence_file() {
        let dir = TempDir::new().unwrap();
        let a = write(dir.path(), "a.toml", "a");
        let b = write(dir.path(), "b.toml", "b");
        let (s, p) = read_first(vec![a.clone(), b]).unwrap();
        assert_eq!((s.as_str(), p), ("a", a));
    }

    // Reading a directory fails with `PermissionDenied` on Windows, which is
    // skipped instead.
    #[cfg(unix)]
    #[test]
    fn read_first_fails_on_other_read_errors() {
        let dir = TempDir::new().unwrap();
        let b = write(dir.path(), "b.toml", "b");
        match read_first(vec![dir.path().to_path_buf(), b]) {
            Err(Error::Read { path, .. }) => assert_eq!(path, dir.path()),
            r => panic!("unexpected result: {r:?}"),
        }
    }

    #[cfg(unix)]
    #[test]
    fn read_first_skips_unreadable_files() {
        use std::os::unix::fs::PermissionsExt;

        let dir = TempDir::new().unwrap();
        let a = write(dir.path(), "a.toml", "a");
        let b = write(dir.path(), "b.toml", "b");
        fs::set_permissions(&a, fs::Permissions::from_mode(0o000)).unwrap();
        if fs::read(&a).is_ok() {
            // Running as root, permissions are not enforced.
            return;
        }
        let (s, p) = read_first(vec![a, b.clone()]).unwrap();
        assert_eq!((s.as_str(), p), ("b", b));
    }

    #[test]
    fn read_file_reads_the_given_file() {
        let dir = TempDir::new().unwrap();
        let a = write(dir.path(), "a.toml", "a");
        let (s, p) = read_file(Some(a.clone())).unwrap();
        assert_eq!((s.as_str(), p), ("a", a));
    }

    #[test]
    fn read_file_reports_missing_given_file() {
        let dir = TempDir::new().unwrap();
        let a = dir.path().join("a.toml");
        match read_file(Some(a.clone())) {
            Err(Error::FileNotFound { path, .. }) => assert_eq!(path, a),
            r => panic!("unexpected result: {r:?}"),
        }
    }

    #[test]
    fn read_file_fails_on_other_errors_with_given_file() {
        let dir = TempDir::new().unwrap();
        match read_file(Some(dir.path().to_path_buf())) {
            Err(Error::Read { path, .. }) => assert_eq!(path, dir.path()),
            r => panic!("unexpected result: {r:?}"),
        }
    }
}
