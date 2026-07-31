use crate::protocol::{self, Request};
use anyhow::{Context, Result, bail};
use arboard::{Clipboard, ImageData};
use serde::Deserialize;
use std::fs;
use std::io::{BufReader, BufWriter};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{OnceLock, mpsc};
use std::thread;
use std::time::Duration;
use windows_sys::Win32::Foundation::{CloseHandle, GlobalFree, LPARAM, LRESULT, WPARAM};
use windows_sys::Win32::System::DataExchange::{
    CloseClipboard, EmptyClipboard, GetClipboardData, GetClipboardSequenceNumber,
    IsClipboardFormatAvailable, OpenClipboard, RegisterClipboardFormatW, SetClipboardData,
};
use windows_sys::Win32::System::Memory::{
    GMEM_MOVEABLE, GlobalAlloc, GlobalLock, GlobalSize, GlobalUnlock,
};
use windows_sys::Win32::System::Threading::{OpenProcess, PROCESS_TERMINATE, TerminateProcess};
use windows_sys::Win32::UI::Input::KeyboardAndMouse::{
    GetAsyncKeyState, KEYEVENTF_KEYUP, VK_CONTROL, VK_SHIFT, VK_V, keybd_event,
};
use windows_sys::Win32::UI::WindowsAndMessaging::{
    CallNextHookEx, DispatchMessageW, GetClassNameW, GetForegroundWindow, GetMessageW,
    KBDLLHOOKSTRUCT, MSG, SetWindowsHookExW, TranslateMessage, UnhookWindowsHookEx, WH_KEYBOARD_LL,
    WH_MOUSE_LL, WM_KEYDOWN, WM_KEYUP, WM_LBUTTONDOWN, WM_MBUTTONDOWN, WM_MOUSEWHEEL,
    WM_RBUTTONDOWN, WM_SYSKEYDOWN, WM_SYSKEYUP, WM_XBUTTONDOWN,
};

const CF_DIBV5: u32 = 17;
const CF_UNICODETEXT: u32 = 13;
const DEFAULT_WINDOW_CLASS: &str = "CASCADIA_HOSTING_WINDOW_CLASS";

static REQUESTS: OnceLock<mpsc::SyncSender<PasteRequest>> = OnceLock::new();
static WINDOW_CLASS: OnceLock<String> = OnceLock::new();
static PNG_FORMAT: OnceLock<u32> = OnceLock::new();
static MARKER_FORMAT: OnceLock<u32> = OnceLock::new();
static SUPPRESS_V_UP: AtomicBool = AtomicBool::new(false);
static NEXT_REQUEST_ID: AtomicU64 = AtomicU64::new(1);
static USER_ACTIVITY: AtomicU64 = AtomicU64::new(0);

#[derive(Clone, Copy)]
struct PasteRequest {
    window: isize,
    clipboard_sequence: u32,
    user_activity: u64,
}

#[derive(Debug, Deserialize)]
#[serde(default)]
struct Config {
    ssh_target: String,
    ssh_program: String,
    ssh_arguments: Vec<String>,
    remote_command: String,
    terminal_window_class: String,
    restore_clipboard_delay_ms: u64,
    request_timeout_seconds: u64,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            ssh_target: String::new(),
            ssh_program: "ssh.exe".into(),
            ssh_arguments: Vec::new(),
            remote_command: "~/.local/bin/opencode-ssh-image-paste receiver".into(),
            terminal_window_class: DEFAULT_WINDOW_CLASS.into(),
            restore_clipboard_delay_ms: 150,
            request_timeout_seconds: 15,
        }
    }
}

