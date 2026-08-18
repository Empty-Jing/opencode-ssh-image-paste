use crate::protocol::{self, Response as ProtocolResponse};
use crate::receiver::ReceiverState;
use anyhow::{Context, Result};
use axum::Router;
use axum::body::{Body, to_bytes};
use axum::extract::State;
use axum::http::header::{AUTHORIZATION, CONTENT_LENGTH, CONTENT_TYPE as CONTENT_TYPE_HEADER};
use axum::http::{HeaderMap, Method, Request, Response};
use axum::routing::any;
use axum_server::Handle;
use axum_server::tls_rustls::{RustlsAcceptor, RustlsConfig};
use serde::{Deserialize, Serialize};
use std::fs::{self, OpenOptions};
use std::io::Cursor;
use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::{Mutex, Semaphore};

const MAX_HTTP_BODY_BYTES: usize = protocol::MAX_IMAGE_BYTES + 16;
const MAX_CONCURRENT_REQUESTS: usize = 16;
const REQUEST_TIMEOUT: Duration = Duration::from_secs(15);
const TLS_HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(10);
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

#[derive(Clone)]
struct HttpState {
    token: Arc<str>,
    receiver: Arc<Mutex<ReceiverState>>,
    concurrency: Arc<Semaphore>,
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
    let bind = socket_address(&config.host, config.port);
    let address: SocketAddr = bind
        .parse()
        .with_context(|| format!("parse HTTPS receiver address {bind}"))?;
    let state = ReceiverState::new(Some(config.directory.clone()))?;
    state.start_cleanup_thread();
    let shared = HttpState {
        token: config.token.into(),
        receiver: Arc::new(Mutex::new(state)),
        concurrency: Arc::new(Semaphore::new(MAX_CONCURRENT_REQUESTS)),
    };

    let tls = load_tls_config(&config.certificate_path, &config.private_key_path)?;
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()
        .context("create HTTPS receiver runtime")?;
    runtime.block_on(async move {
        let handle = Handle::new();
        let listening = handle.clone();
        let server = tokio::spawn(serve_address(address, tls, shared, handle));
        if let Some(bound) = listening.listening().await {
            eprintln!("HTTPS receiver listening on {bound}");
        }
        server.await.context("join HTTPS receiver task")?
    })
}

fn load_tls_config(certificate_path: &Path, private_key_path: &Path) -> Result<RustlsConfig> {
    use rustls::pki_types::{CertificateDer, PrivateKeyDer, pem::PemObject};

    let certificate_pem = fs::read(certificate_path)
        .with_context(|| format!("read HTTPS certificate {}", certificate_path.display()))?;
    let certificates = CertificateDer::pem_slice_iter(&certificate_pem)
        .collect::<std::result::Result<Vec<_>, _>>()
        .with_context(|| format!("parse HTTPS certificate {}", certificate_path.display()))?;
    anyhow::ensure!(
        !certificates.is_empty(),
        "HTTPS certificate file contains no certificates: {}",
        certificate_path.display()
    );

    let private_key_pem = fs::read(private_key_path)
        .with_context(|| format!("read HTTPS private key {}", private_key_path.display()))?;
    let private_key = PrivateKeyDer::from_pem_slice(&private_key_pem)
        .with_context(|| format!("parse HTTPS private key {}", private_key_path.display()))?;

    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let server = rustls::ServerConfig::builder_with_provider(provider)
        .with_protocol_versions(&[&rustls::version::TLS13, &rustls::version::TLS12])
        .context("configure HTTPS TLS protocol versions")?
        .with_no_client_auth()
        .with_single_cert(certificates, private_key)
        .context("configure HTTPS certificate and private key")?;
    Ok(RustlsConfig::from_config(Arc::new(server)))
}

