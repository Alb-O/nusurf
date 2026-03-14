use {
	nu_plugin::{EngineInterface, EvaluatedCall, Plugin, PluginCommand},
	nu_protocol::{
		ByteStream, ByteStreamType, Category, LabeledError, PipelineData, Record, Signature, SyntaxShape, Type, Value,
	},
	std::{
		collections::HashMap,
		sync::{
			LazyLock, Mutex,
			atomic::{AtomicU64, Ordering},
		},
		time::Duration,
	},
};

pub mod ws;
use ws::client::{ReceivedMessage, SessionClient, connect, connect_session, http_parse_url, request_headers};

pub struct WebSocketPlugin;

struct SessionEntry {
	url: String,
	client: SessionClient,
}

static SESSIONS: LazyLock<Mutex<HashMap<String, SessionEntry>>> = LazyLock::new(|| Mutex::new(HashMap::new()));
static NEXT_SESSION_ID: AtomicU64 = AtomicU64::new(1);

impl Plugin for WebSocketPlugin {
	fn version(&self) -> String {
		env!("CARGO_PKG_VERSION").into()
	}

	fn commands(&self) -> Vec<Box<dyn PluginCommand<Plugin = Self>>> {
		vec![
			Box::new(WebSocket),
			Box::new(WebSocketOpen),
			Box::new(WebSocketSend),
			Box::new(WebSocketRecv),
			Box::new(WebSocketClose),
			Box::new(WebSocketList),
		]
	}
}

pub struct WebSocket;
pub struct WebSocketOpen;
pub struct WebSocketSend;
pub struct WebSocketRecv;
pub struct WebSocketClose;
pub struct WebSocketList;

impl PluginCommand for WebSocket {
	type Plugin = WebSocketPlugin;

	fn name(&self) -> &str {
		"ws"
	}

	fn description(&self) -> &str {
		"connect to a websocket, send optional input data, and stream output"
	}

	fn signature(&self) -> Signature {
		Signature::build(self.name())
			.input_output_types(vec![
				(Type::Nothing, Type::Any),
				(Type::String, Type::Any),
				(Type::Binary, Type::Any),
			])
			.required("URL", SyntaxShape::String, "The URL to stream from (ws:// or wss://).")
			.named("headers", SyntaxShape::Any, "custom headers you want to add", Some('H'))
			.named(
				"max-time",
				SyntaxShape::Duration,
				"max duration before timeout occurs",
				Some('m'),
			)
			.named(
				"verbose",
				SyntaxShape::Int,
				"verbosity level (0=error, 1=warn, 2=info, 3=debug, 4=trace)",
				Some('v'),
			)
			.filter()
			.category(Category::Network)
	}

	fn run(
		&self, _plugin: &Self::Plugin, engine: &EngineInterface, call: &EvaluatedCall, input: PipelineData,
	) -> Result<PipelineData, LabeledError> {
		let url: Value = call.req(0)?;
		let headers: Option<Value> = call.get_flag("headers")?;
		let timeout: Option<Value> = call.get_flag("max-time")?;
		let verbose: Option<Value> = call.get_flag("verbose")?;

		init_logging(verbose);

		let span = url.span();
		let (_, requested_url) = http_parse_url(call, span, url).map_err(LabeledError::from)?;

		if !["ws", "wss"].contains(&requested_url.scheme()) {
			return Err(LabeledError::new("URL must use ws:// or wss://").with_label("Unsupported scheme", span));
		}

		let timeout = parse_timeout(timeout)?;

		if let Some((client, handle)) = connect(
			requested_url,
			timeout,
			request_headers(headers).map_err(LabeledError::from)?,
			engine.signals().clone(),
			span,
		) {
			if let Some(data) = pipeline_input_to_bytes(input, span, false)? {
				handle.send(data).map_err(LabeledError::new)?;
			}

			let reader = Box::new(client);

			return Ok(PipelineData::ByteStream(
				ByteStream::read(reader, span, engine.signals().clone(), ByteStreamType::Unknown),
				None,
			));
		}

		Err(LabeledError::new("Failed to connect to WebSocket"))
	}
}

impl PluginCommand for WebSocketOpen {
	type Plugin = WebSocketPlugin;

	fn name(&self) -> &str {
		"ws open"
	}

	fn description(&self) -> &str {
		"open a persistent websocket session"
	}

	fn signature(&self) -> Signature {
		Signature::build(self.name())
			.input_output_types(vec![(Type::Nothing, Type::Record(vec![].into()))])
			.required("URL", SyntaxShape::String, "The URL to connect to (ws:// or wss://).")
			.named("headers", SyntaxShape::Any, "custom headers you want to add", Some('H'))
			.named("name", SyntaxShape::String, "session name to use", Some('n'))
			.named(
				"verbose",
				SyntaxShape::Int,
				"verbosity level (0=error, 1=warn, 2=info, 3=debug, 4=trace)",
				Some('v'),
			)
			.category(Category::Network)
	}

