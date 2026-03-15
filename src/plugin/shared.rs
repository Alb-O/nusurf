use {
	crate::ws::client::{ReceivedMessage, WebSocketUrl},
	nu_protocol::{LabeledError, Record, Value},
	std::time::Duration,
	tracing::Level,
};

pub(super) fn init_logging(verbose: Option<Value>) {
	let level = match verbose {
		Some(Value::Int { val: 0, .. }) => Level::ERROR,
		Some(Value::Int { val: 1, .. }) => Level::WARN,
		Some(Value::Int { val: 3, .. }) => Level::DEBUG,
		Some(Value::Int { val: 4, .. }) => Level::TRACE,
		Some(Value::Int { .. }) => Level::INFO,
		_ => Level::ERROR,
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
			let duration = val.as_duration().map_err(LabeledError::from)?;
			u64::try_from(duration)
				.map(Duration::from_nanos)
				.map_err(|_| LabeledError::new("Duration cannot be negative"))
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
