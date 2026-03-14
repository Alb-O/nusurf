use {
	nu_plugin::{EngineInterface, EvaluatedCall, Plugin, PluginCommand},
	nu_protocol::{
		ByteStream, ByteStreamType, Category, LabeledError, PipelineData, Record, Signature, SyntaxShape, Type, Value,
	},
	serde_json::{Map as JsonMap, Number as JsonNumber, Value as JsonValue},
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
			Box::new(WebSocketSendJson),
			Box::new(WebSocketRecvJson),
			Box::new(WebSocketAwait),
			Box::new(WebSocketNextEvent),
			Box::new(WebSocketClose),
			Box::new(WebSocketList),
		]
	}
}

pub struct WebSocket;
pub struct WebSocketOpen;
pub struct WebSocketSend;
pub struct WebSocketRecv;
pub struct WebSocketSendJson;
pub struct WebSocketRecvJson;
pub struct WebSocketAwait;
pub struct WebSocketNextEvent;
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
		validate_ws_scheme(&requested_url, span)?;
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

			return Ok(PipelineData::ByteStream(
				ByteStream::read(
					Box::new(client),
					span,
					engine.signals().clone(),
					ByteStreamType::Unknown,
				),
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
		validate_ws_scheme(&requested_url, span)?;

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
		"receive the next raw message from a persistent websocket session"
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

		let value = match client.recv_raw(timeout, &engine.signals().clone(), call.head) {
			Ok(Some(message)) => raw_message_value(message, call.head, full),
			Ok(None) => Value::nothing(call.head),
			Err(err) => return Err(LabeledError::new(err)),
		};

		Ok(PipelineData::Value(value, None))
	}
}

impl PluginCommand for WebSocketSendJson {
	type Plugin = WebSocketPlugin;

	fn name(&self) -> &str {
		"ws send-json"
	}

	fn description(&self) -> &str {
		"send structured JSON on a persistent websocket session"
	}

	fn signature(&self) -> Signature {
		Signature::build(self.name())
			.input_output_types(vec![(Type::Any, Type::Nothing)])
			.required("SESSION", SyntaxShape::String, "session id returned by `ws open`")
			.filter()
			.category(Category::Network)
	}

	fn run(
		&self, _plugin: &Self::Plugin, _engine: &EngineInterface, call: &EvaluatedCall, input: PipelineData,
	) -> Result<PipelineData, LabeledError> {
		let session_id: String = call.req(0)?;
		let client = session_client(&session_id)?;
		let json = pipeline_input_to_json(input, call.head)?;
		let bytes = serde_json::to_vec(&json)
			.map_err(|e| LabeledError::new(format!("Failed to serialize JSON payload: {}", e)))?;

		client.send(bytes).map_err(LabeledError::new)?;
		Ok(PipelineData::Value(Value::nothing(call.head), None))
	}
}

impl PluginCommand for WebSocketRecvJson {
	type Plugin = WebSocketPlugin;

	fn name(&self) -> &str {
		"ws recv-json"
	}

	fn description(&self) -> &str {
		"receive the next JSON message from a persistent websocket session"
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
			.category(Category::Network)
	}

	fn run(
		&self, _plugin: &Self::Plugin, engine: &EngineInterface, call: &EvaluatedCall, _input: PipelineData,
	) -> Result<PipelineData, LabeledError> {
		let session_id: String = call.req(0)?;
		let timeout: Option<Value> = call.get_flag("max-time")?;
		let client = session_client(&session_id)?;
		let timeout = parse_timeout(timeout)?;

		let value = match client.recv_json(timeout, &engine.signals().clone(), call.head) {
			Ok(Some(json)) => json_to_nu_value(json, call.head),
			Ok(None) => Value::nothing(call.head),
			Err(err) => return Err(LabeledError::new(err)),
		};

		Ok(PipelineData::Value(value, None))
	}
}

impl PluginCommand for WebSocketAwait {
	type Plugin = WebSocketPlugin;

	fn name(&self) -> &str {
		"ws await"
	}

	fn description(&self) -> &str {
		"wait for the JSON response with the given id on a persistent websocket session"
	}

	fn signature(&self) -> Signature {
		Signature::build(self.name())
			.input_output_types(vec![(Type::Nothing, Type::Any)])
			.required("SESSION", SyntaxShape::String, "session id returned by `ws open`")
			.required("ID", SyntaxShape::Any, "JSON response id to wait for")
			.named(
				"max-time",
				SyntaxShape::Duration,
				"max duration before timeout occurs",
				Some('m'),
			)
			.category(Category::Network)
	}

	fn run(
		&self, _plugin: &Self::Plugin, engine: &EngineInterface, call: &EvaluatedCall, _input: PipelineData,
	) -> Result<PipelineData, LabeledError> {
		let session_id: String = call.req(0)?;
		let id: Value = call.req(1)?;
		let timeout: Option<Value> = call.get_flag("max-time")?;
		let client = session_client(&session_id)?;
		let timeout = parse_timeout(timeout)?;
		let id_key = value_to_id_key(&id)?;

		let value = match client.await_response(&id_key, timeout, &engine.signals().clone(), call.head) {
			Ok(Some(json)) => json_to_nu_value(json, call.head),
			Ok(None) => Value::nothing(call.head),
			Err(err) => return Err(LabeledError::new(err)),
		};

		Ok(PipelineData::Value(value, None))
	}
}

impl PluginCommand for WebSocketNextEvent {
	type Plugin = WebSocketPlugin;

