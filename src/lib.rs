//! Nusurf: a Nushell plugin crate for WebSocket transport commands.

mod plugin;
/// WebSocket transport primitives and session clients used by the plugin.
pub mod ws;

/// The plugin entrypoint registered by `nu_plugin_nusurf`.
pub use plugin::NusurfPlugin;
