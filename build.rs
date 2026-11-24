use semver::{BuildMetadata, Version};
use versolve::cargo::Resolver;

fn main() {
    let version = Resolver::new()
        .tag_prefix("v")
        .default_branch("master")
        .branch_env("REGINALD_BUILD_BRANCH")
        .resolve()
        .unwrap();
    let version = Version {
        build: BuildMetadata::EMPTY,
        ..version
    };
    println!("cargo:rustc-env=REGINALD_VERSION={version}");
}
