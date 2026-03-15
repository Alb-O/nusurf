#[cfg(not(target_arch = "wasm32"))]
use std::collections::HashMap;

use {
	nu_plugin::EvaluatedCall,
	nu_protocol::{ShellError, Signals, Span, Value},
	serde_json::Value as JsonValue,
	std::{
		collections::VecDeque,
		io::{ErrorKind, Read},
		net::TcpStream,
		sync::{
			Arc, Condvar, Mutex,
			atomic::{AtomicBool, Ordering},
			mpsc::{self, Receiver, RecvTimeoutError, TryRecvError},
		},
		thread,
		time::{Duration, Instant},
	},
	tungstenite::{
		ClientRequestBuilder, Error as WsError, Message, WebSocket,
		client::connect_with_config,
		error::ProtocolError,
		protocol::WebSocketConfig,
		stream::{MaybeTlsStream, NoDelay},
	},
};

const SOCKET_POLL_INTERVAL: Duration = Duration::from_millis(100);
pub const DEFAULT_MAX_RAW_MESSAGES: usize = 1024;
const MAX_ROUTED_RESPONSES: usize = 1024;
const MAX_ROUTED_EVENTS: usize = 1024;
const MAX_WEBSOCKET_MESSAGE_SIZE: usize = 256 << 20;
const MAX_WEBSOCKET_FRAME_SIZE: usize = 128 << 20;

type WebSocketStream = WebSocket<MaybeTlsStream<TcpStream>>;
type SharedSessionState = Arc<(Mutex<SessionQueues>, Condvar)>;
type RoutedJson = Arc<JsonValue>;

enum ControlMessage {
	Send(Vec<u8>),
	Close,
}

#[derive(Clone, Debug)]
/// A single WebSocket frame payload exposed to Nushell callers.
pub enum ReceivedMessage {
	/// UTF-8 text frame contents.
	Text(String),
	/// Raw binary frame contents.
	Binary(Vec<u8>),
}

#[derive(Clone)]
/// Cloneable sender-side handle for a running WebSocket worker thread.
pub struct SessionHandle {
	tx: mpsc::SyncSender<ControlMessage>,
	closed: Arc<AtomicBool>,
}

#[derive(Clone)]
/// High-level API for a persistent WebSocket session with routed JSON queues.
pub struct SessionClient {
	handle: SessionHandle,
	state: SharedSessionState,
}

/// Streaming reader used by the one-shot `ws` command.
///
/// Incoming frames are buffered as newline-delimited chunks so Nushell can
/// consume the socket through its standard byte-stream interface.
pub struct WebSocketClient {
	rx: Receiver<ReceivedMessage>,
	deadline: Option<Instant>,
	buf_deque: VecDeque<u8>,
	signals: Signals,
	span: Span,
}

struct SessionQueues {
	raw_messages: VecDeque<ReceivedMessage>,
	max_raw_messages: usize,
	responses_by_id: HashMap<String, VecDeque<RoutedJson>>,
	responses_all: VecDeque<(String, RoutedJson)>,
	events_all: VecDeque<RoutedJson>,
	events_by_method: HashMap<String, VecDeque<RoutedJson>>,
	closed: bool,
	close_reason: Option<String>,
}

enum ControlFlow {
	Continue,
	Closed,
}

#[derive(Clone, Debug, PartialEq, Eq)]
/// Parsed WebSocket URL fields needed by the plugin runtime.
pub struct WebSocketUrl {
	raw: String,
	scheme: String,
	host: String,
	port: Option<u16>,
}

impl WebSocketUrl {
	fn parse(raw: String) -> Option<Self> {
		let scheme_end = raw.find("://")?;
		let scheme = raw[..scheme_end].to_ascii_lowercase();
		if scheme.is_empty() {
			return None;
		}

		let remainder = &raw[scheme_end + 3..];
		if remainder.is_empty() {
			return None;
		}

		let authority_end = remainder.find(['/', '?', '#']).unwrap_or(remainder.len());
		let authority = &remainder[..authority_end];
		let host_port = authority.rsplit_once('@').map_or(authority, |(_, host_port)| host_port);
		let (host, port) = split_host_port(host_port)?;

		Some(Self {
			raw,
			scheme,
			host,
			port,
		})
	}

	pub fn as_str(&self) -> &str {
		&self.raw
	}

	pub fn scheme(&self) -> &str {
		&self.scheme
	}

