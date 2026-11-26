use std::path::PathBuf;

use clap::{ArgAction, Parser, Subcommand};

use crate::logger::LogLevel;

#[derive(Debug, Parser)]
#[command(disable_version_flag = false)]
pub struct Cli {
    #[command(subcommand)]
    pub command: Option<Command>,

    /// Path to the config file. Default is to search from the default paths.
    #[arg(short, long = "config", global = true, value_name = "FILE")]
    pub config_file: Option<PathBuf>,

    /// Set the log level.
    #[arg(long, value_name = "LEVEL", global = true, conflicts_with_all = ["quiet", "verbose"])]
    pub log_level: Option<LogLevel>,

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
}
