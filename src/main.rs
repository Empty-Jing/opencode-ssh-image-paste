mod protocol;
mod receiver;

#[cfg(windows)]
mod windows;

use anyhow::{Result, bail};
use std::path::PathBuf;

fn main() -> Result<()> {
    let mut args = std::env::args().skip(1);
    match args.next().as_deref() {
        Some("receiver") => receiver::run(receiver_dir(args.collect())?),
        Some("doctor") => run_doctor(args.next().map(PathBuf::from)),
        Some("--version" | "-V") => {
            println!("opencode-ssh-image-paste {}", env!("CARGO_PKG_VERSION"));
            Ok(())
        }
        Some("client") | None => run_client(args.next().map(PathBuf::from)),
        Some(command) => bail!("unknown command: {command}"),
    }
}

fn receiver_dir(args: Vec<String>) -> Result<Option<PathBuf>> {
    match args.as_slice() {
        [] => Ok(None),
        [flag, value] if flag == "--dir" => Ok(Some(PathBuf::from(value))),
        _ => bail!("usage: opencode-ssh-image-paste receiver [--dir PATH]"),
    }
}

#[cfg(windows)]
fn run_client(config: Option<PathBuf>) -> Result<()> {
    windows::run(config)
}

#[cfg(not(windows))]
fn run_client(_config: Option<PathBuf>) -> Result<()> {
    bail!("client mode is only supported on Windows; use receiver mode on this platform")
}

#[cfg(windows)]
fn run_doctor(config: Option<PathBuf>) -> Result<()> {
    windows::doctor(config)
}

#[cfg(not(windows))]
fn run_doctor(_config: Option<PathBuf>) -> Result<()> {
    bail!("doctor mode is only supported on Windows")
}
