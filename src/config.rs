use std::{
    collections::BTreeMap,
    env,
    ffi::OsString,
    fmt::Write as _,
    fs,
    io::{self, ErrorKind},
    iter,
    path::{Path, PathBuf},
    result,
};

use log::{LevelFilter, info, trace, warn};
use serde::Deserialize;
use thiserror::Error;

#[cfg(windows)]
use crate::known_folder::{self, Folder};
use crate::{cli::Cli, logger};

const DIRECTORY_NAME: &str = "reginald";
#[cfg(not(windows))]
const FILE_NAME: &str = "reginald.toml";
const IN_DIRECTORY_FILE_NAME: &str = "config.toml";
const PLUGINS_DIRECTORY_NAME: &str = "plugins";

#[cfg(not(windows))]
const XDG_CONFIG: Xdg = Xdg {
    home_var: "XDG_CONFIG_HOME",
    home_default: ".config",
    dirs_var: "XDG_CONFIG_DIRS",
    dirs_default: &["/etc/xdg"],
};

#[cfg(not(windows))]
const XDG_DATA: Xdg = Xdg {
    home_var: "XDG_DATA_HOME",
    home_default: ".local/share",
    dirs_var: "XDG_DATA_DIRS",
    dirs_default: &["/usr/local/share", "/usr/share"],
};

type Result<T> = result::Result<T, Error>;

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "kebab-case")]
pub struct Config {
    #[serde(
        default = "default_log_level",
        deserialize_with = "logger::deserialize_level_filter"
    )]
    pub log_level: LevelFilter,
    #[serde(default)]
    #[expect(dead_code, reason = "will be used later")]
    pub plugins: BTreeMap<String, Plugin>,
    pub plugin_path: Option<Vec<PathBuf>>,
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

        if let Some(l) = log_level_override(cli, &var)? {
            config.log_level = l;
        }

        let var = |name: &str| var(name).filter(|v| !v.is_empty());

        if let Some(d) = &cli.plugin_path {
            config.plugin_path = Some(d.to_owned());
        } else if let Some(d) = var("REGINALD_PLUGIN_PATH") {
            config.plugin_path = Some(env::split_paths(&d).collect());
        } else if config.plugin_path.is_none() {
            #[cfg(windows)]
            let paths = default_plugin_path(known_folder::path);
            #[cfg(not(windows))]
            let paths = default_plugin_path(var, env::home_dir());
            config.plugin_path = Some(paths);
        }

        Ok(config)
    }
}

#[derive(Debug, Deserialize)]
pub struct Plugin {
    #[expect(dead_code, reason = "will be used later")]
    path: Option<PathBuf>,
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
    #[error("no config file found, searched:{}", path_list(.searched))]
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

/// A kind of XDG base directory and its defaults as defined by the XDG Base
/// Directory Specification.
#[cfg(not(windows))]
struct Xdg {
    home_var: &'static str,
    home_default: &'static str,
    dirs_var: &'static str,
    dirs_default: &'static [&'static str],
}

#[cfg(not(windows))]
impl Xdg {
    /// Returns the user directory followed by the system directories, in order
    /// of precedence.
    ///
    /// The spec requires every path to be absolute. A relative `*_HOME` value
    /// is ignored like an unset one, so the default under `home` is used
    /// instead. The default can only be used if `home` is absolute, too.
    ///
    /// The `*_DIRS` defaults are only used if the variable is unset or empty.
    /// Relative entries in the list are skipped one by one, so a list without
    /// any valid entries means that there are no system directories.
    fn dirs(&self, var: impl Fn(&str) -> Option<OsString>, home: Option<PathBuf>) -> Vec<PathBuf> {
        let mut dirs = Vec::new();

        let user = var(self.home_var)
            .map(PathBuf::from)
            .filter(|p| p.is_absolute())
            .or_else(|| {
                home.filter(|h| h.is_absolute())
                    .map(|h| h.join(self.home_default))
            });
        match user {
            Some(d) => dirs.push(d),
            None => warn!(
                "cannot determine the user directory, set {} or HOME to an absolute path",
                self.home_var
            ),
        }

        match var(self.dirs_var).filter(|v| !v.is_empty()) {
            Some(s) => dirs.extend(env::split_paths(&s).filter(|p| p.is_absolute())),
            None => dirs.extend(self.dirs_default.iter().map(PathBuf::from)),
        }

        dirs
    }
}

