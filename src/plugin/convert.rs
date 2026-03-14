use {
	nu_protocol::{LabeledError, PipelineData, Record, Value},
	serde_json::{Map as JsonMap, Number as JsonNumber, Value as JsonValue},
};

pub(super) fn pipeline_input_to_bytes(
	input: PipelineData, span: nu_protocol::Span, require_input: bool,
) -> Result<Option<Vec<u8>>, LabeledError> {
	const INPUT_ERROR: &str = "Input must be string or binary";

	match input {
		PipelineData::Value(Value::String { val, .. }, ..) => Ok(Some(val.into_bytes())),
		PipelineData::Value(Value::Binary { val, .. }, ..) => Ok(Some(val)),
		PipelineData::ByteStream(stream, ..) => stream
			.into_bytes()
			.map(Some)
			.map_err(|e| LabeledError::new(e.to_string())),
		PipelineData::Empty if !require_input => Ok(None),
		PipelineData::Empty => Err(LabeledError::new(INPUT_ERROR).with_label("Missing input", span)),
		_ => Err(LabeledError::new(INPUT_ERROR).with_label("Unsupported input type", span)),
	}
}

pub(super) fn pipeline_input_to_json(input: PipelineData, span: nu_protocol::Span) -> Result<JsonValue, LabeledError> {
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

pub(super) fn value_to_json(value: Value) -> Result<JsonValue, LabeledError> {
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
			for (key, item) in val.into_owned() {
				object.insert(key, value_to_json(item)?);
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

pub(super) fn value_to_id_key(value: &Value) -> Result<String, LabeledError> {
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

pub(super) fn json_to_nu_value(value: JsonValue, span: nu_protocol::Span) -> Value {
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
