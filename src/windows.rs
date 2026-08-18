use crate::protocol::{self, Request};
use anyhow::{Context, Result, bail};
use arboard::{Clipboard, ImageData};
use serde::Deserialize;
use std::borrow::Cow;
use std::fs::{self, OpenOptions};
use std::io::{BufReader, BufWriter, Write};
use std::os::windows::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, ChildStdout, Command, Output, Stdio};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{OnceLock, mpsc};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use ureq::tls::{Certificate, RootCerts, TlsConfig};
use windows_sys::Win32::Foundation::{
    CloseHandle, ERROR_ALREADY_EXISTS, GetLastError, HANDLE, LPARAM, LRESULT, SetLastError, WPARAM,
};
use windows_sys::Win32::Graphics::Gdi::{
    BI_RGB, BITMAP, BITMAPINFO, BITMAPINFOHEADER, CreateCompatibleDC, DIB_RGB_COLORS, DeleteDC,
    GetDIBits, GetObjectW,
};
use windows_sys::Win32::System::Console::FreeConsole;
use windows_sys::Win32::System::DataExchange::{
    CloseClipboard, GetClipboardData, GetClipboardSequenceNumber, IsClipboardFormatAvailable,
    OpenClipboard, RegisterClipboardFormatW,
};
use windows_sys::Win32::System::Threading::{
    CREATE_NO_WINDOW, CreateMutexW, OpenProcess, PROCESS_TERMINATE, TerminateProcess,
};
use windows_sys::Win32::UI::Input::KeyboardAndMouse::{
    GetAsyncKeyState, KEYEVENTF_KEYUP, VK_CONTROL, VK_LWIN, VK_MENU, VK_RWIN, VK_SHIFT, VK_V,
    keybd_event,
};
use windows_sys::Win32::UI::WindowsAndMessaging::{
    CallNextHookEx, DispatchMessageW, GetClassNameW, GetForegroundWindow, GetMessageW,
    KBDLLHOOKSTRUCT, MSG, SetWindowsHookExW, TranslateMessage, UnhookWindowsHookEx, WH_KEYBOARD_LL,
    WH_MOUSE_LL, WM_KEYDOWN, WM_KEYUP, WM_LBUTTONDOWN, WM_MBUTTONDOWN, WM_MOUSEWHEEL,
    WM_RBUTTONDOWN, WM_SYSKEYDOWN, WM_SYSKEYUP, WM_XBUTTONDOWN,
};

const CF_BITMAP: u32 = 2;
const CF_DIB: u32 = 8;
const CF_UNICODETEXT: u32 = 13;
const CF_DIBV5: u32 = 17;
const DEFAULT_WINDOW_CLASS: &str = "CASCADIA_HOSTING_WINDOW_CLASS";
const TIMING_LOG_MAX_BYTES: u64 = 1024 * 1024;
const TERMINAL_ACTION_ID: &str = "User.OpenCodeSSHImagePaste.AtomicPaste";
const SINGLE_INSTANCE_MUTEX_NAME: &str = "Local\\OpenCodeSSHImagePaste.Client";
const MAX_IMAGE_DIMENSION: usize = 16_384;
const MAX_IMAGE_PIXELS: usize = 64 * 1024 * 1024;
const MAX_RAW_IMAGE_BYTES: usize = MAX_IMAGE_PIXELS * 4;
const COMMAND_WAIT_POLL: Duration = Duration::from_millis(25);
const VK_F13_CODE: u16 = 0x7C;

static REQUESTS: OnceLock<mpsc::SyncSender<PasteRequest>> = OnceLock::new();
static WINDOW_CLASS: OnceLock<String> = OnceLock::new();
static PNG_FORMAT: OnceLock<u32> = OnceLock::new();
static SUPPRESS_V_UP: AtomicBool = AtomicBool::new(false);
static NEXT_REQUEST_ID: AtomicU64 = AtomicU64::new(1);
static USER_ACTIVITY: AtomicU64 = AtomicU64::new(0);

#[derive(Clone, Copy)]
struct PasteRequest {
    window: isize,
    clipboard_sequence: u32,
    user_activity: u64,
    queued_at: Instant,
}

struct PasteTiming {
    request_id: u64,
    started_at: Instant,
    queue: Duration,
    clipboard_read: Option<Duration>,
    png_encode: Option<Duration>,
    ssh_spawn: Option<Duration>,
    retry_sleep: Option<Duration>,
    upload_receiver: Option<Duration>,
    modifier_wait: Option<Duration>,
    input_guard: Option<Duration>,
    terminal_paste: Option<Duration>,
    opencode_handoff: Option<Duration>,
    opencode_handoff_unix_ms: Option<u128>,
    image_width: usize,
    image_height: usize,
    raw_bytes: usize,
    png_bytes: usize,
    transport: &'static str,
    transport_state: &'static str,
    ssh_attempts: u32,
    upload_attempts: u32,
}

impl PasteTiming {
    fn new(request_id: u64, queued_at: Instant) -> Self {
        Self {
            request_id,
            started_at: queued_at,
            queue: queued_at.elapsed(),
            clipboard_read: None,
            png_encode: None,
            ssh_spawn: None,
            retry_sleep: None,
            upload_receiver: None,
            modifier_wait: None,
            input_guard: None,
            terminal_paste: None,
            opencode_handoff: None,
            opencode_handoff_unix_ms: None,
            image_width: 0,
            image_height: 0,
            raw_bytes: 0,
            png_bytes: 0,
            transport: "not_started",
            transport_state: "not_started",
            ssh_attempts: 0,
            upload_attempts: 0,
        }
    }
}

#[derive(Clone, Copy, Debug, Default, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
enum TransportKind {
    #[default]
    Ssh,
    Https,
}

#[derive(Debug, Deserialize)]
#[serde(default)]
struct Config {
    transport: TransportKind,
    https_endpoint: String,
    https_token: String,
    https_certificate_path: PathBuf,
    ssh_target: String,
    ssh_program: String,
    ssh_arguments: Vec<String>,
    remote_command: String,
    remote_probe_command: String,
    terminal_paste_directory: String,
    terminal_window_class: String,
    request_timeout_seconds: u64,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            transport: TransportKind::Ssh,
            https_endpoint: String::new(),
            https_token: String::new(),
            https_certificate_path: PathBuf::new(),
            ssh_target: String::new(),
            ssh_program: "ssh.exe".into(),
            ssh_arguments: Vec::new(),
            remote_command: "~/.local/bin/opencode-ssh-image-paste receiver".into(),
            remote_probe_command: "~/.local/bin/opencode-ssh-image-paste receiver --capabilities"
                .into(),
            terminal_paste_directory: String::new(),
            terminal_window_class: DEFAULT_WINDOW_CLASS.into(),
            request_timeout_seconds: 15,
        }
    }
}

fn validate_https_config(config: &Config) -> Result<()> {
    anyhow::ensure!(
        config.https_endpoint.starts_with("https://"),
        "https_endpoint must use https://"
    );
    anyhow::ensure!(
        !config.https_endpoint.ends_with('/'),
        "https_endpoint must not end with '/'"
    );
    let authority = &config.https_endpoint["https://".len()..];
    anyhow::ensure!(
        !authority.is_empty()
            && !authority.contains('@')
            && !authority.contains(['/', '?', '#'])
            && !authority.chars().any(char::is_control),
        "https_endpoint must contain only an HTTPS origin without credentials, path, query, or fragment"
    );
    anyhow::ensure!(
        config.https_token.len() == 64
            && config
                .https_token
                .bytes()
                .all(|byte| byte.is_ascii_hexdigit()),
        "https_token must be exactly 32 bytes encoded as 64 hexadecimal characters"
    );
    anyhow::ensure!(
        config.https_certificate_path.is_file(),
        "https_certificate_path is not a readable file: {}",
        config.https_certificate_path.display()
    );
    Ok(())
}