/// Returns the directories to change into, in order: the `-C` flags, or
/// `REGINALD_CHDIR` if none were given.
pub fn working_directories(cli: &Cli, var: impl Fn(&str) -> Option<OsString>) -> Vec<PathBuf> {
    if !cli.working_directories.is_empty() {
        return cli.working_directories.clone();
    }
    var("REGINALD_CHDIR")
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
        .into_iter()
        .collect()
}

/// Returns the config file given with `-c` or `REGINALD_CONFIG_FILE`, or `None`
/// to search the default locations.
pub fn file(cli: &Cli, var: impl Fn(&str) -> Option<OsString>) -> Option<PathBuf> {
    cli.config_file.clone().or_else(|| {
        var("REGINALD_CONFIG_FILE")
            .filter(|v| !v.is_empty())
            .map(PathBuf::from)
    })
}

/// Resolves the log level set by the command-line flags or the environment.
/// Returns `None` if neither sets it, in which case the level from the config
/// file or the default level should be used.
///
/// The flags take precedence over the environment, and the environment
/// variable is not read at all if a flag sets the level.
pub fn log_level_override(
    cli: &Cli,
    var: impl Fn(&str) -> Option<OsString>,
) -> Result<Option<LevelFilter>> {
    if cli.quiet {
        return Ok(Some(LevelFilter::Error));
    }

    let flag = match cli.verbose {
        0 => cli.log_level,
        1 => Some(LevelFilter::Info),
        2 => Some(LevelFilter::Debug),
        _ => Some(LevelFilter::Trace),
    };
    if flag.is_some() {
        return Ok(flag);
    }

    let name = "REGINALD_LOG_LEVEL";
    let Some(s) = var(name).filter(|v| !v.is_empty()) else {
        return Ok(None);
    };

    #[expect(
        clippy::unnecessary_debug_formatting,
        reason = "`Debug` escapes the invalid bytes, `display` would hide them"
    )]
    let s = s.to_str().ok_or_else(|| Error::EnvironmentVariableValue {
        name,
        reason: format!("value {s:?} is not valid Unicode"),
    })?;

    logger::parse_level_filter(s)
        .map(Some)
        .map_err(|reason| Error::EnvironmentVariableValue { name, reason })
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

    #[cfg(windows)]
    let paths = search_paths(known_folder::path);
    #[cfg(not(windows))]
    let paths = search_paths(|name| env::var_os(name), env::home_dir());

    read_first(paths)
}

/// Reads the first readable file in `paths`, warning about the other existing
/// files that it shadows.
fn read_first(paths: Vec<PathBuf>) -> Result<(String, PathBuf)> {
    let mut chosen = None;
    let mut others = Vec::new();
    for path in &paths {
        trace!("trying config file {}", path.display());
        if chosen.is_none() {
            // let s = fs::read_to_string(path);
            match fs::read_to_string(path) {
                Ok(s) => {
                    info!("read config file from {}", path.display());
                    chosen = Some((s, path));
                }
                Err(e) if e.kind() == ErrorKind::NotFound => {}
                Err(e) if e.kind() == ErrorKind::PermissionDenied => {
                    warn!("failed to open config file at {}: {e}", path.display());
                }
                Err(e) => {
                    return Err(Error::Read {
                        path: path.clone(),
                        source: e,
                    });
                }
            }
        } else {
            match fs::exists(path) {
                Ok(true) => {
                    info!("found config file at {}", path.display());
                    others.push(path);
                }
                Ok(false) => {}
                Err(e) => {
                    warn!("failed to open config file at {}: {e}", path.display());
                }
            }
        }
    }

    let Some((s, path)) = chosen else {
        return Err(Error::NoFile { searched: paths });
    };

    if !others.is_empty() {
        warn!(
            "multiple config files found:{}",
            path_list(iter::once(path).chain(others))
        );
        warn!(
            "using config file with the highest precedence: {}",
            path.display()
        );
    }

    Ok((s, path.clone()))
}

