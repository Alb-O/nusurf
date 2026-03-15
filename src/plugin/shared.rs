use {
	crate::ws::client::{ReceivedMessage, WebSocketUrl},
	nu_protocol::{LabeledError, Record, Value},
	std::time::Duration,
	tracing::Level,
};

pub(super) fn init_logging(verbose: Option<Value>) {
	let level = if let Some(Value::Int { val, .. }) = verbose {
		match val {
			0 => Level::ERROR,
			1 => Level::WARN,
			2 => Level::INFO,
			3 => Level::DEBUG,
			4 => Level::TRACE,
			_ => Level::INFO,
		}
	} else {
		Level::ERROR
	};

	let subscriber = tracing_subscriber::fmt()
		.with_max_level(level)
		.with_ansi(false)
		.without_time()
		.finish();
	let _ = tracing::subscriber::set_global_default(subscriber);
}

pub(super) fn validate_ws_scheme(url: &WebSocketUrl, span: nu_protocol::Span) -> Result<(), LabeledError> {
	if ["ws", "wss"].contains(&url.scheme()) {
		Ok(())
	} else {
		Err(LabeledError::new("URL must use ws:// or wss://").with_label("Unsupported scheme", span))
	}
}

pub(super) fn parse_timeout(timeout: Option<Value>) -> Result<Option<Duration>, LabeledError> {
	timeout
		.map(|val| {
			val.as_duration()
				.map(|duration| Duration::from_nanos(duration as u64))
				.map_err(LabeledError::from)
		})
		.transpose()
}

pub(super) fn raw_message_value(message: ReceivedMessage, span: nu_protocol::Span, full: bool) -> Value {
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