fn validate_ssh_target(target: &str) -> Result<()> {
    anyhow::ensure!(!target.trim().is_empty(), "ssh_target must not be empty");
    anyhow::ensure!(
        !target.starts_with('-'),
        "ssh_target must not start with '-'"
    );
    anyhow::ensure!(
        !target.chars().any(char::is_control),
        "ssh_target must not contain control characters"
    );
    Ok(())
}

fn configure_ssh_options(
    command: &mut Command,
    user_arguments: &[String],
    connect_timeout_seconds: u64,
    keepalive: bool,
) {
    command
        .arg("-o")
        .arg("BatchMode=yes")
        .arg("-o")
        .arg(format!("ConnectTimeout={connect_timeout_seconds}"));
    if keepalive {
        command.args(["-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=2"]);
    }
    // OpenSSH keeps the first value obtained for most options. Append user
    // arguments so -F/-J remain available without allowing later -o values to
    // override the non-interactive and timeout guarantees above.
    command.args(user_arguments);
}

enum TimedCommandOutput {
    Completed(Output),
    TimedOut,
}

fn command_output_with_timeout(
    command: &mut Command,
    timeout: Duration,
) -> Result<TimedCommandOutput> {
    let mut child = command.spawn().context("start timed child process")?;
    let started = Instant::now();
    loop {
        if child
            .try_wait()
            .context("poll timed child process")?
            .is_some()
        {
            return child
                .wait_with_output()
                .map(TimedCommandOutput::Completed)
                .context("collect timed child process output");
        }

        let elapsed = started.elapsed();
        if elapsed >= timeout {
            if let Err(kill_error) = child.kill()
                && child
                    .try_wait()
                    .context("check timed child process after termination failure")?
                    .is_none()
            {
                return Err(kill_error).context("terminate timed out child process");
            }
            child
                .wait_with_output()
                .context("reap timed out child process")?;
            return Ok(TimedCommandOutput::TimedOut);
        }
        thread::sleep(COMMAND_WAIT_POLL.min(timeout - elapsed));
    }
}

struct SingleInstanceGuard(HANDLE);

fn single_instance_mutex_name() -> Vec<u16> {
    SINGLE_INSTANCE_MUTEX_NAME
        .encode_utf16()
        .chain(std::iter::once(0))
        .collect()
}

fn client_single_instance_lock_exists() -> Result<bool> {
    let name = single_instance_mutex_name();
    unsafe { SetLastError(0) };
    let handle = unsafe { CreateMutexW(std::ptr::null(), 0, name.as_ptr()) };
    if handle.is_null() {
        return Err(std::io::Error::last_os_error())
            .context("open the Windows client single-instance mutex");
    }
    let exists = unsafe { GetLastError() } == ERROR_ALREADY_EXISTS;
    unsafe { CloseHandle(handle) };
    Ok(exists)
}

impl SingleInstanceGuard {
    fn acquire() -> Result<Self> {
        let name = single_instance_mutex_name();
        unsafe { SetLastError(0) };
        let handle = unsafe { CreateMutexW(std::ptr::null(), 0, name.as_ptr()) };
        if handle.is_null() {
            return Err(std::io::Error::last_os_error())
                .context("create the Windows client single-instance mutex");
        }
        if unsafe { GetLastError() } == ERROR_ALREADY_EXISTS {
            unsafe { CloseHandle(handle) };
            bail!("another opencode SSH image paste client is already running")
        }
        Ok(Self(handle))
    }
}

impl Drop for SingleInstanceGuard {
    fn drop(&mut self) {
        unsafe {
            CloseHandle(self.0);
        }
    }
}

pub fn run(config_path: Option<PathBuf>) -> Result<()> {
    let _single_instance = SingleInstanceGuard::acquire()?;
    // Client mode is a background process. The same executable remains a console
    // application so commands such as `doctor` can print useful diagnostics.
    unsafe { FreeConsole() };
    let config_path = config_path.unwrap_or_else(default_config_path);
    let config = load_config(&config_path)?;
    match config.transport {
        TransportKind::Ssh => validate_ssh_target(&config.ssh_target)
            .with_context(|| format!("invalid ssh_target in {}", config_path.display()))?,
        TransportKind::Https => validate_https_config(&config)
            .with_context(|| format!("invalid HTTPS transport in {}", config_path.display()))?,
    }
    anyhow::ensure!(
        config.request_timeout_seconds > 0,
        "request_timeout_seconds must be positive"
    );
    anyhow::ensure!(
        is_safe_remote_directory(&config.terminal_paste_directory),
        "terminal_paste_directory must be a safe absolute Linux path; rerun bootstrap.ps1 to install the Windows Terminal actions"
    );
    WINDOW_CLASS
        .set(config.terminal_window_class.clone())
        .map_err(|_| anyhow::anyhow!("window class was already configured"))?;
    let png = "PNG\0".encode_utf16().collect::<Vec<_>>();
    let png_format = unsafe { RegisterClipboardFormatW(png.as_ptr()) };
    anyhow::ensure!(
        png_format != 0,
        "could not register the PNG clipboard format"
    );
    PNG_FORMAT
        .set(png_format)
        .map_err(|_| anyhow::anyhow!("PNG clipboard format was already registered"))?;

    let (sender, receiver) = mpsc::sync_channel(3);
    REQUESTS
        .set(sender)
        .map_err(|_| anyhow::anyhow!("keyboard hook was already initialized"))?;
    let timing_log = timing_log_path(&config_path);
    thread::spawn(move || worker(receiver, config, timing_log));

    eprintln!("opencode SSH image paste is running; Ctrl+V image interception is active");
    run_keyboard_hook()
}

