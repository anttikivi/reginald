use core::fmt;
use std::{env, fs, path::Path, process::Command};

use git2::Repository;
use jiff::{Timestamp, tz::Offset};
use semver::BuildMetadata;
use serde_json::Value;
use versolve::cargo::Resolver;

fn main() {
    let mut version = Resolver::new()
        .tag_prefix("v")
        .default_branch("master")
        .branch_env("REGINALD_BUILD_BRANCH")
        .resolve()
        .unwrap();
    version.build = BuildMetadata::EMPTY;

    set("REGINALD_VERSION", version);
    set("REGINALD_TARGET", var("TARGET"));
    set("REGINALD_BUILD_HOST", var("HOST"));
    set("REGINALD_PROFILE", var("PROFILE"));

    let rustc_version = Command::new(var("RUSTC")).arg("-V").output().unwrap();
    let rustc_version = String::from_utf8(rustc_version.stdout).unwrap();
    let rustc_version = rustc_version.split_whitespace().nth(1).unwrap();

    set("REGINALD_RUSTC_VERSION", rustc_version);

    let manifest_dir = var("CARGO_MANIFEST_DIR");
    if let Some((hash, date)) = commit(Path::new(&manifest_dir)) {
        // TODO: Pass also the short hash from a Git-resolved value.
        set("REGINALD_COMMIT_HASH", hash);
        if let Some(date) = date {
            set("REGINALD_COMMIT_DATE", date);
        }
    }
}

fn commit(dir: &Path) -> Option<(String, Option<String>)> {
    if let Ok(json) = fs::read_to_string(dir.join(".cargo_vcs_info.json")) {
        let info: Value = serde_json::from_str(&json).ok()?;
        return Some((info["git"]["sha1"].as_str()?.to_owned(), None));
    }
    if dir.join("Cargo.toml.orig").exists() {
        return None;
    }

    let repo = Repository::discover(dir).ok()?;
    let rel = dir.strip_prefix(repo.workdir()?).ok()?;
    if !rel.as_os_str().is_empty() && repo.is_path_ignored(rel).ok()? {
        return None;
    }
    let commit = repo.head().ok()?.peel_to_commit().ok()?;
    let ts = Timestamp::from_second(commit.time().seconds()).ok()?;
    let date = Offset::UTC.to_datetime(ts).date().to_string();
    Some((commit.id().to_string(), Some(date)))
}

fn set(name: &str, value: impl fmt::Display) {
    println!("cargo:rustc-env={name}={value}");
}

fn var(name: &str) -> String {
    env::var(name).unwrap_or_else(|_| panic!("variable {name} not set"))
}
