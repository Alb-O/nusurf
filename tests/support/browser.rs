use std::path::{Path, PathBuf};

pub fn discover_chromium_browser() -> Option<PathBuf> {
	[std::env::var_os("NU_CDP_BROWSER"), std::env::var_os("BROWSER")]
		.into_iter()
		.flatten()
		.flat_map(env_browser_candidates)
		.find_map(resolve_path_candidate)
		.or_else(find_browser_on_host)
}

fn find_browser_on_host() -> Option<PathBuf> {
	#[cfg(target_os = "linux")]
	{
		for name in [
			"google-chrome",
			"google-chrome-stable",
			"chromium",
			"chromium-browser",
			"chrome",
			"brave-browser",
			"microsoft-edge",
			"microsoft-edge-stable",
			"vivaldi",
			"vivaldi-stable",
			"opera",
			"helium",
		] {
			if let Some(path) = resolve_path_candidate(name) {
				return Some(path);
			}
		}
	}

	#[cfg(target_os = "macos")]
	{
		for path in [
			"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
			"/Applications/Google Chrome Canary.app/Contents/MacOS/Google Chrome Canary",
			"/Applications/Chromium.app/Contents/MacOS/Chromium",
		] {
			let path = PathBuf::from(path);
			if path.exists() {
				return Some(path);
			}
		}
	}

	#[cfg(target_os = "windows")]
	{
		for path in [
			r"C:\Program Files\Google\Chrome\Application\chrome.exe",
			r"C:\Program Files (x86)\Google\Chrome\Application\chrome.exe",
		] {
			let path = PathBuf::from(path);
			if path.exists() {
				return Some(path);
			}
		}
	}

	None
}

fn env_browser_candidates(raw: std::ffi::OsString) -> Vec<String> {
	let raw = raw.to_string_lossy();
	let trimmed = raw.trim();
	if trimmed.is_empty() {
		return vec![];
	}

	let first_segment = trimmed.split(':').next().unwrap_or(trimmed).trim();
	let first_word = first_segment.split_whitespace().next().unwrap_or(first_segment);

	[trimmed, first_word]
		.into_iter()
		.filter(|candidate| !candidate.is_empty())
		.map(str::to_string)
		.collect()
}

fn resolve_path_candidate(candidate: impl AsRef<Path>) -> Option<PathBuf> {
	let candidate = candidate.as_ref();

	if candidate.exists() {
		return Some(candidate.to_path_buf());
	}

	candidate
		.file_name()
		.and_then(|name| find_in_path(name.to_string_lossy().as_ref()))
}

fn find_in_path(binary: &str) -> Option<PathBuf> {
	let path_var = std::env::var_os("PATH")?;

	std::env::split_paths(&path_var)
		.map(|dir| dir.join(binary))
		.find(|candidate| is_executable(candidate))
}

fn is_executable(path: &Path) -> bool {
	path.is_file()
}
