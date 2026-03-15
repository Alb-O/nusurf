use {
	super::{
		WebSocketPlugin,
		convert::{json_to_nu_value, pipeline_input_to_bytes, pipeline_input_to_json, value_to_id_key},
		registry::{
			SessionEntry, next_session_id, prune_closed_sessions, session_client, session_sort_key, session_value,
			sessions_mut,
		},
		shared::{init_logging, parse_timeout, raw_message_value, validate_ws_scheme},
	},
	crate::ws::client::{DEFAULT_MAX_RAW_MESSAGES, connect, connect_session, http_parse_url, request_headers},
	nu_plugin::{EngineInterface, EvaluatedCall, PluginCommand},
	nu_protocol::{
		ByteStream, ByteStreamType, Category, LabeledError, PipelineData, Signature, SyntaxShape, Type, Value,
	},
};

pub(super) fn all_commands() -> Vec<Box<dyn PluginCommand<Plugin = WebSocketPlugin>>> {
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

struct WebSocket;
struct WebSocketOpen;
struct WebSocketSend;
struct WebSocketRecv;
struct WebSocketSendJson;
struct WebSocketRecvJson;
struct WebSocketAwait;
struct WebSocketNextEvent;
struct WebSocketClose;
struct WebSocketList;

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
		let signals = engine.signals().clone();

		if let Some((client, handle)) = connect(
			requested_url,
			timeout,
			request_headers(headers).map_err(LabeledError::from)?,
			signals.clone(),
			span,
		) {
			if let Some(data) = pipeline_input_to_bytes(input, span, false)? {
				handle.send(data).map_err(LabeledError::new)?;
			}

			return Ok(PipelineData::ByteStream(
				ByteStream::read(Box::new(client), span, signals, ByteStreamType::Unknown),
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
				"raw-buffer",
				SyntaxShape::Int,
				"number of raw messages to retain for `ws recv` or `ws recv-json`",
				Some('r'),
			)
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
		let raw_buffer: Option<i64> = call.get_flag("raw-buffer")?;
		let verbose: Option<Value> = call.get_flag("verbose")?;

		init_logging(verbose);

		let span = url.span();
		let (url_text, requested_url) = http_parse_url(call, span, url).map_err(LabeledError::from)?;
		validate_ws_scheme(&requested_url, span)?;
		let max_raw_messages = match raw_buffer {
			Some(val) if val < 0 => {
				return Err(LabeledError::new("Raw buffer size must be zero or greater")
					.with_label("Invalid raw buffer size", call.head));
			}
			Some(val) => val as usize,
			None => DEFAULT_MAX_RAW_MESSAGES,
		};

		let session_id = name.unwrap_or_else(next_session_id);
		let client = connect_session(
			requested_url,
			request_headers(headers).map_err(LabeledError::from)?,
			max_raw_messages,
		)
		.ok_or_else(|| LabeledError::new("Failed to connect to WebSocket"))?;

		let mut sessions = sessions_mut()?;
		if sessions.contains_key(&session_id) {
			return Err(LabeledError::new(format!("Session '{}' already exists", session_id)));
		}

		let value = session_value(&session_id, &url_text, span);
		sessions.insert(session_id.clone(), SessionEntry { url: url_text, client });

		Ok(PipelineData::Value(value, None))
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
		let signals = engine.signals().clone();

		let value = match client.recv_raw(timeout, &signals, call.head) {
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
		let signals = engine.signals().clone();

		let value = match client.recv_json(timeout, &signals, call.head) {
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
		let signals = engine.signals().clone();

		let value = match client.await_response(&id_key, timeout, &signals, call.head) {
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
				"session-id",
				SyntaxShape::String,
				"top-level JSON sessionId to filter on",
				Some('s'),
			)
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
		let event_session_id: Option<String> = call.get_flag("session-id")?;
		let timeout: Option<Value> = call.get_flag("max-time")?;
		let client = session_client(&session_id)?;
		let timeout = parse_timeout(timeout)?;
		let signals = engine.signals().clone();

		let value = match client.next_event(
			method.as_deref(),
			event_session_id.as_deref(),
			timeout,
			&signals,
			call.head,
		) {
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
		let mut sessions = sessions_mut()?;
		prune_closed_sessions(&mut sessions);
		let mut values = sessions
			.iter()
			.map(|(id, entry)| session_value(id, &entry.url, call.head))
			.collect::<Vec<_>>();
		values.sort_by_key(session_sort_key);
		Ok(PipelineData::Value(Value::list(values, call.head), None))
	}
}