	fn origin(&self) -> String {
		match self.port {
			Some(port) => format!("{}://{}:{}", self.scheme, self.host, port),
			None => format!("{}://{}", self.scheme, self.host),
		}
	}
}

fn split_host_port(authority: &str) -> Option<(String, Option<u16>)> {
	if authority.is_empty() {
		return None;
	}

	if authority.starts_with('[') {
		let host_end = authority.find(']')?;
		let host = authority[..=host_end].to_string();
		let remainder = &authority[host_end + 1..];

		return match remainder {
			"" => Some((host, None)),
			_ => remainder
				.strip_prefix(':')
				.and_then(parse_port)
				.map(|port| (host, Some(port))),
		};
	}

	match authority.rsplit_once(':') {
		Some((host, port)) if !host.is_empty() => parse_port(port).map(|port| (host.to_string(), Some(port))),
		_ => Some((authority.to_string(), None)),
	}
}

fn parse_port(port: &str) -> Option<u16> {
	(!port.is_empty() && port.bytes().all(|byte| byte.is_ascii_digit()))
		.then(|| port.parse().ok())
		.flatten()
}

impl WebSocketClient {
	/// Create a byte-stream adapter over a worker thread receiver.
	pub fn new(rx: Receiver<ReceivedMessage>, timeout: Option<Duration>, signals: Signals, span: Span) -> Self {
		Self {
			rx,
			deadline: timeout.map(|timeout| Instant::now() + timeout),
			buf_deque: VecDeque::new(),
			signals,
			span,
		}
	}

	fn enqueue_message(&mut self, message: ReceivedMessage) {
		match message {
			ReceivedMessage::Text(text) => {
				// Preserve frame boundaries in the byte stream without inventing a
				// structured protocol: each frame is emitted as one newline-terminated chunk.
				self.buf_deque.extend(text.bytes());
				self.buf_deque.push_back(b'\n');
			}
			ReceivedMessage::Binary(data) => {
				self.buf_deque.extend(data);
				self.buf_deque.push_back(b'\n');
			}
		}
	}

	fn drain_buffer(&mut self, buf: &mut [u8]) -> usize {
		let mut len = 0;
		for buf_slot in buf {
			if let Some(byte) = self.buf_deque.pop_front() {
				*buf_slot = byte;
				len += 1;
			} else {
				break;
			}
		}
		len
	}
}

impl Read for WebSocketClient {
	fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
		if !self.buf_deque.is_empty() {
			return Ok(self.drain_buffer(buf));
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
					return Ok(self.drain_buffer(buf));
				}
				Err(RecvTimeoutError::Timeout) => continue,
				Err(RecvTimeoutError::Disconnected) => return Ok(0),
			}
		}
	}
}

impl SessionHandle {
	/// Queue a frame to be written by the worker thread.
	pub fn send(&self, data: Vec<u8>) -> Result<(), String> {
		if self.closed.load(Ordering::SeqCst) {
			return Err("WebSocket session is closed".to_string());
		}

		self.tx
			.send(ControlMessage::Send(data))
			.map_err(|_| "WebSocket worker is no longer running".to_string())
	}

	/// Request an orderly shutdown of the worker thread and socket.
	pub fn close(&self) -> Result<(), String> {
		self.closed.store(true, Ordering::SeqCst);
		let _ = self.tx.send(ControlMessage::Close);
		Ok(())
	}
}

impl SessionClient {
	/// Send a raw WebSocket frame on the persistent session.
	pub fn send(&self, data: Vec<u8>) -> Result<(), String> {
		self.handle.send(data)
	}

	/// Receive the next raw frame from the session's FIFO queue.
	pub fn recv_raw(
		&self, timeout: Option<Duration>, signals: &Signals, span: Span,
	) -> Result<Option<ReceivedMessage>, String> {
		self.ensure_raw_messages_enabled()?;
		self.wait_for(timeout, signals, span, |queues| queues.raw_messages.pop_front())
	}

	/// Receive the next raw frame and parse it as JSON text.
	pub fn recv_json(
		&self, timeout: Option<Duration>, signals: &Signals, span: Span,
	) -> Result<Option<JsonValue>, String> {
		match self.recv_raw(timeout, signals, span)? {
			Some(ReceivedMessage::Text(text)) => serde_json::from_str(&text)
				.map(Some)
				.map_err(|e| format!("Failed to parse JSON message: {}", e)),
			Some(ReceivedMessage::Binary(_)) => Err("Received binary message while expecting JSON".to_string()),
			None => Ok(None),
		}
	}

