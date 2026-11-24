use std::path::PathBuf;

use clap::{Parser, Subcommand};

#[derive(Debug, Parser)]
#[command(version)]
pub struct Cli {
    #[command(subcommand)]
    command: Option<Command>,
    #[arg(short, long = "config")]
    config_file: Option<PathBuf>,
    #[arg(short = 'C', long = "chdir", default_value = ".")]
    working_directory: PathBuf,
}

#[derive(Debug, Subcommand)]
enum Command {
    Apply {
        #[arg(short = 'n', long)]
        dry_run: bool,
    },
}