async fn serve_address(
    address: SocketAddr,
    tls: RustlsConfig,
    state: HttpState,
    handle: Handle<SocketAddr>,
) -> Result<()> {
    let router = Router::new()
        .fallback(any(handle_request))
        .with_state(state);
    let acceptor = RustlsAcceptor::new(tls).handshake_timeout(TLS_HANDSHAKE_TIMEOUT);
    axum_server::Server::bind(address)
        .acceptor(acceptor)
        .handle(handle)
        .serve(router.into_make_service())
        .await
        .with_context(|| format!("serve HTTPS receiver on {address}"))
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

async fn handle_request(State(state): State<HttpState>, request: Request<Body>) -> Response<Body> {
    let method = request.method().clone();
    let path = request.uri().path().to_owned();
    let headers = request.headers();
    let authorization = header_values(headers, AUTHORIZATION);
    let expected = format!("Bearer {}", state.token);
    let content_types = header_values(headers, CONTENT_TYPE_HEADER);
    let content_lengths = header_values(headers, CONTENT_LENGTH)
        .into_iter()
        .map(|value| value.to_str().ok().and_then(|value| value.parse().ok()))
        .collect::<Vec<_>>();
    if let Some(reply) = request_preflight(
        &method,
        &path,
        authorization.len(),
        authorization.len() == 1 && authorization[0].as_bytes() == expected.as_bytes(),
        content_types.len(),
        content_types.len() == 1
            && content_types[0]
                .to_str()
                .is_ok_and(|value| value.eq_ignore_ascii_case(CONTENT_TYPE)),
        &content_lengths,
    ) {
        return into_response(reply);
    }

    let Ok(_permit) = state.concurrency.try_acquire() else {
        return into_response(text_reply(503, "receiver busy"));
    };
    let operation = async {
        match path.as_str() {
            "/v1/capabilities" => HttpReply {
                status: 200,
                content_type: "text/plain; charset=utf-8",
                body: protocol::CAPABILITIES.as_bytes().to_vec(),
            },
            "/v1/upload" => match to_bytes(request.into_body(), MAX_HTTP_BODY_BYTES).await {
                Ok(body) => {
                    let mut receiver = state.receiver.lock().await;
                    upload_reply(&body, &mut receiver)
                }
                Err(_) => text_reply(413, "request body too large"),
            },
            _ => text_reply(404, "not found"),
        }
    };
    let reply = match tokio::time::timeout(REQUEST_TIMEOUT, operation).await {
        Ok(reply) => reply,
        Err(_) => text_reply(408, "request timeout"),
    };
    into_response(reply)
}

fn header_values(
    headers: &HeaderMap,
    name: axum::http::header::HeaderName,
) -> Vec<&axum::http::HeaderValue> {
    headers.get_all(name).iter().collect()
}

fn into_response(reply: HttpReply) -> Response<Body> {
    Response::builder()
        .status(reply.status)
        .header(CONTENT_TYPE_HEADER, reply.content_type)
        .body(Body::from(reply.body))
        .expect("static HTTP response is valid")
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
        "/v1/capabilities" if method != Method::GET => Some(text_reply(405, "method not allowed")),
        "/v1/capabilities" => None,
        "/v1/upload" if method != Method::POST => Some(text_reply(405, "method not allowed")),
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
    use rustls::pki_types::ServerName;
    use rustls::{ClientConfig, ClientConnection, RootCertStore, StreamOwned};
    use std::io::{Read, Write};
    use std::net::TcpStream;
    use ureq::tls::{Certificate, RootCerts, TlsConfig};

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

    fn raw_tls_request(address: SocketAddr, certificate_path: &Path, request: &[u8]) -> Vec<u8> {
        use rustls::pki_types::{CertificateDer, pem::PemObject};

        let certificate_pem = fs::read(certificate_path).unwrap();
        let certificates = CertificateDer::pem_slice_iter(&certificate_pem)
            .collect::<std::result::Result<Vec<_>, _>>()
            .unwrap();
        let mut roots = RootCertStore::empty();
        for certificate in certificates {
            roots.add(certificate).unwrap();
        }
        let provider = Arc::new(rustls::crypto::ring::default_provider());
        let client = ClientConfig::builder_with_provider(provider)
            .with_protocol_versions(&[&rustls::version::TLS13, &rustls::version::TLS12])
            .unwrap()
            .with_root_certificates(roots)
            .with_no_client_auth();
        let connection = ClientConnection::new(
            Arc::new(client),
            ServerName::try_from("127.0.0.1".to_owned()).unwrap(),
        )
        .unwrap();
        let tcp = TcpStream::connect(address).unwrap();
        tcp.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
        tcp.set_write_timeout(Some(Duration::from_secs(5))).unwrap();
        let mut tls = StreamOwned::new(connection, tcp);
        tls.write_all(request).unwrap();
        tls.flush().unwrap();
        let mut response = Vec::new();
        tls.read_to_end(&mut response).unwrap();
        response
    }

    fn response_status(response: &[u8]) -> u16 {
        let line_end = response
            .windows(2)
            .position(|bytes| bytes == b"\r\n")
            .unwrap();
        std::str::from_utf8(&response[..line_end])
            .unwrap()
            .split_whitespace()
            .nth(1)
            .unwrap()
            .parse()
            .unwrap()
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
            request_preflight(&Method::POST, "/v1/upload", 0, false, 1, true, &ok_length)
                .unwrap()
                .status,
            401
        );
        assert_eq!(
            request_preflight(&Method::POST, "/v1/upload", 2, true, 1, true, &ok_length)
                .unwrap()
                .status,
            401
        );
        assert_eq!(
            request_preflight(&Method::GET, "/v1/upload", 1, true, 1, true, &ok_length)
                .unwrap()
                .status,
            405
        );
        assert_eq!(
            request_preflight(&Method::POST, "/unknown", 1, true, 1, true, &ok_length)
                .unwrap()
                .status,
            404
        );
        assert_eq!(
            request_preflight(&Method::POST, "/v1/upload", 1, true, 0, false, &ok_length)
                .unwrap()
                .status,
            415
        );
        for lengths in [&too_large[..], &invalid_length[..]] {
            assert_eq!(
                request_preflight(&Method::POST, "/v1/upload", 1, true, 1, true, lengths)
                    .unwrap()
                    .status,
                413
            );
        }
        assert!(
            request_preflight(&Method::POST, "/v1/upload", 1, true, 1, true, &ok_length).is_none()
        );
    }

    #[test]
    fn authorization_errors_never_echo_the_token() {
        let reply =
            request_preflight(&Method::GET, "/v1/capabilities", 1, false, 0, false, &[]).unwrap();
        assert_eq!(reply.status, 401);
        assert_eq!(reply.body, b"unauthorized");
    }

    #[test]
    fn concurrency_limit_rejects_then_recovers() {
        let directory = temp_directory("concurrency");
        let _ = fs::remove_dir_all(&directory);
        let receiver = ReceiverState::new(Some(directory.clone())).unwrap();
        let concurrency = Arc::new(Semaphore::new(MAX_CONCURRENT_REQUESTS));
        let permits = (0..MAX_CONCURRENT_REQUESTS)
            .map(|_| concurrency.clone().try_acquire_owned().unwrap())
            .collect::<Vec<_>>();
        let state = HttpState {
            token: "token".into(),
            receiver: Arc::new(Mutex::new(receiver)),
            concurrency,
        };
        let request = || {
            Request::builder()
                .method(Method::GET)
                .uri("/v1/capabilities")
                .header(AUTHORIZATION, "Bearer token")
                .body(Body::empty())
                .unwrap()
        };
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();

        let busy = runtime.block_on(handle_request(State(state.clone()), request()));
        assert_eq!(busy.status().as_u16(), 503);
        drop(permits);
        let available = runtime.block_on(handle_request(State(state.clone()), request()));
        assert_eq!(available.status().as_u16(), 200);

        drop(state);
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn validates_https_config_secret_and_endpoint() {
        assert!(validate_host_port("workbox.lan", 8443).is_ok());
        assert!(validate_host_port("", 8443).is_err());
        assert!(validate_host_port("workbox\nother", 8443).is_err());
        assert!(validate_host_port("workbox", 0).is_err());
        assert_eq!(socket_address("2001:db8::1", 8443), "[2001:db8::1]:8443");
    }

    #[test]
    fn loopback_tls_auth_upload_consecutive_requests_and_body_limit() {
        let root = temp_directory("loopback");
        let _ = fs::remove_dir_all(&root);
        let config_path = root.join("receiver.toml");
        let images = root.join("images");
        initialize(&config_path, "127.0.0.1", 47832, Some(images.clone())).unwrap();
        let config = load_config(&config_path).unwrap();
        let certificate =
            Certificate::from_pem(&fs::read(&config.certificate_path).unwrap()).unwrap();
        let tls_client = TlsConfig::builder()
            .root_certs(RootCerts::from([certificate]))
            .build();
        let agent: ureq::Agent = ureq::Agent::config_builder()
            .timeout_global(Some(Duration::from_secs(5)))
            .max_redirects(0)
            .http_status_as_error(false)
            .tls_config(tls_client)
            .build()
            .into();

        let tls_server =
            load_tls_config(&config.certificate_path, &config.private_key_path).unwrap();
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .build()
            .unwrap();
        runtime.block_on(async move {
            let receiver = ReceiverState::new(Some(images)).unwrap();
            let state = HttpState {
                token: config.token.clone().into(),
                receiver: Arc::new(Mutex::new(receiver)),
                concurrency: Arc::new(Semaphore::new(MAX_CONCURRENT_REQUESTS)),
            };
            let handle = Handle::new();
            let server_handle = handle.clone();
            let server = tokio::spawn(serve_address(
                "127.0.0.1:0".parse().unwrap(),
                tls_server,
                state,
                server_handle,
            ));
            let address = handle.listening().await.unwrap();
            let endpoint = format!("https://{address}");
            let authorization = format!("Bearer {}", config.token);

            for _ in 0..2 {
                let mut response = agent
                    .get(format!("{endpoint}/v1/capabilities"))
                    .header("Authorization", &authorization)
                    .call()
                    .unwrap();
                assert_eq!(response.status().as_u16(), 200);
                assert_eq!(
                    response.body_mut().read_to_string().unwrap(),
                    protocol::CAPABILITIES
                );
            }
            let mut unauthorized = agent
                .get(format!("{endpoint}/v1/capabilities"))
                .call()
                .unwrap();
            assert_eq!(unauthorized.status().as_u16(), 401);
            let unauthorized_body = unauthorized.body_mut().read_to_string().unwrap();
            assert_eq!(unauthorized_body, "unauthorized");
            assert!(!unauthorized_body.contains(&config.token));

            let unknown_without_auth = raw_tls_request(
                address,
                &config.certificate_path,
                b"GET /unknown HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n",
            );
            assert_eq!(response_status(&unknown_without_auth), 401);
            let duplicate_authorization = format!(
                "GET /unknown HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: {authorization}\r\nAuthorization: {authorization}\r\nConnection: close\r\n\r\n"
            );
            assert_eq!(
                response_status(&raw_tls_request(
                    address,
                    &config.certificate_path,
                    duplicate_authorization.as_bytes(),
                )),
                401
            );
            let duplicate_content_type = format!(
                "POST /v1/upload HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: {authorization}\r\nContent-Type: {CONTENT_TYPE}\r\nContent-Type: {CONTENT_TYPE}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            );
            assert_eq!(
                response_status(&raw_tls_request(
                    address,
                    &config.certificate_path,
                    duplicate_content_type.as_bytes(),
                )),
                415
            );

            let frame = request_frame(31, b"\x89PNG\r\n\x1a\nloopback");
            let mut uploaded = agent
                .post(format!("{endpoint}/v1/upload"))
                .header("Authorization", &authorization)
                .header("Content-Type", CONTENT_TYPE)
                .send(frame)
                .unwrap();
            assert_eq!(uploaded.status().as_u16(), 200);
            let upload_body = uploaded.body_mut().read_to_vec().unwrap();
            let upload_response = protocol::read_response_exact(upload_body.as_slice()).unwrap();
            assert_eq!(upload_response.id, 31);
            assert!(upload_response.result.unwrap().ends_with("image-00.png"));

            let chunked_frame = request_frame(32, b"\x89PNG\r\n\x1a\nchunked");
            let mut chunked_request = format!(
                "POST /v1/upload HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: {authorization}\r\nContent-Type: {CONTENT_TYPE}\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n{:x}\r\n",
                chunked_frame.len()
            )
            .into_bytes();
            chunked_request.extend_from_slice(&chunked_frame);
            chunked_request.extend_from_slice(b"\r\n0\r\n\r\n");
            assert_eq!(
                response_status(&raw_tls_request(
                    address,
                    &config.certificate_path,
                    &chunked_request,
                )),
                200
            );

            let oversized = vec![0_u8; MAX_HTTP_BODY_BYTES + 1];
            let mut oversized_request = format!(
                "POST /v1/upload HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: {authorization}\r\nContent-Type: {CONTENT_TYPE}\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n{:x}\r\n",
                oversized.len()
            )
            .into_bytes();
            oversized_request.extend_from_slice(&oversized);
            oversized_request.extend_from_slice(b"\r\n0\r\n\r\n");
            assert_eq!(
                response_status(&raw_tls_request(
                    address,
                    &config.certificate_path,
                    &oversized_request,
                )),
                413
            );

            handle.shutdown();
            server.await.unwrap().unwrap();
        });
        fs::remove_dir_all(root).unwrap();
    }
}
