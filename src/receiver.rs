use crate::protocol::{self, Request, Response};
use anyhow::{Context, Result};
use std::fs::{self, File, OpenOptions};
use std::io::{BufReader, BufWriter};
use std::path::{Path, PathBuf};
use std::thread;
use std::time::{Duration, Instant, SystemTime};

const MAX_AGE: Duration = Duration::from_secs(24 * 60 * 60);
const PNG_SIGNATURE: &[u8; 8] = b"\x89PNG\r\n\x1a\n";
const RECEIVER_LOCK_FILE: &str = ".receiver.lock";
const RECEIVER_LOCK_WAIT: Duration = Duration::from_secs(1);
const RECEIVER_LOCK_POLL: Duration = Duration::from_millis(25);

pub fn run(directory: Option<PathBuf>) -> Result<()> {
    let directory = prepare_directory(directory)?;
    let receiver_lock = acquire_receiver_lock(&directory)?;
    cleanup(&directory);
    let cleanup_directory = directory.clone();
    thread::spawn(move || {
        loop {
            thread::sleep(Duration::from_secs(60 * 60));
            cleanup(&cleanup_directory);
        }
    });

    let mut next_slot = initial_slot(&directory)?;
    let mut input = BufReader::new(std::io::stdin().lock());
    let mut output = BufWriter::new(std::io::stdout().lock());
    while let Some(request) = protocol::read_request(&mut input).context("read request")? {
        let id = request.id;
        let result = store(&directory, request, &mut next_slot)
            .map(|path| path.to_string_lossy().into_owned());
        protocol::write_response(
            &mut output,
            &Response {
                id,
                result: result.map_err(|error| format!("{error:#}")),
            },
        )
        .context("write response")?;
    }
    drop(receiver_lock);
    Ok(())
}

pub fn print_directory(directory: Option<PathBuf>) -> Result<()> {
    let directory = prepare_directory(directory)?;
    println!("{}", directory.display());
    Ok(())
}