	fn name(&self) -> &str {
		"ws next-event"
	}

	fn description(&self) -> &str {
		"receive the next routed JSON event from a persistent websocket session"
	}

	fn signature(&self) -> Signature {
		Signature::build(self.name())
			.input_output_types(vec![(Type::Nothing, Type::Any)])
			.required("SESSION", SyntaxShape::String, "session id returned by `ws open`")
			.optional("METHOD", SyntaxShape::String, "event method to filter on")
			.named(
				"max-time",
				SyntaxShape::Duration,
				"max duration before timeout occurs",
				Some('m'),
			)
			.category(Category::Network)
	}

	fn run(
		&self, _plugin: &Self::Plugin, engine: &EngineInterface, call: &EvaluatedCall, _input: PipelineData,
	) -> Result<PipelineData, LabeledError> {
		let session_id: String = call.req(0)?;
		let method: Option<String> = call.opt(1)?;
		let timeout: Option<Value> = call.get_flag("max-time")?;
		let client = session_client(&session_id)?;
		let timeout = parse_timeout(timeout)?;

		let value = match client.next_event(method.as_deref(), timeout, &engine.signals().clone(), call.head) {
			Ok(Some(json)) => json_to_nu_value(json, call.head),
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
		values.sort_by_key(session_sort_key);
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

fn validate_ws_scheme(url: &url::Url, span: nu_protocol::Span) -> Result<(), LabeledError> {
	if ["ws", "wss"].contains(&url.scheme()) {
		Ok(())
	} else {
		Err(LabeledError::new("URL must use ws:// or wss://").with_label("Unsupported scheme", span))
	}
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

fn pipeline_input_to_json(input: PipelineData, span: nu_protocol::Span) -> Result<JsonValue, LabeledError> {
	match input {
		PipelineData::Value(value, ..) => value_to_json(value),
		PipelineData::ListStream(stream, ..) => stream.into_value().map_err(LabeledError::from).and_then(value_to_json),
		PipelineData::ByteStream(stream, ..) => {
			let bytes = stream.into_bytes().map_err(|e| LabeledError::new(e.to_string()))?;
			let text = String::from_utf8(bytes)
				.map_err(|e| LabeledError::new(format!("JSON byte stream is not valid UTF-8: {}", e)))?;
			serde_json::from_str(&text).map_err(|e| LabeledError::new(format!("Failed to parse JSON payload: {}", e)))
		}
		PipelineData::Empty => Err(LabeledError::new("JSON input is required").with_label("Missing input", span)),
	}
}

fn value_to_json(value: Value) -> Result<JsonValue, LabeledError> {
	match value {
		Value::Nothing { .. } => Ok(JsonValue::Null),
		Value::Bool { val, .. } => Ok(JsonValue::Bool(val)),
		Value::Int { val, .. } => Ok(JsonValue::Number(val.into())),
		Value::Float { val, .. } => JsonNumber::from_f64(val)
			.map(JsonValue::Number)
			.ok_or_else(|| LabeledError::new("Cannot encode non-finite float as JSON")),
		Value::String { val, .. } | Value::Glob { val, .. } => Ok(JsonValue::String(val)),
		Value::Record { val, .. } => {
			let mut object = JsonMap::new();
			for (key, item) in val.iter() {
				object.insert(key.to_string(), value_to_json(item.clone())?);
			}
			Ok(JsonValue::Object(object))
		}
		Value::List { vals, .. } => vals
			.into_iter()
			.map(value_to_json)
			.collect::<Result<Vec<_>, _>>()
			.map(JsonValue::Array),
		Value::Binary { .. } => Err(LabeledError::new("Binary values cannot be encoded as JSON")),
		Value::Error { error, .. } => Err(LabeledError::new(format!("Cannot encode error as JSON: {}", error))),
		other => Err(LabeledError::new(format!(
			"Cannot encode Nushell value of type '{}' as JSON",
			other.get_type()
		))),
	}
}

fn value_to_id_key(value: &Value) -> Result<String, LabeledError> {
	match value {
		Value::Int { val, .. } => Ok(val.to_string()),
		Value::String { val, .. } => Ok(val.clone()),
		Value::Bool { val, .. } => Ok(val.to_string()),
		Value::Nothing { .. } => Ok("null".to_string()),
		other => Err(LabeledError::new(format!(
			"Unsupported response id type '{}'",
			other.get_type()
		))),
	}
}

fn json_to_nu_value(value: JsonValue, span: nu_protocol::Span) -> Value {
	match value {
		JsonValue::Null => Value::nothing(span),
		JsonValue::Bool(val) => Value::bool(val, span),
		JsonValue::Number(number) => {
			if let Some(val) = number.as_i64() {
				Value::int(val, span)
			} else if let Some(val) = number.as_u64() {
				if let Ok(val) = i64::try_from(val) {
					Value::int(val, span)
				} else {
					Value::float(val as f64, span)
				}
			} else {
				Value::float(number.as_f64().unwrap_or_default(), span)
			}
		}
		JsonValue::String(val) => Value::string(val, span),
		JsonValue::Array(values) => Value::list(
			values.into_iter().map(|value| json_to_nu_value(value, span)).collect(),
			span,
		),
		JsonValue::Object(object) => {
			let mut record = Record::new();
			for (key, value) in object {
				record.push(key, json_to_nu_value(value, span));
			}
			Value::record(record, span)
		}
	}
}

fn raw_message_value(message: ReceivedMessage, span: nu_protocol::Span, full: bool) -> Value {
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