pub fn doctor(config_path: Option<PathBuf>) -> Result<()> {
    let config_path = config_path.unwrap_or_else(default_config_path);
    let mut failures = 0_u32;

    check(
        "Configuration file",
        config_path.is_file(),
        &config_path.display().to_string(),
        &mut failures,
    );
    let config = match load_config(&config_path) {
        Ok(config) => {
            check("Configuration syntax", true, "valid TOML", &mut failures);
            config
        }
        Err(error) => {
            check(
                "Configuration syntax",
                false,
                &format!("{error:#}"),
                &mut failures,
            );
            anyhow::bail!("doctor found {failures} problem(s)");
        }
    };
    check(
        "Upload transport",
        true,
        match config.transport {
            TransportKind::Ssh => "ssh (legacy explicit mode)",
            TransportKind::Https => "https",
        },
        &mut failures,
    );
    let target_error = validate_ssh_target(&config.ssh_target)
        .err()
        .map(|error| format!("{error:#}"));
    check(
        "SSH target",
        target_error.is_none(),
        target_error.as_deref().unwrap_or(&config.ssh_target),
        &mut failures,
    );
    let timeout_valid = config.request_timeout_seconds > 0;
    check(
        "Request timeout",
        timeout_valid,
        if timeout_valid {
            "positive"
        } else {
            "request_timeout_seconds must be positive"
        },
        &mut failures,
    );

    let ssh_version = Command::new(&config.ssh_program)
        .arg("-V")
        .creation_flags(CREATE_NO_WINDOW)
        .output();
    match ssh_version {
        Ok(output) if output.status.success() => {
            let version = String::from_utf8_lossy(if output.stderr.is_empty() {
                &output.stdout
            } else {
                &output.stderr
            });
            check("OpenSSH client", true, version.trim(), &mut failures);
        }
        Ok(output) => check(
            "OpenSSH client",
            false,
            &format!("{} exited with {}", config.ssh_program, output.status),
            &mut failures,
        ),
        Err(error) => check(
            "OpenSSH client",
            false,
            &format!("could not run {}: {error}", config.ssh_program),
            &mut failures,
        ),
    }

    let terminal_available = Command::new("where.exe")
        .arg("wt.exe")
        .creation_flags(CREATE_NO_WINDOW)
        .status()
        .is_ok_and(|status| status.success())
        || std::env::var_os("LOCALAPPDATA").is_some_and(|base| {
            PathBuf::from(base)
                .join("Microsoft/WindowsApps/wt.exe")
                .is_file()
        });
    check(
        "Windows Terminal",
        terminal_available,
        if terminal_available {
            "wt.exe found"
        } else {
            "wt.exe was not found"
        },
        &mut failures,
    );

    match terminal_action_status(&config.terminal_paste_directory) {
        Ok(detail) => check(
            "Windows Terminal paste action",
            true,
            &detail,
            &mut failures,
        ),
        Err(error) => check(
            "Windows Terminal paste action",
            false,
            &format!("{error:#}"),
            &mut failures,
        ),
    }

    if config.transport == TransportKind::Https && timeout_valid {
        let https_error = validate_https_config(&config)
            .and_then(|()| HttpsTransport::new(&config))
            .and_then(|transport| {
                let capabilities = transport.capabilities()?;
                anyhow::ensure!(
                    receiver_capabilities_are_compatible(capabilities.as_bytes()),
                    "receiver capabilities are incompatible; rerun bootstrap.ps1"
                );
                Ok(())
            })
            .err()
            .map(|error| format!("{error:#}"));
        check(
            "HTTPS receiver",
            https_error.is_none(),
            https_error
                .as_deref()
                .unwrap_or("TLS, bearer authentication, and capability check succeeded"),
            &mut failures,
        );
    }

    if config.transport == TransportKind::Ssh && target_error.is_none() && timeout_valid {
        let mut remote = Command::new(&config.ssh_program);
        configure_ssh_options(
            &mut remote,
            &config.ssh_arguments,
            config.request_timeout_seconds,
            false,
        );
        remote
            .arg("-T")
            .arg(&config.ssh_target)
            .arg(&config.remote_probe_command)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .creation_flags(CREATE_NO_WINDOW);
        match command_output_with_timeout(
            &mut remote,
            Duration::from_secs(config.request_timeout_seconds),
        ) {
            Ok(TimedCommandOutput::Completed(output)) if output.status.success() => {
                let compatible = receiver_capabilities_are_compatible(&output.stdout);
                check(
                    "Remote receiver",
                    compatible,
                    if compatible {
                        "SSH connection and receiver capability check succeeded"
                    } else {
                        "receiver capabilities are incompatible; rerun bootstrap.ps1 to install matching binaries"
                    },
                    &mut failures,
                );
            }
            Ok(TimedCommandOutput::Completed(output)) => {
                let detail = String::from_utf8_lossy(&output.stderr);
                check(
                    "Remote receiver",
                    false,
                    if detail.trim().is_empty() {
                        "SSH connection or receiver startup failed"
                    } else {
                        detail.trim()
                    },
                    &mut failures,
                );
            }
            Ok(TimedCommandOutput::TimedOut) => check(
                "Remote receiver",
                false,
                &format!(
                    "SSH capability check timed out after {} second(s); the process was terminated",
                    config.request_timeout_seconds
                ),
                &mut failures,
            ),
            Err(error) => check(
                "Remote receiver",
                false,
                &format!("SSH capability check failed: {error:#}"),
                &mut failures,
            ),
        }
    }

    let process_count = Command::new("tasklist.exe")
        .args([
            "/FI",
            "IMAGENAME eq opencode-ssh-image-paste.exe",
            "/FO",
            "CSV",
            "/NH",
        ])
        .creation_flags(CREATE_NO_WINDOW)
        .output()
        .ok()
        .map(|output| {
            String::from_utf8_lossy(&output.stdout)
                .lines()
                .filter(|line| {
                    line.to_ascii_lowercase()
                        .contains("opencode-ssh-image-paste.exe")
                })
                .count()
        })
        .unwrap_or_default();
    let client_lock = client_single_instance_lock_exists();
    let process_detail = match (process_count, &client_lock) {
        (2, Ok(true)) => "client process and single-instance lock are present".to_owned(),
        (0 | 1, _) => "client process was not found".to_owned(),
        (count, _) if count > 2 => format!(
            "found {count} same-name processes; expected this doctor process plus exactly one client"
        ),
        (_, Ok(false)) => {
            "same-name process found, but the client single-instance lock is absent".to_owned()
        }
        (_, Err(error)) => format!("could not inspect the client single-instance lock: {error:#}"),
        _ => "client process state is inconsistent".to_owned(),
    };
    check(
        "Background client",
        process_count == 2 && matches!(client_lock, Ok(true)),
        &process_detail,
        &mut failures,
    );
    println!(
        "[INFO] Timing log: {}",
        timing_log_path(&config_path).display()
    );

    if failures == 0 {
        println!("\nAll checks passed. Copy an image, focus Windows Terminal, and press Ctrl+V.");
        Ok(())
    } else {
        anyhow::bail!("doctor found {failures} problem(s)")
    }
}

fn receiver_capabilities_are_compatible(output: &[u8]) -> bool {
    String::from_utf8_lossy(output).trim() == protocol::CAPABILITIES
}

fn check(name: &str, passed: bool, detail: &str, failures: &mut u32) {
    if passed {
        println!("[OK]   {name}: {detail}");
    } else {
        println!("[FAIL] {name}: {detail}");
        *failures += 1;
    }
}

fn terminal_action_status(remote_directory: &str) -> Result<String> {
    anyhow::ensure!(
        is_safe_remote_directory(remote_directory),
        "terminal_paste_directory is not a safe absolute Linux path; rerun bootstrap.ps1"
    );
    let settings = windows_terminal_settings_paths();
    anyhow::ensure!(
        !settings.is_empty(),
        "Windows Terminal settings.json was not found; open Windows Terminal once, then rerun bootstrap.ps1"
    );

    let mut configured = Vec::new();
    for path in &settings {
        let Ok(content) = fs::read_to_string(path) else {
            continue;
        };
        let complete = (0..protocol::IMAGE_SLOT_COUNT).all(|slot| {
            content.contains(&terminal_action_id(slot))
                && content.contains(&remote_slot_path(remote_directory, slot))
        });
        if complete {
            configured.push(path.display().to_string());
        }
    }
    anyhow::ensure!(
        !configured.is_empty(),
        "one or more {TERMINAL_ACTION_ID} slot actions for {remote_directory:?} are missing; rerun bootstrap.ps1"
    );
    Ok(format!("configured in {}", configured.join(", ")))
}

fn is_safe_remote_directory(path: &str) -> bool {
    path.starts_with('/') && !path.ends_with('/') && !path.chars().any(char::is_control)
}

fn remote_slot_path(directory: &str, slot: usize) -> String {
    format!("{directory}/image-{slot:02}.png")
}

fn terminal_action_id(slot: usize) -> String {
    format!("{TERMINAL_ACTION_ID}.Slot{slot:02}")
}

fn windows_terminal_settings_paths() -> Vec<PathBuf> {
    let Some(local_app_data) = std::env::var_os("LOCALAPPDATA").map(PathBuf::from) else {
        return Vec::new();
    };
    let mut paths = Vec::new();
    let packages = local_app_data.join("Packages");
    if let Ok(entries) = fs::read_dir(packages) {
        for entry in entries.flatten() {
            let name = entry.file_name();
            if !name
                .to_string_lossy()
                .starts_with("Microsoft.WindowsTerminal")
            {
                continue;
            }
            let path = entry.path().join("LocalState/settings.json");
            if path.is_file() {
                paths.push(path);
            }
        }
    }
    let unpackaged = local_app_data.join("Microsoft/Windows Terminal/settings.json");
    if unpackaged.is_file() {
        paths.push(unpackaged);
    }
    paths.sort();
    paths.dedup();
    paths
}

fn default_config_path() -> PathBuf {
    std::env::var_os("APPDATA")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."))
        .join("OpenCodeSSHImagePaste/config.toml")
}

fn timing_log_path(config_path: &Path) -> PathBuf {
    config_path
        .parent()
        .unwrap_or_else(|| Path::new("."))
        .join("timing.log")
}

fn load_config(path: &Path) -> Result<Config> {
    toml::from_str(&fs::read_to_string(path).with_context(|| format!("read {}", path.display()))?)
        .with_context(|| format!("parse {}", path.display()))
}

