use std::path::PathBuf;

use clap::{ArgAction, Parser, Subcommand};
use log::LevelFilter;

use crate::logger;

#[derive(Debug, Parser)]
pub struct Cli {
    #[command(subcommand)]
    pub command: Option<Command>,

    /// Path to the config file. Resolved after applying `--chdir`. Default is
    /// to search from the default paths.
    #[arg(short, long = "config", global = true, value_name = "FILE")]
    pub config_file: Option<PathBuf>,

    /// Set the log level.
    #[arg(long, global = true, value_name = "LEVEL", value_parser = logger::level_filter_parser(), conflicts_with_all = ["quiet", "verbose"])]
    pub log_level: Option<LevelFilter>,

    #[arg(short = 'P', long, global = true, value_name = "DIR", action = ArgAction::Append)]
    pub plugin_dirs: Option<Vec<PathBuf>>,

    /// Only log errors.
    #[arg(short, long, global = true, conflicts_with = "verbose")]
    pub quiet: bool,

    /// Log more information. Specify up to three times to increase the
    /// verbosity.
    #[arg(short, long, global = true, action = ArgAction::Count)]
    pub verbose: u8,

    /// Print Reginald version information.
    #[arg(short = 'V', long, global = true)]
    pub version: bool,

    /// Run as if the process was started from the given directory.
    #[arg(short = 'C', long = "chdir", global = true, value_name = "DIR", action = ArgAction::Append)]
    pub working_directories: Vec<PathBuf>,
}

#[derive(Debug, Subcommand)]
pub enum Command {
    Apply {
        #[arg(short = 'n', long)]
        dry_run: bool,
    },
}

#[cfg(test)]
mod tests {
    use clap::CommandFactory;

    use super::*;

    #[test]
    fn command_definition_is_valid() {
        Cli::command().debug_assert();
    }

    /// Each `-C` is relative to the previous one, so all of them must be kept
    /// in order. Added as a way to catch any changes in the dependencies that
    /// would break our assumptions in the future.
    #[test]
    fn chdir_flags_keep_their_order() {
        let cli = Cli::try_parse_from(["reginald", "-C", "a", "-C", "b"]).unwrap();
        assert_eq!(cli.working_directories, [PathBuf::from("a"), "b".into()]);
    }

    #[test]
    fn log_level_flag_is_parsed() {
        let cli = Cli::try_parse_from(["reginald", "--log-level", "debug"]).unwrap();
        assert_eq!(cli.log_level, Some(LevelFilter::Debug));
    }

    #[test]
    fn log_level_flag_is_case_sensitive() {
        assert!(Cli::try_parse_from(["reginald", "--log-level", "DEBUG"]).is_err());
    }
}
