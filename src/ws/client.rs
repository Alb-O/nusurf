#[cfg(not(target_arch = "wasm32"))]
use std::collections::HashMap;

use {
	nu_plugin::EvaluatedCall,
	nu_protocol::{ShellError, Signals, Span, Value},
	std::{
		collections::VecDeque,
		io::{ErrorKind, Read},
		net::TcpStream,
		sync::{
			Arc, Mutex,
			atomic::{AtomicBool, Ordering},
			mpsc::{self, Receiver, RecvTimeoutError, TryRecvError},
		},
		thread,
		time::{Duration, Instant},
	},
	tungstenite::{
		ClientRequestBuilder, Error as WsError, Message, WebSocket,
		stream::{MaybeTlsStream, NoDelay},
	},
	url::Url,
};

const SOCKET_POLL_INTERVAL: Duration = Duration::from_millis(100);

type WebSocketStream = WebSocket<MaybeTlsStream<TcpStream>>;

enum ControlMessage {
	Send(Vec<u8>),
	Close,
}

pub enum ReceivedMessage {
	Text(String),
	Binary(Vec<u8>),
}

#[derive(Clone)]
pub struct SessionHandle {
	tx: mpsc::SyncSender<ControlMessage>,
	closed: Arc<AtomicBool>,
}

#[derive(Clone)]
pub struct SessionClient {
	handle: SessionHandle,
	rx: Arc<Mutex<Receiver<ReceivedMessage>>>,
}

pub struct WebSocketClient {
	rx: Receiver<ReceivedMessage>,
	deadline: Option<Instant>,
	buf_deque: VecDeque<u8>,
	signals: Signals,
	span: Span,
}

impl WebSocketClient {
	pub fn new(rx: Receiver<ReceivedMessage>, timeout: Option<Duration>, signals: Signals, span: Span) -> Self {
		let mut client = Self {
			rx,
			deadline: None,
			buf_deque: VecDeque::new(),
			signals,
			span,
		};
		if let Some(timeout) = timeout {
			client.deadline = Some(Instant::now() + timeout);
		}
		client
	}

	fn enqueue_message(&mut self, message: ReceivedMessage) {
		match message {
			ReceivedMessage::Text(text) => {
				self.buf_deque.extend(text.bytes());
				self.buf_deque.push_back(b'\n');
			}
			ReceivedMessage::Binary(data) => {
				self.buf_deque.extend(data);
				self.buf_deque.push_back(b'\n');
			}
		}
	}
}

impl Read for WebSocketClient {
	fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
		if !self.buf_deque.is_empty() {
			let mut len = 0;
			for buf_slot in buf {
				if let Some(b) = self.buf_deque.pop_front() {
					*buf_slot = b;
					len += 1;
				} else {
					break;
				}
			}
			return Ok(len);
		}

		loop {
			if let Err(e) = self.signals.check(&self.span) {
				return Err(std::io::Error::new(std::io::ErrorKind::Interrupted, e.to_string()));
			}

			let wait_time = match self.deadline {
				Some(deadline) => match deadline.checked_duration_since(Instant::now()) {
					Some(remaining) => remaining.min(SOCKET_POLL_INTERVAL),
					None => return Ok(0),
				},
				None => SOCKET_POLL_INTERVAL,
			};

			match self.rx.recv_timeout(wait_time) {
				Ok(message) => {
					self.enqueue_message(message);

					let mut len = 0;
					for buf_slot in buf {
						if let Some(b) = self.buf_deque.pop_front() {
							*buf_slot = b;
							len += 1;
						} else {
							break;
						}
					}
					return Ok(len);
				}
				Err(RecvTimeoutError::Timeout) => continue,
				Err(RecvTimeoutError::Disconnected) => return Ok(0),
			}
		}
	}
}

impl SessionHandle {
	pub fn send(&self, data: Vec<u8>) -> Result<(), String> {
		if self.closed.load(Ordering::SeqCst) {
			return Err("WebSocket session is closed".to_string());
		}

		self.tx
			.send(ControlMessage::Send(data))
			.map_err(|_| "WebSocket worker is no longer running".to_string())
	}

	pub fn close(&self) -> Result<(), String> {
		self.closed.store(true, Ordering::SeqCst);
		let _ = self.tx.send(ControlMessage::Close);
		Ok(())
	}
}

impl SessionClient {
	pub fn send(&self, data: Vec<u8>) -> Result<(), String> {
		self.handle.send(data)
	}

