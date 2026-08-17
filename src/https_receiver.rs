use crate::protocol::{self, Response as ProtocolResponse};
use crate::receiver::ReceiverState;
use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::fs::{self, OpenOptions};
use std::io::{Cursor, Read};
use std::path::{Path, PathBuf};
use tiny_http::{Header, Method, Response, Server, StatusCode};

const MAX_HTTP_BODY_BYTES: usize = protocol::MAX_IMAGE_BYTES + 16;
const TOKEN_BYTES: usize = 32;
const CONTENT_TYPE: &str = "application/octet-stream";

#[derive(Debug, Deserialize, Serialize)]
pub struct HttpsReceiverConfig {
    pub host: String,
    pub port: u16,
    pub token: String,
    pub certificate_path: PathBuf,
    pub private_key_path: PathBuf,
    pub directory: PathBuf,
}

struct HttpReply {
    status: u16,
    content_type: &'static str,
    body: Vec<u8>,
}

pub fn initialize(
    config_path: &Path,
    host: &str,
    port: u16,
    directory: Option<PathBuf>,
) -> Result<()> {
    validate_host_port(host, port)?;
    let parent = config_path
        .parent()
        .filter(|path| !path.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    fs::create_dir_all(parent).with_context(|| format!("create {}", parent.display()))?;
    set_private_directory_permissions(parent)?;
    let parent =
        fs::canonicalize(parent).with_context(|| format!("resolve {}", parent.display()))?;
    let config_path = if config_path.is_absolute() {
        config_path.to_path_buf()
    } else {
        parent.join(
            config_path
                .file_name()
                .context("HTTPS config path has no file name")?,
        )
    };
    let certificate_path = parent.join("receiver-cert.pem");
    let private_key_path = parent.join("receiver-key.pem");

    let state = ReceiverState::new(directory)?;
    let image_directory = state.directory().to_path_buf();
    drop(state);

    let rcgen::CertifiedKey { cert, signing_key } =
        rcgen::generate_simple_self_signed(vec![host.to_owned()])
            .context("generate self-signed HTTPS certificate")?;
    let mut token_bytes = [0_u8; TOKEN_BYTES];
    getrandom::fill(&mut token_bytes)
        .map_err(|error| anyhow::anyhow!("generate HTTPS bearer token: {error}"))?;
    let token = token_bytes
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect::<String>();

    write_private_file(&certificate_path, cert.pem().as_bytes())?;
    write_private_file(&private_key_path, signing_key.serialize_pem().as_bytes())?;
    let config = HttpsReceiverConfig {
        host: host.to_owned(),
        port,
        token,
        certificate_path,
        private_key_path,
        directory: image_directory,
    };
    let text = toml::to_string_pretty(&config).context("serialize HTTPS receiver configuration")?;
    write_private_file(&config_path, text.as_bytes())?;
    println!(
        "Initialized HTTPS receiver configuration: {}",
        config_path.display()
    );
    println!("Certificate: {}", config.certificate_path.display());
    Ok(())
}

pub fn serve(config_path: &Path) -> Result<()> {
    let config = load_config(config_path)?;
    let certificate = fs::read(&config.certificate_path)
        .with_context(|| format!("read {}", config.certificate_path.display()))?;
    let private_key = fs::read(&config.private_key_path)
        .with_context(|| format!("read {}", config.private_key_path.display()))?;
    let bind = socket_address(&config.host, config.port);
    let server = Server::https(
        &bind,
        tiny_http::SslConfig {
            certificate,
            private_key,
        },
    )
    .map_err(|error| anyhow::anyhow!(error))
    .with_context(|| format!("bind HTTPS receiver to {bind}"))?;
    let mut state = ReceiverState::new(Some(config.directory.clone()))?;
    state.start_cleanup_thread();
    eprintln!("HTTPS receiver listening on {bind}");

    for mut request in server.incoming_requests() {
        let reply = handle_request(&mut request, &config.token, &mut state);
        let content_type = Header::from_bytes("Content-Type", reply.content_type)
            .expect("static HTTP header is valid");
        let response = Response::from_data(reply.body)
            .with_status_code(StatusCode(reply.status))
            .with_header(content_type);
        if let Err(error) = request.respond(response) {
            eprintln!("could not send HTTPS response: {error}");
        }
    }
    Ok(())
}

pub fn load_config(config_path: &Path) -> Result<HttpsReceiverConfig> {
    let text = fs::read_to_string(config_path)
        .with_context(|| format!("read {}", config_path.display()))?;
    let mut config: HttpsReceiverConfig =
        toml::from_str(&text).with_context(|| format!("parse {}", config_path.display()))?;
    validate_host_port(&config.host, config.port)?;
    anyhow::ensure!(
        config.token.len() == TOKEN_BYTES * 2
            && config.token.bytes().all(|byte| byte.is_ascii_hexdigit()),
        "HTTPS bearer token must be exactly 32 bytes encoded as 64 hexadecimal characters"
    );
    let parent = config_path.parent().unwrap_or_else(|| Path::new("."));
    if config.certificate_path.is_relative() {
        config.certificate_path = parent.join(&config.certificate_path);
    }
    if config.private_key_path.is_relative() {
        config.private_key_path = parent.join(&config.private_key_path);
    }
    if config.directory.is_relative() {
        config.directory = parent.join(&config.directory);
    }
    Ok(config)
}

fn validate_host_port(host: &str, port: u16) -> Result<()> {
    anyhow::ensure!(!host.trim().is_empty(), "HTTPS host must not be empty");
    anyhow::ensure!(
        !host.chars().any(char::is_control),
        "HTTPS host must not contain control characters"
    );
    anyhow::ensure!(port != 0, "HTTPS port must be between 1 and 65535");
    Ok(())
}

fn socket_address(host: &str, port: u16) -> String {
    if host.contains(':') && !host.starts_with('[') {
        format!("[{host}]:{port}")
    } else {
        format!("{host}:{port}")
    }
}

fn handle_request(
    request: &mut tiny_http::Request,
    token: &str,
    state: &mut ReceiverState,
) -> HttpReply {
    let headers = request.headers();
    let authorization = headers
        .iter()
        .filter(|header| header.field.equiv("Authorization"))
        .collect::<Vec<_>>();
    let expected = format!("Bearer {token}");
    let content_types = headers
        .iter()
        .filter(|header| header.field.equiv("Content-Type"))
        .collect::<Vec<_>>();
    let content_lengths = headers
        .iter()
        .filter(|header| header.field.equiv("Content-Length"))
        .map(|header| header.value.as_str().parse::<usize>().ok())
        .collect::<Vec<_>>();
    if let Some(reply) = request_preflight(
        request.method(),
        request.url(),
        authorization.len(),
        authorization.len() == 1 && authorization[0].value.as_str() == expected,
        content_types.len(),
        content_types.len() == 1
            && content_types[0]
                .value
                .as_str()
                .eq_ignore_ascii_case(CONTENT_TYPE),
        &content_lengths,
    ) {
        return reply;
    }

    match request.url() {
        "/v1/capabilities" => {
            if request.method() != &Method::Get {
                return text_reply(405, "method not allowed");
            }
            HttpReply {
                status: 200,
                content_type: "text/plain; charset=utf-8",
                body: protocol::CAPABILITIES.as_bytes().to_vec(),
            }
        }
        "/v1/upload" => {
            if request.method() != &Method::Post {
                return text_reply(405, "method not allowed");
            }
            let mut body = Vec::new();
            if let Err(error) = request
                .as_reader()
                .take((MAX_HTTP_BODY_BYTES + 1) as u64)
                .read_to_end(&mut body)
            {
                return protocol_error(0, format!("read request body: {error}"));
            }
            if body.len() > MAX_HTTP_BODY_BYTES {
                return text_reply(413, "request body too large");
            }
            upload_reply(&body, state)
        }
        _ => text_reply(404, "not found"),
    }
}

fn request_preflight(
    method: &Method,
    path: &str,
    authorization_count: usize,
    authorization_matches: bool,
    content_type_count: usize,
    content_type_matches: bool,
    content_lengths: &[Option<usize>],
) -> Option<HttpReply> {
    if authorization_count != 1 || !authorization_matches {
        return Some(text_reply(401, "unauthorized"));
    }
    match path {
        "/v1/capabilities" if method != &Method::Get => Some(text_reply(405, "method not allowed")),
        "/v1/capabilities" => None,
        "/v1/upload" if method != &Method::Post => Some(text_reply(405, "method not allowed")),
        "/v1/upload" if content_type_count != 1 || !content_type_matches => {
            Some(text_reply(415, "unsupported media type"))
        }
        "/v1/upload"
            if content_lengths
                .iter()
                .any(|length| length.is_none_or(|length| length > MAX_HTTP_BODY_BYTES)) =>
        {
            Some(text_reply(413, "request body too large"))
        }
        "/v1/upload" => None,
        _ => Some(text_reply(404, "not found")),
    }
}

fn upload_reply(body: &[u8], state: &mut ReceiverState) -> HttpReply {
    let mut cursor = Cursor::new(body);
    let request = match protocol::read_request(&mut cursor) {
        Ok(Some(request)) if cursor.position() == body.len() as u64 => request,
        Ok(Some(request)) => return protocol_error(request.id, "request frame has trailing bytes"),
        Ok(None) => return protocol_error(0, "request frame is empty"),
        Err(error) => return protocol_error(0, format!("invalid request frame: {error}")),
    };
    let id = request.id;
    let result = state
        .store(request)
        .map(|path| path.to_string_lossy().into_owned())
        .map_err(|error| format!("{error:#}"));
    protocol_reply(ProtocolResponse { id, result })
}

fn protocol_error(id: u64, error: impl Into<String>) -> HttpReply {
    protocol_reply(ProtocolResponse {
        id,
        result: Err(error.into()),
    })
}

fn protocol_reply(response: ProtocolResponse) -> HttpReply {
    let mut body = Vec::new();
    protocol::write_response(&mut body, &response).expect("bounded protocol response is valid");
    HttpReply {
        status: 200,
        content_type: CONTENT_TYPE,
        body,
    }
}

fn text_reply(status: u16, message: &str) -> HttpReply {
    HttpReply {
        status,
        content_type: "text/plain; charset=utf-8",
        body: message.as_bytes().to_vec(),
    }
}

fn write_private_file(path: &Path, contents: &[u8]) -> Result<()> {
    let parent = path.parent().unwrap_or_else(|| Path::new("."));
    let temporary = parent.join(format!(
        ".{}.{}.tmp",
        path.file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("receiver"),
        std::process::id()
    ));
    let mut options = OpenOptions::new();
    options.write(true).create(true).truncate(true);
    use std::os::unix::fs::OpenOptionsExt;
    options.mode(0o600);
    {
        use std::io::Write;
        let mut file = options
            .open(&temporary)
            .with_context(|| format!("create {}", temporary.display()))?;
        file.write_all(contents)
            .with_context(|| format!("write {}", temporary.display()))?;
        file.sync_all()
            .with_context(|| format!("sync {}", temporary.display()))?;
    }
    fs::rename(&temporary, path).with_context(|| format!("replace {}", path.display()))?;
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(path, fs::Permissions::from_mode(0o600))
        .with_context(|| format!("set permissions on {}", path.display()))?;
    Ok(())
}

fn set_private_directory_permissions(path: &Path) -> Result<()> {
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(path, fs::Permissions::from_mode(0o700))
        .with_context(|| format!("set permissions on {}", path.display()))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_directory(name: &str) -> PathBuf {
        std::env::temp_dir().join(format!("opencode-https-{name}-{}", std::process::id()))
    }

    fn request_frame(id: u64, png: &[u8]) -> Vec<u8> {
        let mut body = Vec::new();
        protocol::write_request(
            &mut body,
            &protocol::Request {
                id,
                png: png.to_vec(),
            },
        )
        .unwrap();
        body
    }

    #[test]
    fn upload_reuses_ocb2_and_ocr2_frames() {
        let directory = temp_directory("frames");
        let _ = fs::remove_dir_all(&directory);
        let mut state = ReceiverState::new(Some(directory.clone())).unwrap();
        let body = request_frame(17, b"\x89PNG\r\n\x1a\nfixture");
        let reply = upload_reply(&body, &mut state);
        assert_eq!(reply.status, 200);
        assert_eq!(reply.content_type, CONTENT_TYPE);
        let response = protocol::read_response(reply.body.as_slice()).unwrap();
        assert_eq!(response.id, 17);
        assert!(response.result.unwrap().ends_with("image-00.png"));
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn malformed_frames_are_bounded_protocol_errors() {
        let directory = temp_directory("malformed");
        let _ = fs::remove_dir_all(&directory);
        let mut state = ReceiverState::new(Some(directory.clone())).unwrap();
        for body in [Vec::new(), b"bad".to_vec(), {
            let mut body = request_frame(4, b"\x89PNG\r\n\x1a\nfixture");
            body.push(0);
            body
        }] {
            let reply = upload_reply(&body, &mut state);
            assert_eq!(reply.status, 200);
            assert!(
                protocol::read_response(reply.body.as_slice())
                    .unwrap()
                    .result
                    .is_err()
            );
        }
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn enforces_http_auth_method_path_type_and_declared_body_limit() {
        let ok_length = [Some(MAX_HTTP_BODY_BYTES)];
        let too_large = [Some(MAX_HTTP_BODY_BYTES + 1)];
        let invalid_length = [None];
        assert_eq!(
            request_preflight(&Method::Post, "/v1/upload", 0, false, 1, true, &ok_length)
                .unwrap()
                .status,
            401
        );
        assert_eq!(
            request_preflight(&Method::Post, "/v1/upload", 2, true, 1, true, &ok_length)
                .unwrap()
                .status,
            401
        );
        assert_eq!(
            request_preflight(&Method::Get, "/v1/upload", 1, true, 1, true, &ok_length)
                .unwrap()
                .status,
            405
        );
        assert_eq!(
            request_preflight(&Method::Post, "/unknown", 1, true, 1, true, &ok_length)
                .unwrap()
                .status,
            404
        );
        assert_eq!(
            request_preflight(&Method::Post, "/v1/upload", 1, true, 0, false, &ok_length)
                .unwrap()
                .status,
            415
        );
        for lengths in [&too_large[..], &invalid_length[..]] {
            assert_eq!(
                request_preflight(&Method::Post, "/v1/upload", 1, true, 1, true, lengths)
                    .unwrap()
                    .status,
                413
            );
        }
        assert!(
            request_preflight(&Method::Post, "/v1/upload", 1, true, 1, true, &ok_length).is_none()
        );
    }

    #[test]
    fn authorization_errors_never_echo_the_token() {
        let reply =
            request_preflight(&Method::Get, "/v1/capabilities", 1, false, 0, false, &[]).unwrap();
        assert_eq!(reply.status, 401);
        assert_eq!(reply.body, b"unauthorized");
    }

    #[test]
    fn validates_https_config_secret_and_endpoint() {
        assert!(validate_host_port("workbox.lan", 8443).is_ok());
        assert!(validate_host_port("", 8443).is_err());
        assert!(validate_host_port("workbox\nother", 8443).is_err());
        assert!(validate_host_port("workbox", 0).is_err());
        assert_eq!(socket_address("2001:db8::1", 8443), "[2001:db8::1]:8443");
    }
}
