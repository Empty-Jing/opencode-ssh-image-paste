use crate::protocol::{self, Request, Response};
use anyhow::{Context, Result};
use std::fs::{self, OpenOptions};
use std::io::{BufReader, BufWriter};
use std::path::{Path, PathBuf};
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

const MAX_AGE: Duration = Duration::from_secs(24 * 60 * 60);
const PNG_SIGNATURE: &[u8; 8] = b"\x89PNG\r\n\x1a\n";

pub fn run(directory: Option<PathBuf>) -> Result<()> {
    let directory = directory.unwrap_or_else(default_directory);
    ensure_directory(&directory)?;
    cleanup(&directory);
    let cleanup_directory = directory.clone();
    thread::spawn(move || {
        loop {
            thread::sleep(Duration::from_secs(60 * 60));
            cleanup(&cleanup_directory);
        }
    });

    let mut input = BufReader::new(std::io::stdin().lock());
    let mut output = BufWriter::new(std::io::stdout().lock());
    while let Some(request) = protocol::read_request(&mut input).context("read request")? {
        let id = request.id;
        let result = store(&directory, request).map(|path| path.to_string_lossy().into_owned());
        protocol::write_response(
            &mut output,
            &Response {
                id,
                result: result.map_err(|error| format!("{error:#}")),
            },
        )
        .context("write response")?;
    }
    Ok(())
}

fn default_directory() -> PathBuf {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(std::env::temp_dir)
        .join(".cache/opencode-ssh-image-paste")
}

fn ensure_directory(directory: &Path) -> Result<()> {
    fs::create_dir_all(directory).with_context(|| format!("create {}", directory.display()))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(directory, fs::Permissions::from_mode(0o700))
            .with_context(|| format!("set permissions on {}", directory.display()))?;
    }
    Ok(())
}

fn store(directory: &Path, request: Request) -> Result<PathBuf> {
    anyhow::ensure!(
        request.png.starts_with(PNG_SIGNATURE),
        "payload is not a PNG image"
    );
    cleanup(directory);
    let timestamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    for attempt in 0..100 {
        let path = directory.join(format!(
            "clipboard-{}-{timestamp}-{attempt}.png",
            request.id
        ));
        let mut options = OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        match options.open(&path) {
            Ok(mut file) => {
                use std::io::Write;
                file.write_all(&request.png)
                    .with_context(|| format!("write {}", path.display()))?;
                return Ok(path);
            }
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(error) => return Err(error).with_context(|| format!("create {}", path.display())),
        }
    }
    anyhow::bail!("could not allocate a unique image path")
}

fn cleanup(directory: &Path) {
    let Ok(entries) = fs::read_dir(directory) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        let managed = path
            .file_name()
            .and_then(|value| value.to_str())
            .is_some_and(|name| name.starts_with("clipboard-") && name.ends_with(".png"));
        if !managed {
            continue;
        }
        let stale = entry
            .metadata()
            .and_then(|metadata| metadata.modified())
            .and_then(|modified| modified.elapsed().map_err(std::io::Error::other))
            .is_ok_and(|elapsed| elapsed > MAX_AGE);
        if stale {
            let _ = fs::remove_file(path);
        }
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    fn temp_directory(name: &str) -> PathBuf {
        std::env::temp_dir().join(format!(
            "opencode-ssh-image-paste-{name}-{}",
            std::process::id()
        ))
    }

    #[test]
    fn stores_png_with_private_permissions() {
        let directory = temp_directory("store");
        let _ = fs::remove_dir_all(&directory);
        ensure_directory(&directory).unwrap();
        let mut png = PNG_SIGNATURE.to_vec();
        png.extend_from_slice(b"test");
        let path = store(
            &directory,
            Request {
                id: 7,
                png: png.clone(),
            },
        )
        .unwrap();
        assert_eq!(fs::read(&path).unwrap(), png);
        assert_eq!(
            fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );
        assert_eq!(
            fs::metadata(&directory).unwrap().permissions().mode() & 0o777,
            0o700
        );
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn rejects_non_png_payload() {
        let directory = temp_directory("invalid");
        let _ = fs::remove_dir_all(&directory);
        ensure_directory(&directory).unwrap();
        assert!(
            store(
                &directory,
                Request {
                    id: 8,
                    png: b"not png".to_vec()
                }
            )
            .is_err()
        );
        fs::remove_dir_all(directory).unwrap();
    }
}