	fn run(
		&self, _plugin: &Self::Plugin, _engine: &EngineInterface, call: &EvaluatedCall, _input: PipelineData,
	) -> Result<PipelineData, LabeledError> {
		let url: Value = call.req(0)?;
		let headers: Option<Value> = call.get_flag("headers")?;
		let name: Option<String> = call.get_flag("name")?;
		let verbose: Option<Value> = call.get_flag("verbose")?;

		init_logging(verbose);

		let span = url.span();
		let (url_text, requested_url) = http_parse_url(call, span, url).map_err(LabeledError::from)?;

		if !["ws", "wss"].contains(&requested_url.scheme()) {
			return Err(LabeledError::new("URL must use ws:// or wss://").with_label("Unsupported scheme", span));
		}

		let session_id = name.unwrap_or_else(next_session_id);
		let client = connect_session(requested_url, request_headers(headers).map_err(LabeledError::from)?)
			.ok_or_else(|| LabeledError::new("Failed to connect to WebSocket"))?;

		let mut sessions = sessions_mut()?;
		if sessions.contains_key(&session_id) {
			return Err(LabeledError::new(format!("Session '{}' already exists", session_id)));
		}

		sessions.insert(
			session_id.clone(),
			SessionEntry {
				url: url_text.clone(),
				client,
			},
		);

		Ok(PipelineData::Value(session_value(&session_id, &url_text, span), None))
	}
}

impl PluginCommand for WebSocketSend {
	type Plugin = WebSocketPlugin;

	fn name(&self) -> &str {
		"ws send"
	}

	fn description(&self) -> &str {
		"send a message on a persistent websocket session"
	}

	fn signature(&self) -> Signature {
		Signature::build(self.name())
			.input_output_types(vec![(Type::String, Type::Nothing), (Type::Binary, Type::Nothing)])
			.required("SESSION", SyntaxShape::String, "session id returned by `ws open`")
			.filter()
			.category(Category::Network)
	}

	fn run(
		&self, _plugin: &Self::Plugin, _engine: &EngineInterface, call: &EvaluatedCall, input: PipelineData,
	) -> Result<PipelineData, LabeledError> {
		let session_id: String = call.req(0)?;
		let client = session_client(&session_id)?;
		let data = pipeline_input_to_bytes(input, call.head, true)?
			.ok_or_else(|| LabeledError::new("Input must be string or binary"))?;

		client.send(data).map_err(LabeledError::new)?;
		Ok(PipelineData::Value(Value::nothing(call.head), None))
	}
}

impl PluginCommand for WebSocketRecv {
	type Plugin = WebSocketPlugin;

	fn name(&self) -> &str {
		"ws recv"
	}

	fn description(&self) -> &str {
		"receive the next message from a persistent websocket session"
	}

	fn signature(&self) -> Signature {
		Signature::build(self.name())
			.input_output_types(vec![(Type::Nothing, Type::Any)])
			.required("SESSION", SyntaxShape::String, "session id returned by `ws open`")
			.named(
				"max-time",
				SyntaxShape::Duration,
				"max duration before timeout occurs",
				Some('m'),
			)
			.switch("full", "return a record with message type and payload", Some('f'))
			.category(Category::Network)
	}

	fn run(
		&self, _plugin: &Self::Plugin, engine: &EngineInterface, call: &EvaluatedCall, _input: PipelineData,
	) -> Result<PipelineData, LabeledError> {
		let session_id: String = call.req(0)?;
		let timeout: Option<Value> = call.get_flag("max-time")?;
		let full = call.has_flag("full")?;
		let client = session_client(&session_id)?;
		let timeout = parse_timeout(timeout)?;

		let value = match client.recv(timeout, &engine.signals().clone(), call.head) {
			Ok(Some(message)) => message_value(message, call.head, full),
			Ok(None) => Value::nothing(call.head),
			Err(err) => return Err(LabeledError::new(err)),
		};

		Ok(PipelineData::Value(value, None))
	}
}

impl PluginCommand for WebSocketClose {
	type Plugin = WebSocketPlugin;

	fn name(&self) -> &str {
		"ws close"
	}

	fn description(&self) -> &str {
		"close a persistent websocket session"
	}

	fn signature(&self) -> Signature {
		Signature::build(self.name())
			.input_output_types(vec![(Type::Nothing, Type::Record(vec![].into()))])
			.required("SESSION", SyntaxShape::String, "session id returned by `ws open`")
			.category(Category::Network)
	}

