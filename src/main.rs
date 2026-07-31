mod protocol;
mod receiver;

#[cfg(windows)]
mod windows;

use anyhow::{Result, bail};
use std::path::PathBuf;

enum ReceiverMode {
    Run(Option<PathBuf>),
    PrintDirectory(Option<PathBuf>),
    PrintCapabilities,
}

fn main() -> Result<()> {
    let mut args = std::env::args().skip(1);
    match args.next().as_deref() {
        Some("receiver") => match receiver_mode(args.collect())? {
            ReceiverMode::Run(directory) => receiver::run(directory),
            ReceiverMode::PrintDirectory(directory) => receiver::print_directory(directory),
            ReceiverMode::PrintCapabilities => {
                println!("{}", protocol::CAPABILITIES);
                Ok(())
            }
        },
        Some("doctor") => run_doctor(args.next().map(PathBuf::from)),
        Some("--version" | "-V") => {
            println!("opencode-ssh-image-paste {}", env!("CARGO_PKG_VERSION"));
            Ok(())
        }
        Some("client") | None => run_client(args.next().map(PathBuf::from)),
        Some(command) => bail!("unknown command: {command}"),
    }
}

fn receiver_mode(args: Vec<String>) -> Result<ReceiverMode> {
    match args.as_slice() {
        [] => Ok(ReceiverMode::Run(None)),
        [flag] if flag == "--print-directory" => Ok(ReceiverMode::PrintDirectory(None)),
        [flag] if flag == "--capabilities" => Ok(ReceiverMode::PrintCapabilities),
        [flag, value] if flag == "--dir" => Ok(ReceiverMode::Run(Some(PathBuf::from(value)))),
        [print, flag, value] if print == "--print-directory" && flag == "--dir" => {
            Ok(ReceiverMode::PrintDirectory(Some(PathBuf::from(value))))
        }
        _ => bail!(
            "usage: opencode-ssh-image-paste receiver [--print-directory | --capabilities] [--dir PATH]"
        ),
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_receiver_capabilities_mode() {
        assert!(matches!(
            receiver_mode(vec!["--capabilities".into()]).unwrap(),
            ReceiverMode::PrintCapabilities
        ));
    }

    #[test]
    fn rejects_capabilities_with_a_directory() {
        assert!(
            receiver_mode(vec!["--capabilities".into(), "--dir".into(), "/tmp".into()]).is_err()
        );
    }
}
