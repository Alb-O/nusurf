use {
	crate::ws::client::SessionClient,
	nu_protocol::{LabeledError, Record, Value},
	std::{
		collections::HashMap,
		sync::{
			LazyLock, Mutex, MutexGuard,
			atomic::{AtomicU64, Ordering},
		},
	},
};

pub(super) struct SessionEntry {
	pub url: String,
	pub client: SessionClient,
}

static SESSIONS: LazyLock<Mutex<HashMap<String, SessionEntry>>> = LazyLock::new(|| Mutex::new(HashMap::new()));
static NEXT_SESSION_ID: AtomicU64 = AtomicU64::new(1);

pub(super) fn next_session_id() -> String {
	format!("ws{}", NEXT_SESSION_ID.fetch_add(1, Ordering::SeqCst))
}

pub(super) fn session_value(id: &str, url: &str, span: nu_protocol::Span) -> Value {
	let mut record = Record::new();
	record.push("id", Value::string(id, span));
	record.push("url", Value::string(url, span));
	Value::record(record, span)
}

pub(super) fn session_client(session_id: &str) -> Result<SessionClient, LabeledError> {
	let mut sessions = sessions_mut()?;
	prune_closed_sessions(&mut sessions);

	let Some(is_closed) = sessions.get(session_id).map(|entry| entry.client.is_closed()) else {
		return Err(LabeledError::new(format!("Session '{}' was not found", session_id)));
	};

	if is_closed {
		sessions.remove(session_id);
		return Err(LabeledError::new(format!("Session '{}' is closed", session_id)));
	}

	sessions
		.get(session_id)
		.map(|entry| entry.client.clone())
		.ok_or_else(|| LabeledError::new(format!("Session '{}' was not found", session_id)))
}

pub(super) fn sessions_mut() -> Result<MutexGuard<'static, HashMap<String, SessionEntry>>, LabeledError> {
	SESSIONS
		.lock()
		.map_err(|_| LabeledError::new("Failed to lock session registry"))
}

pub(super) fn prune_closed_sessions(sessions: &mut HashMap<String, SessionEntry>) {
	sessions.retain(|_, entry| !entry.client.is_closed());
}

pub(super) fn session_sort_key(value: &Value) -> String {
	value
		.get_data_by_key("id")
		.and_then(|value| value.coerce_str().ok().map(|value| value.to_string()))
		.unwrap_or_default()
}
