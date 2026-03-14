use {
	nu_plugin::{JsonSerializer, serve_plugin},
	nu_plugin_ws::WebSocketPlugin,
};

fn main() {
	serve_plugin(&WebSocketPlugin, JsonSerializer)
}
