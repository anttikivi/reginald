use std::env;

use versolve::build::Config;

fn main() {
    let target = env::var("TARGET").expect("TARGET is not set");
    println!("cargo:rustc-env=REGINALD_HOST={target}");
    Config::new()
        .tag_prefix("v")
        .default_branch("master")
        .branch_env("REGINALD_BUILD_BRANCH")
        .emit("REGINALD_VERSION")
        .unwrap();
}