pub fn run(config_path: Option<PathBuf>) -> Result<()> {
    let config_path = config_path.unwrap_or_else(default_config_path);
    let config = load_config(&config_path)?;
    anyhow::ensure!(
        !config.ssh_target.trim().is_empty(),
        "ssh_target is required in {}",
        config_path.display()
    );
    anyhow::ensure!(
        config.request_timeout_seconds > 0,
        "request_timeout_seconds must be positive"
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
    let marker = "OpenCodeSSHImagePasteMarker\0"
        .encode_utf16()
        .collect::<Vec<_>>();
    let marker_format = unsafe { RegisterClipboardFormatW(marker.as_ptr()) };
    anyhow::ensure!(
        marker_format != 0,
        "could not register the clipboard marker format"
    );
    MARKER_FORMAT
        .set(marker_format)
        .map_err(|_| anyhow::anyhow!("clipboard marker format was already registered"))?;

    let (sender, receiver) = mpsc::sync_channel(3);
    REQUESTS
        .set(sender)
        .map_err(|_| anyhow::anyhow!("keyboard hook was already initialized"))?;
    thread::spawn(move || worker(receiver, config));

    eprintln!("opencode SSH image paste is running; Ctrl+V image interception is active");
    run_keyboard_hook()
}

fn default_config_path() -> PathBuf {
    std::env::var_os("APPDATA")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."))
        .join("OpenCodeSSHImagePaste/config.toml")
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
    loop {
        let result = unsafe { GetMessageW(&mut message, std::ptr::null_mut(), 0, 0) };
        if result <= 0 {
            break;
        }
        unsafe {
            TranslateMessage(&message);
            DispatchMessageW(&message);
        }
    }
    unsafe {
        UnhookWindowsHookEx(mouse_hook);
        UnhookWindowsHookEx(keyboard_hook);
    }
    Ok(())
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
    if !key_down || !control_is_down() || !clipboard_has_image_without_text() {
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

fn control_is_down() -> bool {
    (unsafe { GetAsyncKeyState(i32::from(VK_CONTROL)) }) < 0
}

fn clipboard_has_image_without_text() -> bool {
    if unsafe { IsClipboardFormatAvailable(CF_UNICODETEXT) } != 0 {
        return false;
    }
    let png = PNG_FORMAT.get().copied().unwrap_or_default();
    unsafe {
        IsClipboardFormatAvailable(CF_DIBV5) != 0
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

fn worker(receiver: mpsc::Receiver<PasteRequest>, config: Config) {
    let mut transport = Transport::new(&config);
    for request in receiver {
        if let Err(error) = handle_paste(request, &config, &mut transport) {
            eprintln!("image paste failed: {error:#}");
        }
    }
}

fn handle_paste(request: PasteRequest, config: &Config, transport: &mut Transport) -> Result<()> {
    if request_changed(request) {
        bail!("focus or clipboard changed before the image could be read")
    }

    let mut clipboard = Clipboard::new().context("open Windows clipboard")?;
    let image = clipboard
        .get_image()
        .context("read clipboard image")?
        .to_owned_img();
    let png = encode_png(&image)?;
    anyhow::ensure!(
        png.len() <= protocol::MAX_IMAGE_BYTES,
        "encoded image exceeds 16 MiB"
    );
    let path = transport.upload(
        NEXT_REQUEST_ID.fetch_add(1, Ordering::Relaxed),
        png.clone(),
        Duration::from_secs(config.request_timeout_seconds),
    )?;

    if request_changed(request) {
        bail!("focus or clipboard changed while the image was uploading")
    }
    if !wait_for_modifier_release() || request_changed(request) {
        bail!("input changed before the remote path could be pasted")
    }

    let marker = marker_value();
    set_clipboard_text_if_sequence(&path, &marker, request.clipboard_sequence, request.window)?;
    if current_window() != request.window
        || USER_ACTIVITY.load(Ordering::SeqCst) != request.user_activity
        || !clipboard_marker_matches(&marker, request.window)?
    {
        restore_png_if_marker(&png, &marker, request.window)?;
        bail!("terminal input changed before the remote path could be pasted")
    }
    send_terminal_paste();
    thread::sleep(Duration::from_millis(config.restore_clipboard_delay_ms));
    restore_png_if_marker(&png, &marker, request.window)
}

fn request_changed(request: PasteRequest) -> bool {
    current_window() != request.window
        || clipboard_sequence() != request.clipboard_sequence
        || USER_ACTIVITY.load(Ordering::SeqCst) != request.user_activity
}

fn encode_png(image: &ImageData<'_>) -> Result<Vec<u8>> {
    let width = u32::try_from(image.width).context("image width is too large")?;
    let height = u32::try_from(image.height).context("image height is too large")?;
    anyhow::ensure!(
        image.bytes.len() == image.width.saturating_mul(image.height).saturating_mul(4),
        "clipboard image is not RGBA"
    );
    let mut bytes = Vec::new();
    {
        let mut encoder = png::Encoder::new(&mut bytes, width, height);
        encoder.set_color(png::ColorType::Rgba);
        encoder.set_depth(png::BitDepth::Eight);
        encoder.write_header()?.write_image_data(&image.bytes)?;
    }
    Ok(bytes)
}

fn marker_value() -> [u8; 12] {
    let mut marker = [0; 12];
    marker[..4].copy_from_slice(&std::process::id().to_be_bytes());
    marker[4..].copy_from_slice(
        &NEXT_REQUEST_ID
            .fetch_add(1, Ordering::Relaxed)
            .to_be_bytes(),
    );
    marker
}

fn set_clipboard_text_if_sequence(
    text: &str,
    marker: &[u8],
    sequence: u32,
    owner: isize,
) -> Result<()> {
    let bytes = text
        .encode_utf16()
        .chain(std::iter::once(0))
        .flat_map(u16::to_le_bytes)
        .collect::<Vec<_>>();
    let clipboard = ClipboardLock::open(owner)?;
    anyhow::ensure!(
        clipboard_sequence() == sequence,
        "clipboard changed before replacement"
    );
    anyhow::ensure!(
        unsafe { EmptyClipboard() } != 0,
        "could not clear the Windows clipboard"
    );
    set_clipboard_bytes(CF_UNICODETEXT, &bytes)?;
    set_clipboard_bytes(
        *MARKER_FORMAT
            .get()
            .context("clipboard marker is unavailable")?,
        marker,
    )?;
    drop(clipboard);
    Ok(())
}

fn restore_png_if_marker(png: &[u8], marker: &[u8], owner: isize) -> Result<()> {
    let Some(format) = PNG_FORMAT.get().copied() else {
        return Ok(());
    };
    let clipboard = ClipboardLock::open(owner)?;
    if !clipboard_marker_matches_locked(marker) {
        return Ok(());
    }
    anyhow::ensure!(
        unsafe { EmptyClipboard() } != 0,
        "could not clear the Windows clipboard"
    );
    set_clipboard_bytes(format, png)?;
    drop(clipboard);
    Ok(())
}

fn clipboard_marker_matches(marker: &[u8], owner: isize) -> Result<bool> {
    let clipboard = ClipboardLock::open(owner)?;
    let matches = clipboard_marker_matches_locked(marker);
    drop(clipboard);
    Ok(matches)
}

fn clipboard_marker_matches_locked(marker: &[u8]) -> bool {
    let Some(format) = MARKER_FORMAT.get().copied() else {
        return false;
    };
    let memory = unsafe { GetClipboardData(format) };
    if memory.is_null() || unsafe { GlobalSize(memory) } < marker.len() {
        return false;
    }
    let data = unsafe { GlobalLock(memory) } as *const u8;
    if data.is_null() {
        return false;
    }
    let matches = unsafe { std::slice::from_raw_parts(data, marker.len()) } == marker;
    unsafe { GlobalUnlock(memory) };
    matches
}

fn set_clipboard_bytes(format: u32, bytes: &[u8]) -> Result<()> {
    let memory = unsafe { GlobalAlloc(GMEM_MOVEABLE, bytes.len()) };
    anyhow::ensure!(!memory.is_null(), "could not allocate clipboard memory");
    let target = unsafe { GlobalLock(memory) } as *mut u8;
    if target.is_null() {
        unsafe { GlobalFree(memory) };
        bail!("could not lock clipboard memory")
    }
    unsafe {
        std::ptr::copy_nonoverlapping(bytes.as_ptr(), target, bytes.len());
        GlobalUnlock(memory);
    }
    if unsafe { SetClipboardData(format, memory) }.is_null() {
        unsafe { GlobalFree(memory) };
        bail!("could not set Windows clipboard data")
    }
    Ok(())
}

struct ClipboardLock;

impl ClipboardLock {
    fn open(owner: isize) -> Result<Self> {
        anyhow::ensure!(
            unsafe { OpenClipboard(owner as *mut core::ffi::c_void) } != 0,
            "could not open Windows clipboard"
        );
        Ok(Self)
    }
}

impl Drop for ClipboardLock {
    fn drop(&mut self) {
        unsafe { CloseClipboard() };
    }
}

fn clipboard_sequence() -> u32 {
    unsafe { GetClipboardSequenceNumber() }
}

fn current_window() -> isize {
    unsafe { GetForegroundWindow() as isize }
}

fn wait_for_modifier_release() -> bool {
    for _ in 0..100 {
        let pressed = unsafe {
            GetAsyncKeyState(i32::from(VK_CONTROL)) < 0 || GetAsyncKeyState(i32::from(VK_SHIFT)) < 0
        };
        if !pressed {
            return true;
        }
        thread::sleep(Duration::from_millis(5));
    }
    false
}

fn send_terminal_paste() {
    unsafe {
        keybd_event(VK_CONTROL as u8, 0, 0, 0);
        keybd_event(VK_V as u8, 0, 0, 0);
        keybd_event(VK_V as u8, 0, KEYEVENTF_KEYUP, 0);
        keybd_event(VK_CONTROL as u8, 0, KEYEVENTF_KEYUP, 0);
    }
}

struct Transport {
    ssh_program: String,
    ssh_arguments: Vec<String>,
    ssh_target: String,
    remote_command: String,
    connection: Option<Connection>,
}

impl Transport {
    fn new(config: &Config) -> Self {
        Self {
            ssh_program: config.ssh_program.clone(),
            ssh_arguments: config.ssh_arguments.clone(),
            ssh_target: config.ssh_target.clone(),
            remote_command: config.remote_command.clone(),
            connection: None,
        }
    }

    fn upload(&mut self, id: u64, png: Vec<u8>, timeout: Duration) -> Result<String> {
        let request = Request { id, png };
        for attempt in 0..2 {
            if self.connection.is_none() {
                match self.connect() {
                    Ok(connection) => self.connection = Some(connection),
                    Err(error) if attempt == 0 => {
                        eprintln!("SSH clipboard connection failed, retrying: {error:#}");
                        thread::sleep(Duration::from_millis(250));
                        continue;
                    }
                    Err(error) => return Err(error),
                }
            }
            match self.connection.as_mut().unwrap().upload(&request, timeout) {
                Ok(path) => return Ok(path),
                Err(error) if attempt == 0 => {
                    eprintln!("SSH clipboard connection was lost, reconnecting: {error:#}");
                    self.connection = None;
                }
                Err(error) => return Err(error),
            }
        }
        unreachable!()
    }

    fn connect(&self) -> Result<Connection> {
        let mut child = Command::new(&self.ssh_program)
            .args(&self.ssh_arguments)
            .args([
                "-o",
                "BatchMode=yes",
                "-o",
                "ConnectTimeout=5",
                "-o",
                "ServerAliveInterval=5",
                "-o",
                "ServerAliveCountMax=2",
            ])
            .arg("-T")
            .arg(&self.ssh_target)
            .arg(&self.remote_command)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
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