/// Returns the default config file candidates, in order of precedence.
///
/// The machine-local folder comes first so that it overrides the roaming one,
/// and the folder shared by all users comes last.
#[cfg(windows)]
fn search_paths(folder: impl Fn(Folder) -> Option<PathBuf>) -> Vec<PathBuf> {
    unique(
        [
            Folder::LocalAppData,
            Folder::RoamingAppData,
            Folder::ProgramData,
        ]
        .into_iter()
        .filter_map(folder)
        .map(|p| p.join(DIRECTORY_NAME).join(IN_DIRECTORY_FILE_NAME)),
    )
}

/// Returns the default config file candidates, in order of precedence.
///
/// Follows the XDG Base Directory Specification: the user config directory
/// comes first, then the system config directories.
#[cfg(not(windows))]
fn search_paths(var: impl Fn(&str) -> Option<OsString>, home: Option<PathBuf>) -> Vec<PathBuf> {
    unique(XDG_CONFIG.dirs(var, home).into_iter().flat_map(|p| {
        [
            p.join(DIRECTORY_NAME).join(IN_DIRECTORY_FILE_NAME),
            p.join(FILE_NAME),
        ]
    }))
}

const fn default_log_level() -> LevelFilter {
    LevelFilter::Warn
}

/// Returns the default plugin directories, in order of precedence.
///
/// Plugins are installed software, so they are not looked up from the roaming
/// folder.
#[cfg(windows)]
fn default_plugin_path(folder: impl Fn(Folder) -> Option<PathBuf>) -> Vec<PathBuf> {
    unique(
        [Folder::LocalAppData, Folder::ProgramData]
            .into_iter()
            .filter_map(folder)
            .map(|p| p.join(DIRECTORY_NAME).join(PLUGINS_DIRECTORY_NAME)),
    )
}

/// Returns the default plugin directories, in order of precedence.
///
/// Follows the XDG Base Directory Specification: the user data directory comes
/// first, then the system data directories.
#[cfg(not(windows))]
fn default_plugin_path(
    var: impl Fn(&str) -> Option<OsString>,
    home: Option<PathBuf>,
) -> Vec<PathBuf> {
    unique(
        XDG_DATA
            .dirs(var, home)
            .into_iter()
            .map(|p| p.join(DIRECTORY_NAME).join(PLUGINS_DIRECTORY_NAME)),
    )
}

/// Removes the duplicates from `paths`, keeping the first occurrences.
fn unique(paths: impl IntoIterator<Item = PathBuf>) -> Vec<PathBuf> {
    let mut unique = Vec::new();
    for p in paths {
        if !unique.contains(&p) {
            unique.push(p);
        }
    }

    unique
}

