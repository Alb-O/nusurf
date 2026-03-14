mod commands;
mod convert;
mod registry;
mod shared;

use nu_plugin::{Plugin, PluginCommand};

pub use self::commands::all_commands;

pub struct WebSocketPlugin;

impl Plugin for WebSocketPlugin {
	fn version(&self) -> String {
		env!("CARGO_PKG_VERSION").into()
	}

	fn commands(&self) -> Vec<Box<dyn PluginCommand<Plugin = Self>>> {
		all_commands()
	}
}