	/// Wait for the next routed JSON response matching the given `id`.
	pub fn await_response(
		&self, id: &str, timeout: Option<Duration>, signals: &Signals, span: Span,
	) -> Result<Option<JsonValue>, String> {
		self.wait_for(timeout, signals, span, |queues| pop_response(queues, id))
	}

	/// Wait for the next routed JSON event, optionally filtered by method name.
	pub fn next_event(
		&self, method: Option<&str>, session_id: Option<&str>, timeout: Option<Duration>, signals: &Signals, span: Span,
	) -> Result<Option<JsonValue>, String> {
		self.wait_for(timeout, signals, span, |queues| pop_event(queues, method, session_id))
	}

	/// Close the persistent session.
	pub fn close(&self) -> Result<(), String> {
		self.handle.close()
	}

	/// Whether the session worker has already observed the socket as closed.
	pub fn is_closed(&self) -> bool {
		self.handle.closed.load(Ordering::SeqCst)
	}

	fn ensure_raw_messages_enabled(&self) -> Result<(), String> {
		let (lock, _) = &*self.state;
		let queues = lock
			.lock()
			.map_err(|_| "Failed to lock WebSocket session state".to_string())?;

		if queues.max_raw_messages == 0 {
			return Err("Raw message buffering is disabled for this session".to_string());
		}

		Ok(())
	}

	fn wait_for<T, F>(
		&self, timeout: Option<Duration>, signals: &Signals, span: Span, mut pop: F,
	) -> Result<Option<T>, String>
	where
		F: FnMut(&mut SessionQueues) -> Option<T>, {
		let deadline = timeout.map(|duration| Instant::now() + duration);
		let (lock, condvar) = &*self.state;
		let mut queues = lock
			.lock()
			.map_err(|_| "Failed to lock WebSocket session state".to_string())?;

		loop {
			if let Some(item) = pop(&mut queues) {
				return Ok(Some(item));
			}
			if queues.closed {
				return Err(queues
					.close_reason
					.clone()
					.unwrap_or_else(|| "WebSocket session is closed".to_string()));
			}
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

			// Wake periodically instead of blocking forever so interrupt signals and
			// timeouts are observed even when no new socket traffic arrives.
			let (new_queues, _) = condvar
				.wait_timeout(queues, wait_time)
				.map_err(|_| "Failed to wait for WebSocket session state".to_string())?;
			queues = new_queues;
		}
	}
}

/// Open a one-shot WebSocket connection suitable for the streaming `ws` command.
pub fn connect(
	url: WebSocketUrl, timeout: Option<Duration>, headers: HashMap<String, String>, signals: Signals, span: Span,
) -> Option<(WebSocketClient, SessionHandle)> {
	let websocket = open_websocket(url, headers)?;
	let (tx, rx, closed) = connect_components(websocket)?;
	let handle = SessionHandle { tx, closed };
	Some((WebSocketClient::new(rx, timeout, signals, span), handle))
}

/// Open a persistent WebSocket session with routed JSON response and event queues.
pub fn connect_session(
	url: WebSocketUrl, headers: HashMap<String, String>, max_raw_messages: usize,
) -> Option<SessionClient> {
	let websocket = open_websocket(url, headers)?;
	let (tx, state, closed) = connect_session_components(websocket, max_raw_messages)?;
	Some(SessionClient {
		handle: SessionHandle { tx, closed },
		state,
	})
}

fn open_websocket(url: WebSocketUrl, headers: HashMap<String, String>) -> Option<WebSocketStream> {
	tracing::trace!("Building WebSocket request for: {}", url.as_str());

	let mut builder = ClientRequestBuilder::new(url.as_str().parse().ok()?);
	let origin = websocket_origin(&url);

	tracing::trace!("Setting Origin header to: {origin}");
	builder = builder.with_header("Origin", origin);

	for (k, v) in headers {
		tracing::trace!("Adding header: {k} = {v}");
		builder = builder.with_header(k, v);
	}

	tracing::debug!("Attempting WebSocket connection...");

	match connect_with_config(builder, Some(websocket_config()), 3) {
		Ok((mut websocket, _)) => {
			tracing::debug!("WebSocket handshake completed successfully");
			configure_socket(&mut websocket).ok()?;
			Some(websocket)
		}
		Err(e) => {
			tracing::error!("Failed to connect to WebSocket: {e:?}");
			None
		}
	}
}

