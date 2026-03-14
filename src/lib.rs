//! Nushell plugin crate for WebSocket transport commands.

mod plugin;
/// WebSocket transport primitives and session clients used by the plugin.
pub mod ws;

/// The plugin entrypoint registered by `nu-plugin-ws`.
pub use plugin::WebSocketPlugin;