	pub fn recv(
		&self, timeout: Option<Duration>, signals: &Signals, span: Span,
	) -> Result<Option<ReceivedMessage>, String> {
		let rx = self
			.rx
			.lock()
			.map_err(|_| "Failed to lock WebSocket receiver".to_string())?;
		let deadline = timeout.map(|duration| Instant::now() + duration);

		loop {
			if let Err(e) = signals.check(&span) {
				return Err(e.to_string());
			}

			let wait_time = match deadline {
				Some(deadline) => match deadline.checked_duration_since(Instant::now()) {
					Some(remaining) => remaining.min(SOCKET_POLL_INTERVAL),
					None => return Ok(None),
				},
				None => SOCKET_POLL_INTERVAL,
			};

			match rx.recv_timeout(wait_time) {
				Ok(message) => return Ok(Some(message)),
				Err(RecvTimeoutError::Timeout) => continue,
				Err(RecvTimeoutError::Disconnected) => return Ok(None),
			}
		}
	}

	pub fn close(&self) -> Result<(), String> {
		self.handle.close()
	}
}

pub fn connect(
	url: Url, timeout: Option<Duration>, headers: HashMap<String, String>, signals: Signals, span: Span,
) -> Option<(WebSocketClient, SessionHandle)> {
	let (tx, rx, closed) = connect_components(url, headers)?;
	let handle = SessionHandle { tx, closed };
	Some((WebSocketClient::new(rx, timeout, signals, span), handle))
}

pub fn connect_session(url: Url, headers: HashMap<String, String>) -> Option<SessionClient> {
	let (tx, rx, closed) = connect_components(url, headers)?;
	Some(SessionClient {
		handle: SessionHandle { tx, closed },
		rx: Arc::new(Mutex::new(rx)),
	})
}

fn connect_components(
	url: Url, headers: HashMap<String, String>,
) -> Option<(
	mpsc::SyncSender<ControlMessage>,
	Receiver<ReceivedMessage>,
	Arc<AtomicBool>,
)> {
	log::trace!("Building WebSocket request for: {url}");

	let mut builder = ClientRequestBuilder::new(url.as_str().parse().ok()?);
	let origin = format!(
		"{}://{}:{}",
		url.scheme(),
		url.host_str().unwrap_or_default(),
		url.port().unwrap_or_default()
	);

	log::trace!("Setting Origin header to: {origin}");
	builder = builder.with_header("Origin", origin);

	for (k, v) in headers {
		log::trace!("Adding header: {k} = {v}");
		builder = builder.with_header(k, v);
	}

	log::debug!("Attempting WebSocket connection...");

	match tungstenite::connect(builder) {
		Ok((mut websocket, _)) => {
			log::debug!("WebSocket handshake completed successfully");
			configure_socket(&mut websocket).ok()?;

			let (tx_control, rx_control) = mpsc::sync_channel(1024);
			let (tx_read, rx_read) = mpsc::sync_channel(1024);
			let closed = Arc::new(AtomicBool::new(false));

			spawn_worker_thread(websocket, rx_control, tx_read, closed.clone())?;
			Some((tx_control, rx_read, closed))
		}
		Err(e) => {
			log::error!("Failed to connect to WebSocket: {e:?}");
			None
		}
	}
}

fn spawn_worker_thread(
	mut websocket: WebSocketStream, rx_control: Receiver<ControlMessage>, tx_read: mpsc::SyncSender<ReceivedMessage>,
	closed: Arc<AtomicBool>,
) -> Option<thread::JoinHandle<()>> {
	thread::Builder::new()
		.name("websocket worker".to_string())
		.spawn(move || {
			log::debug!("WebSocket worker thread started");
			loop {
				if closed.load(Ordering::SeqCst) {
					let _ = websocket.close(Some(normal_close("session closed")));
					return;
				}

				match flush_control_messages(&mut websocket, &rx_control, &closed) {
					Ok(ControlFlow::Continue) => {}
					Ok(ControlFlow::Closed) => return,
					Err(e) => {
						log::error!("WebSocket control error: {e}");
						closed.store(true, Ordering::SeqCst);
						return;
					}
				}

				match websocket.read() {
					Ok(Message::Text(msg)) => {
						if tx_read.send(ReceivedMessage::Text(msg.to_string())).is_err() {
							log::debug!("Channel closed, closing WebSocket");
							closed.store(true, Ordering::SeqCst);
							let _ = websocket.close(Some(normal_close("receiver dropped")));
							return;
						}
					}
					Ok(Message::Binary(msg)) => {
						if tx_read.send(ReceivedMessage::Binary(msg.to_vec())).is_err() {
							log::debug!("Channel closed, closing WebSocket");
							closed.store(true, Ordering::SeqCst);
							let _ = websocket.close(Some(normal_close("receiver dropped")));
							return;
						}
					}
					Ok(Message::Close(_)) => {
						log::debug!("Received Close message");
						closed.store(true, Ordering::SeqCst);
						return;
					}
					Ok(other) => {
						log::trace!("Ignoring WebSocket message: {other:?}");
					}
					Err(WsError::Io(err)) if matches!(err.kind(), ErrorKind::WouldBlock | ErrorKind::TimedOut) => {
						thread::yield_now();
						continue;
					}
					Err(WsError::ConnectionClosed | WsError::AlreadyClosed) => {
						log::debug!("WebSocket closed");
						closed.store(true, Ordering::SeqCst);
						return;
					}
					Err(e) => {
						log::error!("WebSocket read error: {e:?}");
						closed.store(true, Ordering::SeqCst);
						return;
					}
				}
			}
		})
		.ok()
}

