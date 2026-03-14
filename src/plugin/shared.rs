use {
	crate::ws::client::ReceivedMessage,
	nu_protocol::{LabeledError, Record, Value},
	std::time::Duration,
};

pub(super) fn init_logging(verbose: Option<Value>) {
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

pub(super) fn validate_ws_scheme(url: &url::Url, span: nu_protocol::Span) -> Result<(), LabeledError> {
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
