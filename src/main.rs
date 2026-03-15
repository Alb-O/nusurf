use {
	nu_plugin::{JsonSerializer, serve_plugin},
	nusurf::NusurfPlugin,
};

fn main() {
	serve_plugin(&NusurfPlugin, JsonSerializer)
}