fn path_list<P>(paths: impl IntoIterator<Item = P>) -> String
where
    P: AsRef<Path>,
{
    paths.into_iter().fold(String::new(), |mut out, p| {
        let _ = write!(out, "\n  {}", p.as_ref().display());
        out
    })
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

    fn working_dirs(args: &[&str], vars: &[(&str, &str)]) -> Vec<PathBuf> {
        working_directories(&cli(args), fake_env(vars))
    }

    fn config_file(args: &[&str], vars: &[(&str, &str)]) -> Option<PathBuf> {
        file(&cli(args), fake_env(vars))
    }

    fn write(dir: &Path, name: &str, content: &str) -> PathBuf {
        let path = dir.join(name);
        fs::write(&path, content).unwrap();
        path
    }

    #[test]
    fn defaults_without_flags_or_env() {
        assert_eq!(working_dirs(&[], &[]), Vec::<PathBuf>::new());
        assert_eq!(config_file(&[], &[]), None);
    }

    #[test]
    fn chdir_flag_overrides_env() {
        let wd = working_dirs(&["-C", "flag"], &[("REGINALD_CHDIR", "env")]);
        assert_eq!(wd, [PathBuf::from("flag")]);
    }

    #[test]
    fn chdir_env_is_used_without_flag() {
        let wd = working_dirs(&[], &[("REGINALD_CHDIR", "env")]);
        assert_eq!(wd, [PathBuf::from("env")]);
    }

    #[test]
    fn config_file_flag_overrides_env() {
        let vars = [("REGINALD_CONFIG_FILE", "env.toml")];
        assert_eq!(
            config_file(&["-c", "flag.toml"], &vars),
            Some("flag.toml".into())
        );
    }

    #[test]
    fn config_file_env_is_used_without_flag() {
        let vars = [("REGINALD_CONFIG_FILE", "env.toml")];
        assert_eq!(config_file(&[], &vars), Some("env.toml".into()));
    }

    #[test]
    fn empty_env_values_are_ignored() {
        let vars = [("REGINALD_CHDIR", ""), ("REGINALD_CONFIG_FILE", "")];
        assert_eq!(working_dirs(&[], &vars), Vec::<PathBuf>::new());
        assert_eq!(config_file(&[], &vars), None);
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

    fn plugin_path(data: &str, args: &[&str], vars: &[(&str, &str)]) -> Vec<PathBuf> {
        config(data, args, vars).unwrap().plugin_path.unwrap()
    }

    const PLUGIN_PATH_FILE: &str = r#"plugin-path = ["file"]"#;

    #[cfg(not(windows))]
    #[test]
    fn plugin_path_default_to_platform_dirs() {
        let vars = [("XDG_DATA_HOME", "/xdg")];
        let dirs = plugin_path("", &[], &vars);
        assert_eq!(dirs, default_plugin_path(fake_env(&vars), env::home_dir()));
        assert_eq!(dirs.first(), Some(&PathBuf::from("/xdg/reginald/plugins")));
    }

    #[cfg(windows)]
    #[test]
    fn plugin_path_default_to_platform_dirs() {
        let dirs = plugin_path("", &[], &[]);
        assert_eq!(dirs, default_plugin_path(known_folder::path));
        assert!(
            !dirs.is_empty(),
            "expected at least one default plugin directory"
        );
    }

    #[test]
    fn plugin_path_are_read_from_file() {
        assert_eq!(
            plugin_path(PLUGIN_PATH_FILE, &[], &[]),
            [PathBuf::from("file")]
        );
    }

    #[test]
    fn empty_plugin_path_in_file_are_kept() {
        assert_eq!(
            plugin_path("plugin-path = []", &[], &[]),
            Vec::<PathBuf>::new()
        );
    }

    #[test]
    fn plugin_path_env_overrides_file() {
        let vars = [("REGINALD_PLUGIN_PATH", "env")];
        assert_eq!(
            plugin_path(PLUGIN_PATH_FILE, &[], &vars),
            [PathBuf::from("env")]
        );
    }

    #[test]
    fn plugin_path_env_is_split_at_path_separators() {
        let sep = if cfg!(windows) { ";" } else { ":" };
        let value = format!("a{sep}b");
        let vars = [("REGINALD_PLUGIN_PATH", value.as_str())];
        assert_eq!(
            plugin_path("", &[], &vars),
            [PathBuf::from("a"), PathBuf::from("b")]
        );
    }

    #[test]
    fn empty_plugin_path_env_is_ignored() {
        let vars = [("REGINALD_PLUGIN_PATH", "")];
        assert_eq!(
            plugin_path(PLUGIN_PATH_FILE, &[], &vars),
            [PathBuf::from("file")]
        );
    }

    #[test]
    fn plugin_path_flag_overrides_env_and_file() {
        let vars = [("REGINALD_PLUGIN_PATH", "env")];
        assert_eq!(
            plugin_path(PLUGIN_PATH_FILE, &["-P", "flag"], &vars),
            [PathBuf::from("flag")]
        );
    }

    #[test]
    fn plugin_path_flag_can_be_repeated() {
        assert_eq!(
            plugin_path("", &["-P", "a", "--plugin-path", "b"], &[]),
            [PathBuf::from("a"), PathBuf::from("b")]
        );
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

    #[cfg(not(windows))]
    mod xdg {
        use super::*;

        const HOME: &str = "/home/u";

        fn search(vars: &[(&str, &str)], home: Option<&str>) -> Vec<PathBuf> {
            search_paths(fake_env(vars), home.map(PathBuf::from))
        }

        fn plugins(vars: &[(&str, &str)], home: Option<&str>) -> Vec<PathBuf> {
            default_plugin_path(fake_env(vars), home.map(PathBuf::from))
        }

        /// The config file candidates in `dirs`, in order.
        fn config_files(dirs: &[&str]) -> Vec<PathBuf> {
            dirs.iter()
                .flat_map(|d| {
                    let d = Path::new(d);
                    [d.join("reginald/config.toml"), d.join("reginald.toml")]
                })
                .collect()
        }

        fn plugin_dirs(dirs: &[&str]) -> Vec<PathBuf> {
            dirs.iter()
                .map(|d| Path::new(d).join("reginald/plugins"))
                .collect()
        }

        #[test]
        fn search_paths_default_to_home_and_etc_xdg() {
            assert_eq!(
                search(&[], Some(HOME)),
                config_files(&["/home/u/.config", "/etc/xdg"])
            );
        }

        #[test]
        fn search_paths_use_xdg_config_home_instead_of_home() {
            let vars = [("XDG_CONFIG_HOME", "/xdg")];
            assert_eq!(
                search(&vars, Some(HOME)),
                config_files(&["/xdg", "/etc/xdg"])
            );
        }

        #[test]
        fn search_paths_ignore_empty_and_relative_xdg_config_home() {
            for value in ["", "relative"] {
                let vars = [("XDG_CONFIG_HOME", value)];
                assert_eq!(
                    search(&vars, Some(HOME)),
                    config_files(&["/home/u/.config", "/etc/xdg"]),
                    "{value:?}"
                );
            }
        }

        #[test]
        fn search_paths_without_valid_home_use_only_system_dirs() {
            for home in [None, Some(""), Some("relative")] {
                assert_eq!(search(&[], home), config_files(&["/etc/xdg"]), "{home:?}");
            }
        }

        #[test]
        fn search_paths_use_xdg_config_dirs_in_order() {
            let vars = [("XDG_CONFIG_DIRS", "/a:/b")];
            assert_eq!(
                search(&vars, Some(HOME)),
                config_files(&["/home/u/.config", "/a", "/b"])
            );
        }

        #[test]
        fn search_paths_skip_invalid_xdg_config_dirs_entries() {
            let vars = [("XDG_CONFIG_DIRS", "/a:relative::/b")];
            assert_eq!(
                search(&vars, Some(HOME)),
                config_files(&["/home/u/.config", "/a", "/b"])
            );
        }

        #[test]
        fn search_paths_use_empty_xdg_config_dirs_default() {
            let vars = [("XDG_CONFIG_DIRS", "")];
            assert_eq!(
                search(&vars, Some(HOME)),
                config_files(&["/home/u/.config", "/etc/xdg"])
            );
        }

        #[test]
        fn search_paths_have_no_system_dirs_if_no_xdg_config_dirs_entry_is_valid() {
            let vars = [("XDG_CONFIG_DIRS", "relative")];
            assert_eq!(
                search(&vars, Some(HOME)),
                config_files(&["/home/u/.config"])
            );
        }

        #[test]
        fn search_paths_are_unique() {
            let vars = [("XDG_CONFIG_DIRS", "/home/u/.config:/etc/xdg:/etc/xdg")];
            assert_eq!(
                search(&vars, Some(HOME)),
                config_files(&["/home/u/.config", "/etc/xdg"])
            );
        }

        #[test]
        fn default_plugin_path_default_to_home_and_usr() {
            assert_eq!(
                plugins(&[], Some(HOME)),
                plugin_dirs(&["/home/u/.local/share", "/usr/local/share", "/usr/share"])
            );
        }

        #[test]
        fn default_plugin_path_use_xdg_data_home_instead_of_home() {
            let vars = [("XDG_DATA_HOME", "/xdg")];
            assert_eq!(
                plugins(&vars, Some(HOME)),
                plugin_dirs(&["/xdg", "/usr/local/share", "/usr/share"])
            );
        }

        #[test]
        fn default_plugin_path_ignore_empty_and_relative_xdg_data_home() {
            for value in ["", "relative"] {
                let vars = [("XDG_DATA_HOME", value)];
                assert_eq!(
                    plugins(&vars, Some(HOME)),
                    plugin_dirs(&["/home/u/.local/share", "/usr/local/share", "/usr/share"]),
                    "{value:?}"
                );
            }
        }

        #[test]
        fn default_plugin_path_without_valid_home_use_only_system_dirs() {
            for home in [None, Some(""), Some("relative")] {
                assert_eq!(
                    plugins(&[], home),
                    plugin_dirs(&["/usr/local/share", "/usr/share"]),
                    "{home:?}"
                );
            }
        }

        #[test]
        fn default_plugin_path_use_xdg_data_dirs_in_order() {
            let vars = [("XDG_DATA_DIRS", "/a:relative::/b")];
            assert_eq!(
                plugins(&vars, Some(HOME)),
                plugin_dirs(&["/home/u/.local/share", "/a", "/b"])
            );
        }

        #[test]
        fn default_plugin_path_have_no_system_dirs_if_no_xdg_data_dirs_entry_is_valid() {
            let vars = [("XDG_DATA_DIRS", "relative")];
            assert_eq!(
                plugins(&vars, Some(HOME)),
                plugin_dirs(&["/home/u/.local/share"])
            );
        }

        #[test]
        fn default_plugin_path_are_unique() {
            let vars = [(
                "XDG_DATA_DIRS",
                "/home/u/.local/share:/usr/share:/usr/share",
            )];
            assert_eq!(
                plugins(&vars, Some(HOME)),
                plugin_dirs(&["/home/u/.local/share", "/usr/share"])
            );
        }
    }

    #[cfg(windows)]
    mod windows {
        use super::*;

        fn all_folders(folder: Folder) -> PathBuf {
            let path = match folder {
                Folder::LocalAppData => r"C:\local",
                Folder::RoamingAppData => r"C:\roaming",
                Folder::ProgramData => r"C:\ProgramData",
            };
            PathBuf::from(path)
        }

        #[test]
        fn search_paths_use_known_folders_in_order() {
            assert_eq!(
                search_paths(|f| Some(all_folders(f))),
                [
                    PathBuf::from(r"C:\local\reginald\config.toml"),
                    PathBuf::from(r"C:\roaming\reginald\config.toml"),
                    PathBuf::from(r"C:\ProgramData\reginald\config.toml"),
                ]
            );
        }

        #[test]
        fn search_paths_skip_missing_known_folders() {
            let folder =
                |f| matches!(f, Folder::RoamingAppData).then(|| PathBuf::from(r"C:\roaming"));
            assert_eq!(
                search_paths(folder),
                [PathBuf::from(r"C:\roaming\reginald\config.toml")]
            );
        }

        #[test]
        fn search_paths_are_unique() {
            let folder = |_| Some(PathBuf::from(r"C:\shared"));
            assert_eq!(
                search_paths(folder),
                [PathBuf::from(r"C:\shared\reginald\config.toml")]
            );
        }

        #[test]
        fn default_plugin_path_use_local_and_shared_known_folders() {
            assert_eq!(
                default_plugin_path(|f| Some(all_folders(f))),
                [
                    PathBuf::from(r"C:\local\reginald\plugins"),
                    PathBuf::from(r"C:\ProgramData\reginald\plugins"),
                ]
            );
        }

        #[test]
        fn default_plugin_path_skip_missing_known_folders() {
            let folder =
                |f| matches!(f, Folder::ProgramData).then(|| PathBuf::from(r"C:\ProgramData"));
            assert_eq!(
                default_plugin_path(folder),
                [PathBuf::from(r"C:\ProgramData\reginald\plugins")]
            );
        }

        #[test]
        fn default_plugin_path_are_unique() {
            let folder = |_| Some(PathBuf::from(r"C:\shared"));
            assert_eq!(
                default_plugin_path(folder),
                [PathBuf::from(r"C:\shared\reginald\plugins")]
            );
        }
    }
}