enum ControlFlow {
	Continue,
	Closed,
}

fn flush_control_messages(
	websocket: &mut WebSocketStream, rx_control: &Receiver<ControlMessage>, closed: &Arc<AtomicBool>,
) -> Result<ControlFlow, String> {
	loop {
		match rx_control.try_recv() {
			Ok(ControlMessage::Send(data)) => {
				let message = match String::from_utf8(data.clone()) {
					Ok(text) => Message::Text(text.into()),
					Err(_) => Message::Binary(data.into()),
				};
				websocket
					.send(message)
					.map_err(|e| format!("Failed to send WebSocket message: {}", e))?;
			}
			Ok(ControlMessage::Close) => {
				closed.store(true, Ordering::SeqCst);
				let _ = websocket.close(Some(normal_close("session closed")));
				return Ok(ControlFlow::Closed);
			}
			Err(TryRecvError::Empty) => return Ok(ControlFlow::Continue),
			Err(TryRecvError::Disconnected) => {
				closed.store(true, Ordering::SeqCst);
				let _ = websocket.close(Some(normal_close("control channel closed")));
				return Ok(ControlFlow::Closed);
			}
		}
	}
}

fn configure_socket(websocket: &mut WebSocketStream) -> std::io::Result<()> {
	let stream = websocket.get_mut();
	stream.set_nodelay(true)?;
	set_read_timeout(stream, Some(SOCKET_POLL_INTERVAL))
}

fn set_read_timeout(stream: &mut MaybeTlsStream<TcpStream>, timeout: Option<Duration>) -> std::io::Result<()> {
	match stream {
		MaybeTlsStream::Plain(socket) => socket.set_read_timeout(timeout),
		MaybeTlsStream::NativeTls(socket) => socket.get_mut().set_read_timeout(timeout),
		_ => Err(std::io::Error::new(
			ErrorKind::Unsupported,
			"setting read timeout is not supported for this TLS backend",
		)),
	}
}

fn normal_close(reason: &'static str) -> tungstenite::protocol::CloseFrame {
	tungstenite::protocol::CloseFrame {
		code: tungstenite::protocol::frame::coding::CloseCode::Normal,
		reason: reason.into(),
	}
}

#[allow(clippy::result_large_err)]
pub fn http_parse_url(call: &EvaluatedCall, span: Span, raw_url: Value) -> Result<(String, Url), ShellError> {
	let requested_url = raw_url.coerce_into_string()?;
	let url = match Url::parse(&requested_url) {
		Ok(u) => u,
		Err(_e) => {
			return Err(ShellError::UnsupportedInput {
				msg: "Incomplete or incorrect URL. Expected a full URL, e.g., https://www.example.com".to_string(),
				input: format!("value: '{requested_url:?}'"),
				msg_span: call.head,
				input_span: span,
			});
		}
	};

	Ok((requested_url, url))
}

#[allow(clippy::result_large_err)]
pub fn request_headers(headers: Option<Value>) -> Result<HashMap<String, String>, ShellError> {
	let mut custom_headers: HashMap<String, Value> = HashMap::new();

	if let Some(headers) = headers {
		match &headers {
			Value::Record { val, .. } => {
				for (k, v) in &**val {
					custom_headers.insert(k.to_string(), v.clone());
				}
			}

			Value::List { vals: table, .. } => {
				if table.len() == 1 {
					match &table[0] {
						Value::Record { val, .. } => {
							for (k, v) in &**val {
								custom_headers.insert(k.to_string(), v.clone());
							}
						}

						x => {
							return Err(ShellError::CantConvert {
								to_type: "string list or single row".into(),
								from_type: x.get_type().to_string(),
								span: headers.span(),
								help: None,
							});
						}
					}
				} else {
					for row in table.chunks(2) {
						if row.len() == 2 {
							custom_headers.insert(row[0].coerce_string()?, row[1].clone());
						}
					}
				}
			}

			x => {
				return Err(ShellError::CantConvert {
					to_type: "string list or single row".into(),
					from_type: x.get_type().to_string(),
					span: headers.span(),
					help: None,
				});
			}
		};
	}

	let mut result = HashMap::new();
	for (k, v) in custom_headers {
		if let Ok(s) = v.coerce_into_string() {
			result.insert(k, s);
		}
	}
	Ok(result)
}