fn prepare_directory(directory: Option<PathBuf>) -> Result<PathBuf> {
    let directory = directory.unwrap_or_else(default_directory);
    ensure_directory(&directory)?;
    fs::canonicalize(&directory).with_context(|| format!("resolve {}", directory.display()))
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

fn acquire_receiver_lock(directory: &Path) -> Result<File> {
    let path = directory.join(RECEIVER_LOCK_FILE);
    match fs::symlink_metadata(&path) {
        Ok(metadata) => anyhow::ensure!(
            metadata.file_type().is_file(),
            "receiver lock {} is not a regular file; remove it before starting the receiver",
            path.display()
        ),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => {
            return Err(error).with_context(|| format!("inspect receiver lock {}", path.display()));
        }
    }

    let mut options = OpenOptions::new();
    options.read(true).write(true).create(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let file = options
        .open(&path)
        .with_context(|| format!("open receiver lock {}", path.display()))?;
    anyhow::ensure!(
        file.metadata()
            .with_context(|| format!("inspect receiver lock {}", path.display()))?
            .is_file(),
        "receiver lock {} is not a regular file; remove it before starting the receiver",
        path.display()
    );
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        file.set_permissions(fs::Permissions::from_mode(0o600))
            .with_context(|| format!("set permissions on receiver lock {}", path.display()))?;
    }

    let started = Instant::now();
    loop {
        match file.try_lock() {
            Ok(()) => return Ok(file),
            Err(std::fs::TryLockError::WouldBlock) => {
                let elapsed = started.elapsed();
                if elapsed >= RECEIVER_LOCK_WAIT {
                    anyhow::bail!(
                        "another receiver is still using {} after waiting {} ms; stop it before starting a second receiver",
                        directory.display(),
                        RECEIVER_LOCK_WAIT.as_millis()
                    );
                }
                thread::sleep(RECEIVER_LOCK_POLL.min(RECEIVER_LOCK_WAIT - elapsed));
            }
            Err(std::fs::TryLockError::Error(error)) => {
                return Err(error)
                    .with_context(|| format!("lock receiver directory {}", directory.display()));
            }
        }
    }
}

struct TemporaryPathGuard {
    path: Option<PathBuf>,
}

impl TemporaryPathGuard {
    fn new(path: PathBuf) -> Self {
        Self { path: Some(path) }
    }

    fn persist(mut self) {
        self.path.take();
    }
}

impl Drop for TemporaryPathGuard {
    fn drop(&mut self) {
        if let Some(path) = self.path.take() {
            let _ = fs::remove_file(path);
        }
    }
}

fn store(directory: &Path, request: Request, next_slot: &mut usize) -> Result<PathBuf> {
    anyhow::ensure!(
        request.png.starts_with(PNG_SIGNATURE),
        "payload is not a PNG image"
    );
    let slot = *next_slot;
    let path = image_slot_path(directory, slot);
    for attempt in 0..100_u32 {
        let temporary = directory.join(format!(
            ".image-{slot:02}-{}-{}-{attempt}.tmp",
            std::process::id(),
            request.id
        ));
        let mut options = OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        match options.open(&temporary) {
            Ok(mut file) => {
                use std::io::Write;
                let temporary_guard = TemporaryPathGuard::new(temporary.clone());
                let write_result = file.write_all(&request.png);
                drop(file);
                write_result.with_context(|| format!("write {}", temporary.display()))?;
                fs::rename(&temporary, &path).with_context(|| {
                    format!("replace {} with {}", path.display(), temporary.display())
                })?;
                temporary_guard.persist();
                *next_slot = (slot + 1) % protocol::IMAGE_SLOT_COUNT;
                return Ok(path);
            }
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(error) => {
                return Err(error).with_context(|| format!("create {}", temporary.display()));
            }
        }
    }
    anyhow::bail!("could not allocate a temporary image path")
}

fn image_slot_path(directory: &Path, slot: usize) -> PathBuf {
    directory.join(format!("image-{slot:02}.png"))
}

fn initial_slot(directory: &Path) -> Result<usize> {
    let mut oldest: Option<(usize, SystemTime)> = None;
    for slot in 0..protocol::IMAGE_SLOT_COUNT {
        let path = image_slot_path(directory, slot);
        let metadata = match fs::symlink_metadata(&path) {
            Ok(metadata) => metadata,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(slot),
            Err(error) => {
                return Err(error)
                    .with_context(|| format!("inspect managed image slot {}", path.display()));
            }
        };
        anyhow::ensure!(
            metadata.file_type().is_file(),
            "managed image slot {} is not a regular file; remove it before starting the receiver",
            path.display()
        );
        let modified = metadata
            .modified()
            .with_context(|| format!("read modification time for {}", path.display()))?;
        if oldest.is_none_or(|(_, oldest_modified)| modified < oldest_modified) {
            oldest = Some((slot, modified));
        }
    }
    Ok(oldest.map(|(slot, _)| slot).unwrap_or(0))
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
            .is_some_and(|name| {
                (name.starts_with("clipboard-") && name.ends_with(".png"))
                    || ((name.starts_with(".latest-") || name.starts_with(".image-"))
                        && name.ends_with(".tmp"))
            });
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
    use std::process::{Child, Command, Stdio};

    const LOCK_HELPER_DIRECTORY_ENV: &str = "OPENCODE_SSH_IMAGE_PASTE_LOCK_TEST_DIR";
    const LOCK_HELPER_HOLD_MS_ENV: &str = "OPENCODE_SSH_IMAGE_PASTE_LOCK_TEST_HOLD_MS";

    struct ChildGuard(Child);

    impl Drop for ChildGuard {
        fn drop(&mut self) {
            let _ = self.0.kill();
            let _ = self.0.wait();
        }
    }

    fn temp_directory(name: &str) -> PathBuf {
        std::env::temp_dir().join(format!(
            "opencode-ssh-image-paste-{name}-{}",
            std::process::id()
        ))
    }

    fn spawn_lock_helper(directory: &Path, hold: Duration) -> ChildGuard {
        ChildGuard(
            Command::new(std::env::current_exe().unwrap())
                .args([
                    "--exact",
                    "receiver::tests::holds_receiver_lock_for_subprocess_test",
                ])
                .env(LOCK_HELPER_DIRECTORY_ENV, directory)
                .env(LOCK_HELPER_HOLD_MS_ENV, hold.as_millis().to_string())
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn()
                .unwrap(),
        )
    }

    fn wait_for_lock_helper(child: &mut ChildGuard, ready: &Path) {
        for _ in 0..200 {
            if ready.is_file() {
                return;
            }
            if let Some(status) = child.0.try_wait().unwrap() {
                panic!("receiver lock helper exited early with {status}");
            }
            thread::sleep(Duration::from_millis(10));
        }
        panic!("receiver lock helper did not become ready");
    }

    #[test]
    fn stores_png_with_private_permissions() {
        let directory = temp_directory("store");
        let _ = fs::remove_dir_all(&directory);
        ensure_directory(&directory).unwrap();
        let mut png = PNG_SIGNATURE.to_vec();
        png.extend_from_slice(b"test");
        let mut next_slot = 0;
        let path = store(
            &directory,
            Request {
                id: 7,
                png: png.clone(),
            },
            &mut next_slot,
        )
        .unwrap();
        assert_eq!(fs::read(&path).unwrap(), png);
        assert_eq!(path.file_name().unwrap(), "image-00.png");
        assert_eq!(next_slot, 1);
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
    fn keeps_fifty_images_then_reuses_the_oldest_slot() {
        let directory = temp_directory("slots");
        let _ = fs::remove_dir_all(&directory);
        ensure_directory(&directory).unwrap();
        let mut next_slot = 0;
        for id in 0..protocol::IMAGE_SLOT_COUNT as u64 {
            let mut png = PNG_SIGNATURE.to_vec();
            png.extend_from_slice(&id.to_le_bytes());
            let path = store(&directory, Request { id, png }, &mut next_slot).unwrap();
            assert_eq!(path, image_slot_path(&directory, id as usize));
        }
        assert_eq!(next_slot, 0);

        let mut replacement = PNG_SIGNATURE.to_vec();
        replacement.extend_from_slice(b"replacement");
        let path = store(
            &directory,
            Request {
                id: 51,
                png: replacement.clone(),
            },
            &mut next_slot,
        )
        .unwrap();
        assert_eq!(path, image_slot_path(&directory, 0));
        assert_eq!(fs::read(path).unwrap(), replacement);
        assert_eq!(
            fs::read_dir(&directory)
                .unwrap()
                .flatten()
                .filter(|entry| entry.path().extension().is_some_and(|value| value == "png"))
                .count(),
            protocol::IMAGE_SLOT_COUNT
        );
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn resumes_from_disk_after_receiver_restart() {
        let directory = temp_directory("resume");
        let _ = fs::remove_dir_all(&directory);
        ensure_directory(&directory).unwrap();
        let mut next_slot = 0;
        for id in 0_u64..3 {
            let mut png = PNG_SIGNATURE.to_vec();
            png.extend_from_slice(&id.to_le_bytes());
            store(&directory, Request { id, png }, &mut next_slot).unwrap();
        }

        assert_eq!(initial_slot(&directory).unwrap(), 3);
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn holds_receiver_lock_for_subprocess_test() {
        let Some(directory) = std::env::var_os(LOCK_HELPER_DIRECTORY_ENV) else {
            return;
        };
        let directory = PathBuf::from(directory);
        let _lock = acquire_receiver_lock(&directory).unwrap();
        fs::write(directory.join(".receiver-lock-ready"), b"ready").unwrap();
        let hold = std::env::var(LOCK_HELPER_HOLD_MS_ENV)
            .ok()
            .and_then(|value| value.parse().ok())
            .map(Duration::from_millis)
            .unwrap_or(Duration::from_secs(30));
        thread::sleep(hold);
    }

    #[test]
    fn waits_for_short_lived_receiver_lock() {
        let directory = temp_directory("receiver-lock-transient");
        let _ = fs::remove_dir_all(&directory);
        ensure_directory(&directory).unwrap();
        let ready = directory.join(".receiver-lock-ready");
        let mut child = spawn_lock_helper(&directory, Duration::from_millis(200));
        wait_for_lock_helper(&mut child, &ready);

        let started = Instant::now();
        let lock = acquire_receiver_lock(&directory).unwrap();
        let elapsed = started.elapsed();
        assert!(
            elapsed >= Duration::from_millis(50),
            "receiver lock returned without waiting: {elapsed:?}"
        );
        assert!(
            elapsed < RECEIVER_LOCK_WAIT,
            "receiver lock exceeded its wait budget: {elapsed:?}"
        );

        child.0.wait().unwrap();
        drop(lock);
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn times_out_when_receiver_lock_remains_held() {
        let directory = temp_directory("receiver-lock-timeout");
        let _ = fs::remove_dir_all(&directory);
        ensure_directory(&directory).unwrap();
        let ready = directory.join(".receiver-lock-ready");
        let mut child = spawn_lock_helper(&directory, Duration::from_secs(30));
        wait_for_lock_helper(&mut child, &ready);

        let started = Instant::now();
        let error = acquire_receiver_lock(&directory).unwrap_err();
        let elapsed = started.elapsed();
        assert!(
            format!("{error:#}").contains("another receiver is still using"),
            "unexpected lock error: {error:#}"
        );
        assert!(
            format!("{error:#}").contains("after waiting 1000 ms"),
            "lock error omitted the wait limit: {error:#}"
        );
        assert!(
            elapsed >= Duration::from_millis(900),
            "receiver lock timed out too early: {elapsed:?}"
        );
        assert!(
            elapsed < Duration::from_secs(2),
            "receiver lock timed out too late: {elapsed:?}"
        );

        let _ = child.0.kill();
        child.0.wait().unwrap();
        let lock = acquire_receiver_lock(&directory).unwrap();
        assert_eq!(
            fs::metadata(directory.join(RECEIVER_LOCK_FILE))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
        drop(lock);
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn rejects_non_regular_managed_slots() {
        let directory = temp_directory("invalid-slot");
        let _ = fs::remove_dir_all(&directory);
        ensure_directory(&directory).unwrap();
        let slot = image_slot_path(&directory, 0);

        fs::create_dir(&slot).unwrap();
        let error = initial_slot(&directory).unwrap_err();
        assert!(
            format!("{error:#}").contains("is not a regular file"),
            "unexpected directory error: {error:#}"
        );
        fs::remove_dir(&slot).unwrap();

        let target = directory.join("target.png");
        fs::write(&target, PNG_SIGNATURE).unwrap();
        std::os::unix::fs::symlink(&target, &slot).unwrap();
        let error = initial_slot(&directory).unwrap_err();
        assert!(
            format!("{error:#}").contains("is not a regular file"),
            "unexpected symlink error: {error:#}"
        );

        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn removes_temporary_file_when_commit_fails() {
        let directory = temp_directory("failed-commit");
        let _ = fs::remove_dir_all(&directory);
        ensure_directory(&directory).unwrap();
        fs::create_dir(image_slot_path(&directory, 0)).unwrap();
        let mut png = PNG_SIGNATURE.to_vec();
        png.extend_from_slice(b"test");
        let mut next_slot = 0;

        let error = store(&directory, Request { id: 9, png }, &mut next_slot).unwrap_err();
        assert!(
            format!("{error:#}").contains("replace"),
            "unexpected commit error: {error:#}"
        );
        assert_eq!(next_slot, 0);
        assert!(
            fs::read_dir(&directory)
                .unwrap()
                .flatten()
                .all(|entry| { !entry.file_name().to_string_lossy().starts_with(".image-") }),
            "failed commit left a temporary image behind"
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
                },
                &mut 0,
            )
            .is_err()
        );
        fs::remove_dir_all(directory).unwrap();
    }
}