fn run_keyboard_hook() -> Result<()> {
    let keyboard_hook =
        unsafe { SetWindowsHookExW(WH_KEYBOARD_LL, Some(keyboard_hook), std::ptr::null_mut(), 0) };
    if keyboard_hook.is_null() {
        bail!("could not install the Windows low-level keyboard hook")
    }
    let mouse_hook =
        unsafe { SetWindowsHookExW(WH_MOUSE_LL, Some(mouse_hook), std::ptr::null_mut(), 0) };
    if mouse_hook.is_null() {
        unsafe { UnhookWindowsHookEx(keyboard_hook) };
        bail!("could not install the Windows low-level mouse hook")
    }
    let mut message: MSG = unsafe { std::mem::zeroed() };
    let message_result = loop {
        let result = unsafe { GetMessageW(&mut message, std::ptr::null_mut(), 0, 0) };
        if result == -1 {
            break Err(std::io::Error::last_os_error()).context("read the Windows message queue");
        }
        if result == 0 {
            break Ok(());
        }
        unsafe {
            TranslateMessage(&message);
            DispatchMessageW(&message);
        }
    };
    unsafe {
        UnhookWindowsHookEx(mouse_hook);
        UnhookWindowsHookEx(keyboard_hook);
    }
    message_result
}

unsafe extern "system" fn keyboard_hook(code: i32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    if code < 0 {
        return unsafe { CallNextHookEx(std::ptr::null_mut(), code, wparam, lparam) };
    }
    let event = unsafe { &*(lparam as *const KBDLLHOOKSTRUCT) };
    let key_down = wparam as u32 == WM_KEYDOWN || wparam as u32 == WM_SYSKEYDOWN;
    if event.vkCode != u32::from(VK_V) {
        if key_down {
            USER_ACTIVITY.fetch_add(1, Ordering::SeqCst);
        }
        return unsafe { CallNextHookEx(std::ptr::null_mut(), code, wparam, lparam) };
    }

    let key_up = wparam as u32 == WM_KEYUP || wparam as u32 == WM_SYSKEYUP;
    if key_up && SUPPRESS_V_UP.swap(false, Ordering::SeqCst) {
        return 1;
    }
    if !key_down || !paste_chord_is_exact() || !clipboard_has_image_without_text() {
        if key_down {
            USER_ACTIVITY.fetch_add(1, Ordering::SeqCst);
        }
        return unsafe { CallNextHookEx(std::ptr::null_mut(), code, wparam, lparam) };
    }

    let window = unsafe { GetForegroundWindow() };
    if window.is_null() || !is_target_window(window) {
        return unsafe { CallNextHookEx(std::ptr::null_mut(), code, wparam, lparam) };
    }
    if SUPPRESS_V_UP.swap(true, Ordering::SeqCst) {
        return 1;
    }
    let request = PasteRequest {
        window: window as isize,
        clipboard_sequence: unsafe { GetClipboardSequenceNumber() },
        user_activity: USER_ACTIVITY.load(Ordering::SeqCst),
        queued_at: Instant::now(),
    };
    if REQUESTS
        .get()
        .is_some_and(|sender| sender.try_send(request).is_ok())
    {
        return 1;
    }
    SUPPRESS_V_UP.store(false, Ordering::SeqCst);
    unsafe { CallNextHookEx(std::ptr::null_mut(), code, wparam, lparam) }
}

unsafe extern "system" fn mouse_hook(code: i32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    if code >= 0
        && matches!(
            wparam as u32,
            WM_LBUTTONDOWN | WM_RBUTTONDOWN | WM_MBUTTONDOWN | WM_XBUTTONDOWN | WM_MOUSEWHEEL
        )
    {
        USER_ACTIVITY.fetch_add(1, Ordering::SeqCst);
    }
    unsafe { CallNextHookEx(std::ptr::null_mut(), code, wparam, lparam) }
}

fn key_is_down(key: u16) -> bool {
    (unsafe { GetAsyncKeyState(i32::from(key)) }) < 0
}

fn paste_chord_is_exact() -> bool {
    key_is_down(VK_CONTROL)
        && ![VK_SHIFT, VK_MENU, VK_LWIN, VK_RWIN]
            .into_iter()
            .any(key_is_down)
}

fn clipboard_has_image_without_text() -> bool {
    if unsafe { IsClipboardFormatAvailable(CF_UNICODETEXT) } != 0 {
        return false;
    }
    let png = PNG_FORMAT.get().copied().unwrap_or_default();
    unsafe {
        IsClipboardFormatAvailable(CF_BITMAP) != 0
            || IsClipboardFormatAvailable(CF_DIB) != 0
            || IsClipboardFormatAvailable(CF_DIBV5) != 0
            || (png != 0 && IsClipboardFormatAvailable(png) != 0)
    }
}

fn is_target_window(window: *mut core::ffi::c_void) -> bool {
    let mut class = [0_u16; 256];
    let length = unsafe { GetClassNameW(window, class.as_mut_ptr(), class.len() as i32) };
    length > 0
        && WINDOW_CLASS.get().is_some_and(|expected| {
            String::from_utf16_lossy(&class[..length as usize]).eq_ignore_ascii_case(expected)
        })
}

fn worker(receiver: mpsc::Receiver<PasteRequest>, config: Config, timing_log: PathBuf) {
    let mut transport = match build_transport(&config) {
        Ok(transport) => transport,
        Err(error) => {
            eprintln!("could not initialize image transport: {error:#}");
            return;
        }
    };
    for request in receiver {
        let request_id = NEXT_REQUEST_ID.fetch_add(1, Ordering::Relaxed);
        let mut timing = PasteTiming::new(request_id, request.queued_at);
        match handle_paste(
            request,
            request_id,
            &config,
            transport.as_mut(),
            &mut timing,
        ) {
            Ok(()) => write_timing_log(&timing_log, &timing, "ok", None),
            Err(error) => {
                write_timing_log(&timing_log, &timing, "error", Some(&error));
                eprintln!("image paste failed: {error:#}");
            }
        }
    }
}

fn handle_paste(
    request: PasteRequest,
    request_id: u64,
    config: &Config,
    transport: &mut dyn ImageTransport,
    timing: &mut PasteTiming,
) -> Result<()> {
    if request_changed(request) {
        bail!("focus or clipboard changed before the image could be read")
    }

    let stage = Instant::now();
    let image = read_clipboard_image();
    timing.clipboard_read = Some(stage.elapsed());
    let image = image?;
    timing.image_width = image.width;
    timing.image_height = image.height;
    timing.raw_bytes = image.bytes.len();

    let stage = Instant::now();
    let png = encode_png(&image);
    timing.png_encode = Some(stage.elapsed());
    let png = png?;
    timing.png_bytes = png.len();
    anyhow::ensure!(
        png.len() <= protocol::MAX_IMAGE_BYTES,
        "encoded image exceeds 16 MiB"
    );
    let path = transport.upload(
        request_id,
        png,
        Duration::from_secs(config.request_timeout_seconds),
        timing,
    )?;
    let slot = (0..protocol::IMAGE_SLOT_COUNT)
        .find(|slot| path == remote_slot_path(&config.terminal_paste_directory, *slot))
        .with_context(|| {
            format!(
                "receiver returned {path:?}, which is not one of the configured image slots in {:?}; rerun bootstrap.ps1",
                config.terminal_paste_directory
            )
        })?;

    if request_changed(request) {
        bail!("focus or clipboard changed while the image was uploading")
    }
    let stage = Instant::now();
    let modifier_released = wait_for_paste_keys_release();
    timing.modifier_wait = Some(stage.elapsed());
    if !modifier_released {
        bail!("paste key or modifier was not released before the remote path could be pasted")
    }

    let guard_stage = Instant::now();
    let terminal_input_unchanged = !request_changed(request);
    timing.input_guard = Some(guard_stage.elapsed());
    if !terminal_input_unchanged {
        bail!("terminal input changed before the remote path could be pasted")
    }

    let stage = Instant::now();
    trigger_terminal_paste_action(slot)?;
    timing.terminal_paste = Some(stage.elapsed());
    timing.opencode_handoff = Some(timing.started_at.elapsed());
    timing.opencode_handoff_unix_ms = Some(unix_time_ms());
    Ok(())
}