fn websocket_origin(url: &WebSocketUrl) -> String {
	url.origin()
}

fn connect_components(
	websocket: WebSocketStream,
) -> Option<(
	mpsc::SyncSender<ControlMessage>,
	Receiver<ReceivedMessage>,
	Arc<AtomicBool>,
)> {
	let (tx_control, rx_control) = mpsc::sync_channel(1024);
	let (tx_read, rx_read) = mpsc::sync_channel(1024);
	let closed = Arc::new(AtomicBool::new(false));

	spawn_worker_thread(websocket, rx_control, tx_read, closed.clone())?;
	Some((tx_control, rx_read, closed))
}

fn connect_session_components(
	websocket: WebSocketStream, max_raw_messages: usize,
) -> Option<(mpsc::SyncSender<ControlMessage>, SharedSessionState, Arc<AtomicBool>)> {
	let (tx_control, rx_control) = mpsc::sync_channel(1024);
	let closed = Arc::new(AtomicBool::new(false));
	let state = Arc::new((
		Mutex::new(SessionQueues {
			raw_messages: VecDeque::new(),
			max_raw_messages,
			responses_by_id: HashMap::new(),
			responses_all: VecDeque::new(),
			events_all: VecDeque::new(),
			events_by_method: HashMap::new(),
			closed: false,
			close_reason: None,
		}),
		Condvar::new(),
	));

	spawn_session_worker_thread(websocket, rx_control, state.clone(), closed.clone())?;
	Some((tx_control, state, closed))
}

fn spawn_worker_thread(
	mut websocket: WebSocketStream, rx_control: Receiver<ControlMessage>, tx_read: mpsc::SyncSender<ReceivedMessage>,
	closed: Arc<AtomicBool>,
) -> Option<thread::JoinHandle<()>> {
	thread::Builder::new()
		.name("websocket worker".to_string())
		.spawn(move || {
			tracing::debug!("WebSocket worker thread started");
			loop {
				if closed.load(Ordering::SeqCst) {
					let _ = websocket.close(Some(normal_close("session closed")));
					return;
				}

				match flush_control_messages(&mut websocket, &rx_control, &closed) {
					Ok(ControlFlow::Continue) => {}
					Ok(ControlFlow::Closed) => return,
					Err(e) => {
						tracing::error!("WebSocket control error: {e}");
						closed.store(true, Ordering::SeqCst);
						return;
					}
				}

				match websocket.read() {
					Ok(Message::Text(msg)) => {
						if tx_read.send(ReceivedMessage::Text(msg.to_string())).is_err() {
							tracing::debug!("Channel closed, closing WebSocket");
							closed.store(true, Ordering::SeqCst);
							let _ = websocket.close(Some(normal_close("receiver dropped")));
							return;
						}
					}
					Ok(Message::Binary(msg)) => {
						if tx_read.send(ReceivedMessage::Binary(msg.to_vec())).is_err() {
							tracing::debug!("Channel closed, closing WebSocket");
							closed.store(true, Ordering::SeqCst);
							let _ = websocket.close(Some(normal_close("receiver dropped")));
							return;
						}
					}
					Ok(Message::Close(_)) => {
						tracing::debug!("Received Close message");
						closed.store(true, Ordering::SeqCst);
						return;
					}
					Ok(other) => {
						tracing::trace!("Ignoring WebSocket message: {other:?}");
					}
					Err(WsError::Io(err)) if matches!(err.kind(), ErrorKind::WouldBlock | ErrorKind::TimedOut) => {
						thread::yield_now();
						continue;
					}
					Err(WsError::ConnectionClosed | WsError::AlreadyClosed) => {
						tracing::debug!("WebSocket closed");
						closed.store(true, Ordering::SeqCst);
						return;
					}
					Err(WsError::Protocol(ProtocolError::ResetWithoutClosingHandshake)) => {
						tracing::debug!("WebSocket peer reset without closing handshake");
						closed.store(true, Ordering::SeqCst);
						return;
					}
					Err(e) => {
						tracing::error!("WebSocket read error: {e:?}");
						closed.store(true, Ordering::SeqCst);
						return;
					}
				}
			}
		})
		.ok()
}