	fn run(
		&self, _plugin: &Self::Plugin, _engine: &EngineInterface, call: &EvaluatedCall, _input: PipelineData,
	) -> Result<PipelineData, LabeledError> {
		let session_id: String = call.req(0)?;
		let entry = sessions_mut()?
			.remove(&session_id)
			.ok_or_else(|| LabeledError::new(format!("Session '{}' was not found", session_id)))?;

		entry.client.close().map_err(LabeledError::new)?;
		Ok(PipelineData::Value(
			session_value(&session_id, &entry.url, call.head),
			None,
		))
	}
}

impl PluginCommand for WebSocketList {
	type Plugin = WebSocketPlugin;

	fn name(&self) -> &str {
		"ws list"
	}

	fn description(&self) -> &str {
		"list persistent websocket sessions"
	}

	fn signature(&self) -> Signature {
		Signature::build(self.name())
			.input_output_types(vec![(Type::Nothing, Type::List(Box::new(Type::Record(vec![].into()))))])
			.category(Category::Network)
	}

	fn run(
		&self, _plugin: &Self::Plugin, _engine: &EngineInterface, call: &EvaluatedCall, _input: PipelineData,
	) -> Result<PipelineData, LabeledError> {
		let sessions = sessions_mut()?;
		let mut values = sessions
			.iter()
			.map(|(id, entry)| session_value(id, &entry.url, call.head))
			.collect::<Vec<_>>();
		values.sort_by(|left, right| session_sort_key(left).cmp(&session_sort_key(right)));
		Ok(PipelineData::Value(Value::list(values, call.head), None))
	}
}

fn init_logging(verbose: Option<Value>) {
	let log_level_filter = if let Some(Value::Int { val, .. }) = verbose {
		match val {
			0 => log::LevelFilter::Error,
			1 => log::LevelFilter::Warn,
			2 => log::LevelFilter::Info,
			3 => log::LevelFilter::Debug,
			4 => log::LevelFilter::Trace,
			_ => log::LevelFilter::Info,
		}
	} else {
		log::LevelFilter::Error
	};

	let _ = env_logger::Builder::from_default_env()
		.filter_level(log_level_filter)
		.try_init();
}

fn parse_timeout(timeout: Option<Value>) -> Result<Option<Duration>, LabeledError> {
	timeout
		.map(|val| {
			val.as_duration()
				.map(|duration| Duration::from_nanos(duration as u64))
				.map_err(LabeledError::from)
		})
		.transpose()
}

fn pipeline_input_to_bytes(
	input: PipelineData, span: nu_protocol::Span, require_input: bool,
) -> Result<Option<Vec<u8>>, LabeledError> {
	match input {
		PipelineData::Value(Value::String { val, .. }, ..) => Ok(Some(val.into_bytes())),
		PipelineData::Value(Value::Binary { val, .. }, ..) => Ok(Some(val)),
		PipelineData::ByteStream(stream, ..) => stream
			.into_bytes()
			.map(Some)
			.map_err(|e| LabeledError::new(e.to_string())),
		PipelineData::Empty if !require_input => Ok(None),
		PipelineData::Empty => {
			Err(LabeledError::new("Input must be string or binary").with_label("Missing input", span))
		}
		_ => Err(LabeledError::new("Input must be string or binary").with_label("Unsupported input type", span)),
	}
}

fn message_value(message: ReceivedMessage, span: nu_protocol::Span, full: bool) -> Value {
	match message {
		ReceivedMessage::Text(text) if !full => Value::string(text, span),
		ReceivedMessage::Binary(data) if !full => Value::binary(data, span),
		ReceivedMessage::Text(text) => {
			let mut record = Record::new();
			record.push("type", Value::string("text", span));
			record.push("data", Value::string(text, span));
			Value::record(record, span)
		}
		ReceivedMessage::Binary(data) => {
			let mut record = Record::new();
			record.push("type", Value::string("binary", span));
			record.push("data", Value::binary(data, span));
			Value::record(record, span)
		}
	}
}

fn session_value(id: &str, url: &str, span: nu_protocol::Span) -> Value {
	let mut record = Record::new();
	record.push("id", Value::string(id, span));
	record.push("url", Value::string(url, span));
	Value::record(record, span)
}

fn next_session_id() -> String {
	format!("ws{}", NEXT_SESSION_ID.fetch_add(1, Ordering::SeqCst))
}

fn session_client(session_id: &str) -> Result<SessionClient, LabeledError> {
	let sessions = sessions_mut()?;
	sessions
		.get(session_id)
		.map(|entry| entry.client.clone())
		.ok_or_else(|| LabeledError::new(format!("Session '{}' was not found", session_id)))
}

fn sessions_mut() -> Result<std::sync::MutexGuard<'static, HashMap<String, SessionEntry>>, LabeledError> {
	SESSIONS
		.lock()
		.map_err(|_| LabeledError::new("Failed to lock session registry"))
}

fn session_sort_key(value: &Value) -> String {
	value
		.get_data_by_key("id")
		.and_then(|value| value.coerce_str().ok().map(|value| value.to_string()))
		.unwrap_or_default()
}