fn read_clipboard_image() -> Result<ImageData<'static>> {
    let arboard_error =
        match Clipboard::new()
            .context("open Windows clipboard")
            .and_then(|mut clipboard| {
                clipboard
                    .get_image()
                    .context("decode clipboard image")
                    .and_then(|image| {
                        validate_image_layout(image.width, image.height, Some(image.bytes.len()))?;
                        Ok(image)
                    })
            }) {
            Ok(image) => return Ok(image),
            Err(error) => error,
        };

    read_clipboard_bitmap().with_context(|| {
        format!(
            "decode clipboard image through Windows GDI after arboard failed: {arboard_error:#}"
        )
    })
}

fn read_clipboard_bitmap() -> Result<ImageData<'static>> {
    anyhow::ensure!(
        unsafe { OpenClipboard(std::ptr::null_mut()) } != 0,
        "open clipboard for Windows bitmap conversion"
    );
    let _clipboard = ClipboardCloseGuard;

    // Windows synthesizes CF_BITMAP when the clipboard owner provides CF_DIB or
    // CF_DIBV5. Asking GDI for a top-down 32-bit DIB avoids depending on an
    // application's private clipboard format (for example PixPinData).
    let bitmap_handle = unsafe { GetClipboardData(CF_BITMAP) };
    anyhow::ensure!(
        !bitmap_handle.is_null(),
        "clipboard does not expose or synthesize CF_BITMAP"
    );

    let mut bitmap: BITMAP = unsafe { std::mem::zeroed() };
    let object_bytes = i32::try_from(std::mem::size_of::<BITMAP>())
        .context("BITMAP structure is unexpectedly large")?;
    anyhow::ensure!(
        unsafe {
            GetObjectW(
                bitmap_handle,
                object_bytes,
                std::ptr::addr_of_mut!(bitmap).cast(),
            )
        } == object_bytes,
        "read synthesized CF_BITMAP metadata"
    );

    let width = usize::try_from(bitmap.bmWidth).context("clipboard bitmap width is invalid")?;
    let height_i32 = bitmap
        .bmHeight
        .checked_abs()
        .context("clipboard bitmap height is invalid")?;
    let height = usize::try_from(height_i32).context("clipboard bitmap height is invalid")?;
    anyhow::ensure!(width > 0 && height > 0, "clipboard bitmap is empty");
    let byte_len = validate_image_layout(width, height, None)?;
    let mut bytes = vec![0_u8; byte_len];

    let width_i32 = i32::try_from(width).context("clipboard bitmap width is too large")?;
    let top_down_height = i32::try_from(height)
        .context("clipboard bitmap height is too large")?
        .checked_neg()
        .context("clipboard bitmap height is too large")?;
    let mut info: BITMAPINFO = unsafe { std::mem::zeroed() };
    info.bmiHeader = BITMAPINFOHEADER {
        biSize: u32::try_from(std::mem::size_of::<BITMAPINFOHEADER>())
            .context("BITMAPINFOHEADER structure is unexpectedly large")?,
        biWidth: width_i32,
        biHeight: top_down_height,
        biPlanes: 1,
        biBitCount: 32,
        biCompression: BI_RGB,
        biSizeImage: u32::try_from(byte_len).context("clipboard bitmap is too large")?,
        ..unsafe { std::mem::zeroed() }
    };

    let device_context = unsafe { CreateCompatibleDC(std::ptr::null_mut()) };
    anyhow::ensure!(
        !device_context.is_null(),
        "create device context for clipboard bitmap conversion"
    );
    let _device_context = DeviceContextGuard(device_context);
    let copied_lines = unsafe {
        GetDIBits(
            device_context,
            bitmap_handle,
            0,
            u32::try_from(height).context("clipboard bitmap height is too large")?,
            bytes.as_mut_ptr().cast(),
            &mut info,
            DIB_RGB_COLORS,
        )
    };
    anyhow::ensure!(
        copied_lines == height_i32,
        "convert clipboard bitmap to 32-bit pixels"
    );

    for pixel in bytes.chunks_exact_mut(4) {
        pixel.swap(0, 2);
        pixel[3] = 255;
    }
    Ok(ImageData {
        width,
        height,
        bytes: Cow::Owned(bytes),
    })
}

struct ClipboardCloseGuard;

impl Drop for ClipboardCloseGuard {
    fn drop(&mut self) {
        unsafe {
            CloseClipboard();
        }
    }
}

struct DeviceContextGuard(*mut core::ffi::c_void);

impl Drop for DeviceContextGuard {
    fn drop(&mut self) {
        unsafe {
            DeleteDC(self.0);
        }
    }
}

fn write_timing_log(
    path: &Path,
    timing: &PasteTiming,
    outcome: &str,
    error: Option<&anyhow::Error>,
) {
    let Some(parent) = path.parent() else {
        return;
    };
    if fs::create_dir_all(parent).is_err() {
        return;
    }
    if fs::metadata(path).is_ok_and(|metadata| metadata.len() >= TIMING_LOG_MAX_BYTES) {
        let previous = path.with_extension("log.1");
        let _ = fs::remove_file(&previous);
        let _ = fs::rename(path, previous);
    }
    let Ok(mut log) = OpenOptions::new().create(true).append(true).open(path) else {
        return;
    };
    let error = error
        .map(|error| format!("{error:#}"))
        .unwrap_or_else(|| "-".into())
        .replace(['\r', '\n', '\t'], " ");
    let _ = writeln!(
        log,
        "unix_ms={} event=paste request={} outcome={} transport={} transport_state={} output=terminal_action queue_ms={} clipboard_read_ms={} png_encode_ms={} ssh_spawn_ms={} retry_sleep_ms={} upload_receiver_ms={} modifier_wait_ms={} input_guard_ms={} terminal_paste_ms={} bridge_total_ms={} opencode_handoff_ms={} opencode_handoff_unix_ms={} opencode_completion=unobservable image={}x{} raw_bytes={} png_bytes={} ssh_attempts={} upload_attempts={} error={:?}",
        unix_time_ms(),
        timing.request_id,
        outcome,
        timing.transport,
        timing.transport_state,
        duration_ms(Some(timing.queue)),
        duration_ms(timing.clipboard_read),
        duration_ms(timing.png_encode),
        duration_ms(timing.ssh_spawn),
        duration_ms(timing.retry_sleep),
        duration_ms(timing.upload_receiver),
        duration_ms(timing.modifier_wait),
        duration_ms(timing.input_guard),
        duration_ms(timing.terminal_paste),
        duration_ms(Some(timing.started_at.elapsed())),
        duration_ms(timing.opencode_handoff),
        timing
            .opencode_handoff_unix_ms
            .map(|value| value.to_string())
            .unwrap_or_else(|| "-".into()),
        timing.image_width,
        timing.image_height,
        timing.raw_bytes,
        timing.png_bytes,
        timing.ssh_attempts,
        timing.upload_attempts,
        error,
    );
}

fn duration_ms(value: Option<Duration>) -> String {
    value
        .map(|duration| format!("{:.3}", duration.as_secs_f64() * 1000.0))
        .unwrap_or_else(|| "-".into())
}

fn unix_time_ms() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
}

fn request_changed(request: PasteRequest) -> bool {
    current_window() != request.window
        || clipboard_sequence() != request.clipboard_sequence
        || USER_ACTIVITY.load(Ordering::SeqCst) != request.user_activity
}

fn encode_png(image: &ImageData<'_>) -> Result<Vec<u8>> {
    validate_image_layout(image.width, image.height, Some(image.bytes.len()))?;
    let width = u32::try_from(image.width).context("image width is too large")?;
    let height = u32::try_from(image.height).context("image height is too large")?;
    let mut bytes = BoundedBytes::new(protocol::MAX_IMAGE_BYTES);
    {
        let mut encoder = png::Encoder::new(&mut bytes, width, height);
        encoder.set_color(png::ColorType::Rgba);
        encoder.set_depth(png::BitDepth::Eight);
        encoder.set_compression(png::Compression::Fast);
        encoder
            .write_header()?
            .write_image_data(&image.bytes)
            .context("encode clipboard image as bounded PNG")?;
    }
    Ok(bytes.into_inner())
}