fn spawn_session_worker_thread(
	mut websocket: WebSocketStream, rx_control: Receiver<ControlMessage>, state: SharedSessionState,
	closed: Arc<AtomicBool>,
) -> Option<thread::JoinHandle<()>> {
	thread::Builder::new()
		.name("websocket session worker".to_string())
		.spawn(move || {
			tracing::debug!("WebSocket session worker thread started");
			loop {
				if closed.load(Ordering::SeqCst) {
					let _ = websocket.close(Some(normal_close("session closed")));
					mark_session_closed(&state, "WebSocket session is closed");
					return;
				}

				match flush_control_messages(&mut websocket, &rx_control, &closed) {
					Ok(ControlFlow::Continue) => {}
					Ok(ControlFlow::Closed) => {
						mark_session_closed(&state, "WebSocket session is closed");
						return;
					}
					Err(e) => {
						tracing::error!("WebSocket control error: {e}");
						closed.store(true, Ordering::SeqCst);
						mark_session_closed(&state, format!("WebSocket control error: {e}"));
						return;
					}
				}

				match websocket.read() {
					Ok(Message::Text(msg)) => enqueue_session_message(&state, ReceivedMessage::Text(msg.to_string())),
					Ok(Message::Binary(msg)) => enqueue_session_message(&state, ReceivedMessage::Binary(msg.to_vec())),
					Ok(Message::Close(_)) => {
						tracing::debug!("Received Close message");
						closed.store(true, Ordering::SeqCst);
						mark_session_closed(&state, "WebSocket session was closed by the remote peer");
						return;
					}
					Ok(other) => {
						tracing::trace!("Ignoring WebSocket message: {other:?}");
					}
					Err(WsError::Io(err)) if matches!(err.kind(), ErrorKind::WouldBlock | ErrorKind::TimedOut) => {
						thread::yield_now();
						continue;
					}
					Err(WsError::ConnectionClosed | WsError::AlreadyClosed) => {
						tracing::debug!("WebSocket closed");
						closed.store(true, Ordering::SeqCst);
						mark_session_closed(&state, "WebSocket session is closed");
						return;
					}
					Err(WsError::Protocol(ProtocolError::ResetWithoutClosingHandshake)) => {
						tracing::debug!("WebSocket peer reset without closing handshake");
						closed.store(true, Ordering::SeqCst);
						mark_session_closed(&state, "WebSocket session is closed");
						return;
					}
					Err(e) => {
						tracing::error!("WebSocket read error: {e:?}");
						closed.store(true, Ordering::SeqCst);
						mark_session_closed(&state, format!("WebSocket read error: {e}"));
						return;
					}
				}
			}
		})
		.ok()
}