fn validate_image_layout(
    width: usize,
    height: usize,
    actual_bytes: Option<usize>,
) -> Result<usize> {
    anyhow::ensure!(width > 0 && height > 0, "clipboard image is empty");
    anyhow::ensure!(
        width <= MAX_IMAGE_DIMENSION && height <= MAX_IMAGE_DIMENSION,
        "clipboard image dimensions {width}x{height} exceed the {MAX_IMAGE_DIMENSION}-pixel edge limit"
    );
    let pixels = width
        .checked_mul(height)
        .context("clipboard image dimensions are too large")?;
    anyhow::ensure!(
        pixels <= MAX_IMAGE_PIXELS,
        "clipboard image contains {pixels} pixels, exceeding the {MAX_IMAGE_PIXELS}-pixel limit"
    );
    let raw_bytes = pixels
        .checked_mul(4)
        .context("clipboard image byte length is too large")?;
    anyhow::ensure!(
        raw_bytes <= MAX_RAW_IMAGE_BYTES,
        "clipboard image requires {raw_bytes} raw bytes, exceeding the {MAX_RAW_IMAGE_BYTES}-byte limit"
    );
    if let Some(actual_bytes) = actual_bytes {
        anyhow::ensure!(
            actual_bytes == raw_bytes,
            "clipboard image is not tightly packed RGBA: expected {raw_bytes} bytes, got {actual_bytes}"
        );
    }
    Ok(raw_bytes)
}

struct BoundedBytes {
    bytes: Vec<u8>,
    limit: usize,
}

impl BoundedBytes {
    fn new(limit: usize) -> Self {
        Self {
            bytes: Vec::new(),
            limit,
        }
    }

    fn into_inner(self) -> Vec<u8> {
        self.bytes
    }
}

impl Write for BoundedBytes {
    fn write(&mut self, buffer: &[u8]) -> std::io::Result<usize> {
        let Some(new_len) = self.bytes.len().checked_add(buffer.len()) else {
            return Err(std::io::Error::other("encoded PNG length overflowed"));
        };
        if new_len > self.limit {
            return Err(std::io::Error::other(format!(
                "encoded PNG exceeds the {}-byte limit",
                self.limit
            )));
        }
        self.bytes.extend_from_slice(buffer);
        Ok(buffer.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

fn clipboard_sequence() -> u32 {
    unsafe { GetClipboardSequenceNumber() }
}

fn current_window() -> isize {
    unsafe { GetForegroundWindow() as isize }
}

fn wait_for_paste_keys_release() -> bool {
    for _ in 0..100 {
        let pressed = SUPPRESS_V_UP.load(Ordering::SeqCst)
            || [VK_CONTROL, VK_SHIFT, VK_MENU, VK_LWIN, VK_RWIN]
                .into_iter()
                .any(key_is_down);
        if !pressed {
            return true;
        }
        thread::sleep(Duration::from_millis(5));
    }
    false
}

fn trigger_terminal_paste_action(slot: usize) -> Result<()> {
    // Windows Terminal 1.24 accepts the same chord from physical input and
    // sequential zero-extra-info events, but ignores a marked SendInput batch.
    // Build and validate every event before sending so the release half of the
    // sequence cannot be skipped by a conversion error after key-down events.
    let events = terminal_action_events(slot)?
        .into_iter()
        .map(|(key, flags)| {
            Ok((
                u8::try_from(key).context("terminal virtual key does not fit in a byte")?,
                flags,
            ))
        })
        .collect::<Result<Vec<_>>>()?;
    for (key, flags) in events {
        unsafe { keybd_event(key, 0, flags, 0) };
    }
    Ok(())
}

fn terminal_action_events(slot: usize) -> Result<Vec<(u16, u32)>> {
    let (modifiers, key) = terminal_action_shortcut(slot)?;
    let mut events = Vec::with_capacity(modifiers.len() * 2 + 2);
    events.extend(modifiers.iter().map(|modifier| (*modifier, 0)));
    events.push((key, 0));
    events.push((key, KEYEVENTF_KEYUP));
    events.extend(
        modifiers
            .iter()
            .rev()
            .map(|modifier| (*modifier, KEYEVENTF_KEYUP)),
    );
    Ok(events)
}

fn terminal_action_shortcut(slot: usize) -> Result<(Vec<u16>, u16)> {
    anyhow::ensure!(
        slot < protocol::IMAGE_SLOT_COUNT,
        "image slot {slot} is out of range"
    );
    // keybd_event does not reliably trigger Windows Terminal bindings for F16
    // and F17 on the validated Windows host. Reuse reliable F13/F14 keys with a
    // distinct modifier set for slots 3 and 4; keep every other proven binding.
    let shortcut = match slot {
        3 => (vec![VK_CONTROL, VK_MENU], VK_F13_CODE),
        4 => (vec![VK_CONTROL, VK_MENU], VK_F13_CODE + 1),
        _ => (
            vec![VK_CONTROL, VK_MENU, VK_SHIFT],
            VK_F13_CODE + u16::try_from(slot).expect("slot key fits in u16"),
        ),
    };
    Ok(shortcut)
}

trait ImageTransport {
    fn upload(
        &mut self,
        id: u64,
        png: Vec<u8>,
        timeout: Duration,
        timing: &mut PasteTiming,
    ) -> Result<String>;
}

fn build_transport(config: &Config) -> Result<Box<dyn ImageTransport>> {
    match config.transport {
        TransportKind::Ssh => Ok(Box::new(SshTransport::new(config))),
        TransportKind::Https => Ok(Box::new(HttpsTransport::new(config)?)),
    }
}

struct SshTransport {
    ssh_program: String,
    ssh_arguments: Vec<String>,
    ssh_target: String,
    remote_command: String,
    remote_probe_command: String,
    connection: Option<Connection>,
}

impl SshTransport {
    fn new(config: &Config) -> Self {
        Self {
            ssh_program: config.ssh_program.clone(),
            ssh_arguments: config.ssh_arguments.clone(),
            ssh_target: config.ssh_target.clone(),
            remote_command: config.remote_command.clone(),
            remote_probe_command: config.remote_probe_command.clone(),
            connection: None,
        }
    }

    fn upload_request(
        &mut self,
        id: u64,
        png: Vec<u8>,
        timeout: Duration,
        timing: &mut PasteTiming,
    ) -> Result<String> {
        timing.transport = "ssh";
        let request = Request { id, png };
        let deadline = Instant::now()
            .checked_add(timeout)
            .context("request timeout is too large")?;
        timing.transport_state = if self.connection.is_some() {
            "connection_reused"
        } else {
            "connection_new"
        };
        for attempt in 0..2 {
            if self.connection.is_none() {
                timing.ssh_attempts += 1;
                let stage = Instant::now();
                let connection = self.connect(deadline);
                add_duration(&mut timing.ssh_spawn, stage.elapsed());
                match connection {
                    Ok(connection) => self.connection = Some(connection),
                    Err(error) if attempt == 0 => {
                        eprintln!("SSH clipboard connection failed, retrying: {error:#}");
                        let stage = Instant::now();
                        let remaining = remaining_request_time(deadline)?;
                        thread::sleep(Duration::from_millis(250).min(remaining));
                        add_duration(&mut timing.retry_sleep, stage.elapsed());
                        continue;
                    }
                    Err(error) => return Err(error),
                }
            }
            timing.upload_attempts += 1;
            let stage = Instant::now();
            let remaining = remaining_request_time(deadline)?;
            let upload = self
                .connection
                .as_mut()
                .unwrap()
                .upload(&request, remaining);
            add_duration(&mut timing.upload_receiver, stage.elapsed());
            match upload {
                Ok(path) => return Ok(path),
                Err(error) if attempt == 0 => {
                    eprintln!("SSH clipboard connection was lost, reconnecting: {error:#}");
                    timing.transport_state = "connection_reconnected";
                    self.connection = None;
                }
                Err(error) => return Err(error),
            }
        }
        unreachable!()
    }

    fn connect(&self, deadline: Instant) -> Result<Connection> {
        let probe_timeout = remaining_request_time(deadline)?;
        let mut probe = Command::new(&self.ssh_program);
        configure_ssh_options(
            &mut probe,
            &self.ssh_arguments,
            probe_timeout.as_secs().max(1),
            false,
        );
        probe
            .arg("-T")
            .arg(&self.ssh_target)
            .arg(&self.remote_probe_command)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .creation_flags(CREATE_NO_WINDOW);
        match command_output_with_timeout(&mut probe, probe_timeout)? {
            TimedCommandOutput::Completed(output)
                if output.status.success()
                    && receiver_capabilities_are_compatible(&output.stdout) => {}
            TimedCommandOutput::Completed(_) => {
                bail!("receiver capabilities are incompatible; rerun bootstrap.ps1")
            }
            TimedCommandOutput::TimedOut => {
                bail!("receiver capability check timed out; rerun bootstrap.ps1")
            }
        }

        let connect_timeout = remaining_request_time(deadline)?;
        let mut command = Command::new(&self.ssh_program);
        configure_ssh_options(
            &mut command,
            &self.ssh_arguments,
            connect_timeout.as_secs().max(1),
            true,
        );
        let mut child = command
            .arg("-T")
            .arg(&self.ssh_target)
            .arg(&self.remote_command)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            // Client mode detaches from the console with FreeConsole. Inheriting
            // stderr after that can pass an invalid Windows handle to ssh.exe.
            .stderr(Stdio::null())
            .creation_flags(CREATE_NO_WINDOW)
            .spawn()
            .with_context(|| format!("start {}", self.ssh_program))?;
        let input = BufWriter::new(child.stdin.take().context("SSH stdin is unavailable")?);
        let output = BufReader::new(child.stdout.take().context("SSH stdout is unavailable")?);
        Ok(Connection {
            child,
            input,
            output,
        })
    }
}

impl ImageTransport for SshTransport {
    fn upload(
        &mut self,
        id: u64,
        png: Vec<u8>,
        timeout: Duration,
        timing: &mut PasteTiming,
    ) -> Result<String> {
        self.upload_request(id, png, timeout, timing)
    }
}

struct HttpsTransport {
    agent: ureq::Agent,
    endpoint: String,
    token: String,
    agent_was_used: bool,
}

impl HttpsTransport {
    fn new(config: &Config) -> Result<Self> {
        validate_https_config(config)?;
        let certificate_bytes = fs::read(&config.https_certificate_path)
            .with_context(|| format!("read {}", config.https_certificate_path.display()))?;
        let certificate = Certificate::from_pem(&certificate_bytes)
            .context("parse dedicated HTTPS receiver certificate")?;
        let tls = TlsConfig::builder()
            .root_certs(RootCerts::from([certificate]))
            .build();
        let agent_config = ureq::Agent::config_builder()
            .timeout_global(Some(Duration::from_secs(config.request_timeout_seconds)))
            .max_idle_age(Duration::from_secs(30 * 60))
            .max_redirects(0)
            .http_status_as_error(false)
            .tls_config(tls)
            .build();
        Ok(Self {
            agent: agent_config.into(),
            endpoint: config.https_endpoint.clone(),
            token: config.https_token.clone(),
            agent_was_used: false,
        })
    }

    fn capabilities(&self) -> Result<String> {
        let url = format!("{}/v1/capabilities", self.endpoint);
        let mut response = self
            .agent
            .get(&url)
            .header("Authorization", &format!("Bearer {}", self.token))
            .call()
            .context("request HTTPS receiver capabilities")?;
        anyhow::ensure!(
            response.status().as_u16() == 200,
            "HTTPS receiver capability check returned HTTP {}",
            response.status()
        );
        let body = response
            .body_mut()
            .with_config()
            .limit(65 * 1024)
            .read_to_vec()
            .context("read HTTPS receiver capabilities")?;
        anyhow::ensure!(
            body.len() < 65 * 1024,
            "HTTPS capability response is too large"
        );
        String::from_utf8(body).context("HTTPS receiver capabilities are not UTF-8")
    }
}

impl ImageTransport for HttpsTransport {
    fn upload(
        &mut self,
        id: u64,
        png: Vec<u8>,
        _timeout: Duration,
        timing: &mut PasteTiming,
    ) -> Result<String> {
        timing.transport = "https";
        timing.transport_state = if self.agent_was_used {
            "agent_reused"
        } else {
            "agent_new"
        };
        self.agent_was_used = true;
        timing.upload_attempts += 1;
        let request = Request { id, png };
        let mut frame = Vec::with_capacity(request.png.len() + 16);
        protocol::write_request(&mut frame, &request).context("encode HTTPS upload frame")?;
        let stage = Instant::now();
        let result = (|| {
            let url = format!("{}/v1/upload", self.endpoint);
            let mut response = self
                .agent
                .post(&url)
                .header("Authorization", &format!("Bearer {}", self.token))
                .header("Content-Type", "application/octet-stream")
                .send(frame.as_slice())
                .context("send HTTPS image upload")?;
            anyhow::ensure!(
                response.status().as_u16() == 200,
                "HTTPS receiver returned HTTP {}",
                response.status()
            );
            let bytes = response
                .body_mut()
                .with_config()
                .limit((64 * 1024 + 18) as u64)
                .read_to_vec()
                .context("read HTTPS upload response")?;
            anyhow::ensure!(
                bytes.len() <= 64 * 1024 + 17,
                "HTTPS receiver response exceeds 64 KiB protocol limit"
            );
            let response = protocol::read_response_exact(bytes.as_slice())
                .context("decode exact HTTPS upload response")?;
            anyhow::ensure!(response.id == id, "receiver returned mismatched request id");
            response.result.map_err(anyhow::Error::msg)
        })();
        add_duration(&mut timing.upload_receiver, stage.elapsed());
        result
    }
}

fn remaining_request_time(deadline: Instant) -> Result<Duration> {
    let remaining = deadline.saturating_duration_since(Instant::now());
    anyhow::ensure!(!remaining.is_zero(), "SSH receiver request timed out");
    Ok(remaining)
}

fn add_duration(total: &mut Option<Duration>, value: Duration) {
    *total = Some(total.unwrap_or_default() + value);
}

struct Connection {
    child: Child,
    input: BufWriter<ChildStdin>,
    output: BufReader<ChildStdout>,
}

impl Connection {
    fn upload(&mut self, request: &Request, timeout: Duration) -> Result<String> {
        if let Some(status) = self.child.try_wait().context("check SSH process")? {
            bail!("SSH process exited with {status}")
        }
        let (done, watchdog) = mpsc::sync_channel(0);
        let process_id = self.child.id();
        thread::spawn(move || {
            if watchdog.recv_timeout(timeout).is_err() {
                let process = unsafe { OpenProcess(PROCESS_TERMINATE, 0, process_id) };
                if !process.is_null() {
                    unsafe {
                        TerminateProcess(process, 1);
                        CloseHandle(process);
                    }
                }
            }
        });
        let write = protocol::write_request(&mut self.input, request).context("send image");
        if let Err(error) = write {
            let _ = done.send(());
            return Err(error);
        }
        let response = protocol::read_response(&mut self.output).context("receive image path");
        let _ = done.send(());
        let response = response?;
        anyhow::ensure!(
            response.id == request.id,
            "receiver returned mismatched request id"
        );
        response.result.map_err(anyhow::Error::msg)
    }
}

impl Drop for Connection {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashSet;

    const COMMAND_TIMEOUT_HELPER_ENV: &str = "OPENCODE_SSH_IMAGE_PASTE_COMMAND_TIMEOUT_TEST_HELPER";

    #[test]
    fn ssh_target_rejects_options_and_control_characters() {
        for target in ["workbox", "developer@workbox", "workbox.example"] {
            validate_ssh_target(target).unwrap();
        }
        for target in ["", "   ", "-oProxyCommand=bad", "workbox\nother"] {
            assert!(
                validate_ssh_target(target).is_err(),
                "unexpected valid target: {target:?}"
            );
        }
    }

    #[test]
    fn legacy_config_defaults_to_ssh_transport() {
        let config: Config = toml::from_str("ssh_target = \"workbox\"").unwrap();
        assert_eq!(config.transport, TransportKind::Ssh);
    }

    #[test]
    fn invalid_https_config_does_not_fall_back_to_ssh() {
        let config: Config = toml::from_str(&format!(
            "transport = \"https\"\nhttps_endpoint = \"https://workbox:8443\"\nhttps_token = \"{}\"\nhttps_certificate_path = \"missing.pem\"\nssh_target = \"valid-ssh-fallback\"",
            "ab".repeat(32)
        ))
        .unwrap();
        assert_eq!(config.transport, TransportKind::Https);
        assert!(build_transport(&config).is_err());
    }

    #[test]
    fn forced_ssh_options_precede_user_arguments() {
        let user_arguments = [
            "-F",
            "custom.conf",
            "-J",
            "jumpbox",
            "-o",
            "BatchMode=no",
            "-o",
            "ConnectTimeout=999",
        ]
        .map(str::to_owned);
        let mut command = Command::new("ssh.exe");
        configure_ssh_options(&mut command, &user_arguments, 7, true);
        let arguments = command
            .get_args()
            .map(|argument| argument.to_string_lossy().into_owned())
            .collect::<Vec<_>>();
        assert_eq!(
            arguments,
            [
                "-o",
                "BatchMode=yes",
                "-o",
                "ConnectTimeout=7",
                "-o",
                "ServerAliveInterval=5",
                "-o",
                "ServerAliveCountMax=2",
                "-F",
                "custom.conf",
                "-J",
                "jumpbox",
                "-o",
                "BatchMode=no",
                "-o",
                "ConnectTimeout=999",
            ]
        );
    }

    #[test]
    fn holds_process_for_timeout_subprocess_test() {
        if std::env::var_os(COMMAND_TIMEOUT_HELPER_ENV).is_none() {
            return;
        }
        thread::sleep(Duration::from_secs(30));
    }

    #[test]
    fn timed_command_is_terminated_and_reported() {
        let mut command = Command::new(std::env::current_exe().unwrap());
        command
            .args([
                "--exact",
                "windows::tests::holds_process_for_timeout_subprocess_test",
            ])
            .env(COMMAND_TIMEOUT_HELPER_ENV, "1")
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .creation_flags(CREATE_NO_WINDOW);

        let started = Instant::now();
        assert!(matches!(
            command_output_with_timeout(&mut command, Duration::from_millis(200)).unwrap(),
            TimedCommandOutput::TimedOut
        ));
        let elapsed = started.elapsed();
        assert!(
            elapsed >= Duration::from_millis(150),
            "command timed out too early: {elapsed:?}"
        );
        assert!(
            elapsed < Duration::from_secs(2),
            "command timed out too late: {elapsed:?}"
        );
    }

    #[test]
    fn terminal_slot_shortcuts_avoid_unreliable_function_keys() {
        let cases = [
            (0, vec![VK_CONTROL, VK_MENU, VK_SHIFT], VK_F13_CODE),
            (3, vec![VK_CONTROL, VK_MENU], VK_F13_CODE),
            (4, vec![VK_CONTROL, VK_MENU], VK_F13_CODE + 1),
            (9, vec![VK_CONTROL, VK_MENU, VK_SHIFT], VK_F13_CODE + 9),
        ];
        for (slot, modifiers, key) in cases {
            assert_eq!(terminal_action_shortcut(slot).unwrap(), (modifiers, key));
        }
    }

    #[test]
    fn terminal_slot_shortcuts_are_unique_and_bounded() {
        let mut shortcuts = HashSet::new();
        for slot in 0..protocol::IMAGE_SLOT_COUNT {
            assert!(shortcuts.insert(terminal_action_shortcut(slot).unwrap()));
        }
        assert_eq!(shortcuts.len(), protocol::IMAGE_SLOT_COUNT);
        assert!(terminal_action_shortcut(protocol::IMAGE_SLOT_COUNT).is_err());
    }

    #[test]
    fn image_layout_accepts_exact_limits() {
        let width = 8_192;
        let height = 8_192;
        let raw_bytes = MAX_IMAGE_PIXELS * 4;
        assert_eq!(
            validate_image_layout(width, height, Some(raw_bytes)).unwrap(),
            raw_bytes
        );
        assert!(
            validate_image_layout(MAX_IMAGE_DIMENSION, 1, Some(MAX_IMAGE_DIMENSION * 4)).is_ok()
        );
    }

    #[test]
    fn image_layout_rejects_oversized_or_malformed_images() {
        assert!(validate_image_layout(MAX_IMAGE_DIMENSION + 1, 1, None).is_err());
        assert!(validate_image_layout(8_192, 8_193, None).is_err());
        assert!(validate_image_layout(10, 10, Some(399)).is_err());
        assert!(validate_image_layout(0, 10, None).is_err());
        assert!(validate_image_layout(usize::MAX, 2, None).is_err());
    }

    #[test]
    fn fast_png_encoding_is_lossless() {
        let pixels = vec![
            255, 0, 0, 255, 0, 255, 0, 128, 0, 0, 255, 64, 255, 255, 255, 0,
        ];
        let image = ImageData {
            width: 2,
            height: 2,
            bytes: Cow::Borrowed(&pixels),
        };
        let encoded = encode_png(&image).unwrap();
        let decoder = png::Decoder::new(std::io::Cursor::new(encoded));
        let mut reader = decoder.read_info().unwrap();
        let mut decoded = vec![0; reader.output_buffer_size().unwrap()];
        let info = reader.next_frame(&mut decoded).unwrap();
        assert_eq!(info.width, 2);
        assert_eq!(info.height, 2);
        assert_eq!(info.color_type, png::ColorType::Rgba);
        assert_eq!(info.bit_depth, png::BitDepth::Eight);
        assert_eq!(&decoded[..info.buffer_size()], pixels.as_slice());
    }

    #[test]
    fn bounded_png_writer_never_exceeds_its_limit() {
        let mut writer = BoundedBytes::new(4);
        writer.write_all(&[1, 2, 3, 4]).unwrap();
        assert!(writer.write_all(&[5]).is_err());
        assert_eq!(writer.into_inner(), vec![1, 2, 3, 4]);
    }

    #[test]
    fn terminal_action_events_release_key_and_modifiers_in_reverse_order() {
        assert_eq!(
            terminal_action_events(9).unwrap(),
            vec![
                (VK_CONTROL, 0),
                (VK_MENU, 0),
                (VK_SHIFT, 0),
                (VK_F13_CODE + 9, 0),
                (VK_F13_CODE + 9, KEYEVENTF_KEYUP),
                (VK_SHIFT, KEYEVENTF_KEYUP),
                (VK_MENU, KEYEVENTF_KEYUP),
                (VK_CONTROL, KEYEVENTF_KEYUP),
            ]
        );
    }

    #[test]
    fn request_deadline_rejects_expired_budget() {
        assert!(remaining_request_time(Instant::now() - Duration::from_millis(1)).is_err());
        assert!(remaining_request_time(Instant::now() + Duration::from_secs(1)).is_ok());
    }

    #[test]
    fn receiver_capabilities_require_exact_stdout() {
        assert!(receiver_capabilities_are_compatible(
            protocol::CAPABILITIES.as_bytes()
        ));
        assert!(receiver_capabilities_are_compatible(
            format!("{}\r\n", protocol::CAPABILITIES).as_bytes()
        ));
        assert!(!receiver_capabilities_are_compatible(
            format!("remote banner\n{}", protocol::CAPABILITIES).as_bytes()
        ));
        assert!(!receiver_capabilities_are_compatible(
            format!("{}\nextra output", protocol::CAPABILITIES).as_bytes()
        ));
    }
}