fn flush_control_messages(
	websocket: &mut WebSocketStream, rx_control: &Receiver<ControlMessage>, closed: &Arc<AtomicBool>,
) -> Result<ControlFlow, String> {
	loop {
		match rx_control.try_recv() {
			Ok(ControlMessage::Send(data)) => websocket
				.send(send_message(data))
				.map_err(|e| format!("Failed to send WebSocket message: {}", e))?,
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

fn enqueue_session_message(state: &SharedSessionState, message: ReceivedMessage) {
	let (lock, condvar) = &**state;
	if let Ok(mut queues) = lock.lock() {
		if let ReceivedMessage::Text(text) = &message
			&& let Ok(json) = serde_json::from_str::<JsonValue>(text)
		{
			if let Some(id) = json_id_key(&json) {
				push_response(&mut queues, id, Arc::new(json));
			} else if let Some(method) = json_method_key(&json) {
				push_event(&mut queues, method.to_owned(), Arc::new(json));
			}
		}

		if queues.max_raw_messages > 0 {
			queues.raw_messages.push_back(message);
			while queues.raw_messages.len() > queues.max_raw_messages {
				let _ = queues.raw_messages.pop_front();
			}
		}
		condvar.notify_all();
	}
}

fn websocket_config() -> WebSocketConfig {
	WebSocketConfig::default()
		.max_message_size(Some(MAX_WEBSOCKET_MESSAGE_SIZE))
		.max_frame_size(Some(MAX_WEBSOCKET_FRAME_SIZE))
}

fn push_response(queues: &mut SessionQueues, id: String, response: RoutedJson) {
	queues
		.responses_by_id
		.entry(id.clone())
		.or_default()
		.push_back(response.clone());
	queues.responses_all.push_back((id, response));

	while queues.responses_all.len() > MAX_ROUTED_RESPONSES {
		let Some((old_id, old_response)) = queues.responses_all.pop_front() else {
			break;
		};
		let empty = if let Some(queue) = queues.responses_by_id.get_mut(&old_id) {
			remove_matching_event(queue, &old_response);
			queue.is_empty()
		} else {
			false
		};

		if empty {
			queues.responses_by_id.remove(&old_id);
		}
	}
}

fn push_event(queues: &mut SessionQueues, method: String, event: RoutedJson) {
	// Keep both a global event queue and per-method queues so consumers can mix
	// filtered and unfiltered reads without reparsing messages later.
	queues.events_all.push_back(event.clone());
	queues.events_by_method.entry(method).or_default().push_back(event);

	while queues.events_all.len() > MAX_ROUTED_EVENTS {
		let Some(old_event) = queues.events_all.pop_front() else {
			break;
		};
		let Some(method) = json_method_key(old_event.as_ref()) else {
			continue;
		};
		let empty = if let Some(queue) = queues.events_by_method.get_mut(method) {
			remove_matching_event(queue, &old_event);
			queue.is_empty()
		} else {
			false
		};

		if empty {
			queues.events_by_method.remove(method);
		}
	}
}

fn mark_session_closed(state: &SharedSessionState, reason: impl Into<String>) {
	let (lock, condvar) = &**state;
	if let Ok(mut queues) = lock.lock() {
		queues.closed = true;
		if queues.close_reason.is_none() {
			queues.close_reason = Some(reason.into());
		}
		condvar.notify_all();
	}
}

fn pop_response(queues: &mut SessionQueues, id: &str) -> Option<JsonValue> {
	let response = queues.responses_by_id.get_mut(id)?.pop_front()?;
	if matches!(queues.responses_by_id.get(id), Some(queue) if queue.is_empty()) {
		queues.responses_by_id.remove(id);
	}
	remove_matching_response(&mut queues.responses_all, id, &response);
	Some(response.as_ref().clone())
}

fn pop_event(queues: &mut SessionQueues, method: Option<&str>, session_id: Option<&str>) -> Option<JsonValue> {
	match method {
		Some(method) => {
			let event = pop_matching_event(queues.events_by_method.get_mut(method)?, session_id)?;
			let method_queue_empty = matches!(queues.events_by_method.get(method), Some(queue) if queue.is_empty());
			remove_matching_event(&mut queues.events_all, &event);

			if method_queue_empty {
				queues.events_by_method.remove(method);
			}

			Some(event.as_ref().clone())
		}
		None => {
			let event = pop_matching_event(&mut queues.events_all, session_id)?;
			let method = json_method_key(event.as_ref())?;
			let empty_after_remove = if let Some(queue) = queues.events_by_method.get_mut(method) {
				remove_matching_event(queue, &event);
				queue.is_empty()
			} else {
				false
			};

			if empty_after_remove {
				queues.events_by_method.remove(method);
			}

			Some(event.as_ref().clone())
		}
	}
}

fn pop_matching_event(queue: &mut VecDeque<RoutedJson>, session_id: Option<&str>) -> Option<RoutedJson> {
	match session_id {
		Some(session_id) => {
			let index = queue
				.iter()
				.position(|event| json_session_id_key(event.as_ref()) == Some(session_id))?;
			queue.remove(index)
		}
		None => queue.pop_front(),
	}
}

fn remove_matching_event(queue: &mut VecDeque<RoutedJson>, needle: &RoutedJson) {
	if let Some(index) = queue.iter().position(|candidate| Arc::ptr_eq(candidate, needle)) {
		queue.remove(index);
	}
}

fn remove_matching_response(queue: &mut VecDeque<(String, RoutedJson)>, id: &str, needle: &RoutedJson) {
	if let Some(index) = queue
		.iter()
		.position(|(candidate_id, candidate)| candidate_id == id && Arc::ptr_eq(candidate, needle))
	{
		queue.remove(index);
	}
}

fn json_id_key(value: &JsonValue) -> Option<String> {
	match value.get("id")? {
		JsonValue::Number(number) => Some(number.to_string()),
		JsonValue::String(text) => Some(text.clone()),
		JsonValue::Bool(flag) => Some(flag.to_string()),
		JsonValue::Null => Some("null".to_string()),
		other => Some(other.to_string()),
	}
}

fn json_method_key(value: &JsonValue) -> Option<&str> {
	value.get("method")?.as_str()
}

fn json_session_id_key(value: &JsonValue) -> Option<&str> {
	value.get("sessionId")?.as_str()
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

fn send_message(data: Vec<u8>) -> Message {
	match String::from_utf8(data) {
		Ok(text) => Message::Text(text.into()),
		Err(err) => Message::Binary(err.into_bytes().into()),
	}
}

fn normal_close(reason: &'static str) -> tungstenite::protocol::CloseFrame {
	tungstenite::protocol::CloseFrame {
		code: tungstenite::protocol::frame::coding::CloseCode::Normal,
		reason: reason.into(),
	}
}

#[allow(clippy::result_large_err)]
/// Parse a Nushell URL argument into both its original string form and parsed fields.
///
/// The original string is returned because session metadata wants the exact
/// caller-provided text, not a normalized serialization.
pub fn http_parse_url(call: &EvaluatedCall, span: Span, raw_url: Value) -> Result<(String, WebSocketUrl), ShellError> {
	let requested_url = raw_url.coerce_into_string()?;
	let url = WebSocketUrl::parse(requested_url.clone()).ok_or_else(|| ShellError::UnsupportedInput {
		msg: "Incomplete or incorrect URL. Expected a full URL, e.g., https://www.example.com".to_string(),
		input: format!("value: '{requested_url:?}'"),
		msg_span: call.head,
		input_span: span,
	})?;

	Ok((requested_url, url))
}

#[allow(clippy::result_large_err)]
/// Normalize a Nushell record or single-row table into HTTP header pairs.
pub fn request_headers(headers: Option<Value>) -> Result<HashMap<String, String>, ShellError> {
	let mut result = HashMap::new();
	let Some(headers) = headers else {
		return Ok(result);
	};
	let span = headers.span();

	match &headers {
		Value::Record { val, .. } => insert_record_headers(&mut result, val),
		Value::List { vals, .. } if vals.len() == 1 => match &vals[0] {
			Value::Record { val, .. } => insert_record_headers(&mut result, val),
			value => return Err(header_convert_error(value, span)),
		},
		Value::List { vals, .. } => {
			for row in vals.chunks(2) {
				if row.len() == 2 {
					insert_header(&mut result, row[0].coerce_string()?, &row[1]);
				}
			}
		}
		value => return Err(header_convert_error(value, span)),
	}

	Ok(result)
}

fn insert_record_headers(result: &mut HashMap<String, String>, record: &nu_protocol::Record) {
	for (key, value) in record.iter() {
		insert_header(result, key.to_owned(), value);
	}
}

fn insert_header(result: &mut HashMap<String, String>, key: String, value: &Value) {
	if let Ok(value) = value.coerce_str() {
		result.insert(key, value.into_owned());
	}
}

fn header_convert_error(value: &Value, span: Span) -> ShellError {
	ShellError::CantConvert {
		to_type: "string list or single row".into(),
		from_type: value.get_type().to_string(),
		span,
		help: None,
	}
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn websocket_origin_omits_missing_port() {
		let url = WebSocketUrl::parse("wss://example.com/devtools/browser/abc".to_string()).unwrap();
		assert_eq!(websocket_origin(&url), "wss://example.com");
	}

	#[test]
	fn websocket_origin_keeps_explicit_port() {
		let url = WebSocketUrl::parse("ws://127.0.0.1:9222/devtools/browser/abc".to_string()).unwrap();
		assert_eq!(websocket_origin(&url), "ws://127.0.0.1:9222");
	}

	#[test]
	fn websocket_url_preserves_ipv6_brackets_in_origin() {
		let url = WebSocketUrl::parse("ws://[::1]:9222/devtools/browser/abc".to_string()).unwrap();
		assert_eq!(websocket_origin(&url), "ws://[::1]:9222");
	}

	#[test]
	fn websocket_url_ignores_userinfo_for_origin() {
		let url = WebSocketUrl::parse("wss://user:pass@example.com/socket".to_string()).unwrap();
		assert_eq!(websocket_origin(&url), "wss://example.com");
	}

	#[test]
	fn websocket_url_rejects_invalid_port() {
		assert!(WebSocketUrl::parse("ws://127.0.0.1:99999/socket".to_string()).is_none());
	}

	#[test]
	fn websocket_url_normalizes_scheme_case() {
		let url = WebSocketUrl::parse("WSS://example.com/socket".to_string()).unwrap();
		assert_eq!(websocket_origin(&url), "wss://example.com");
	}
}
