use std::path::{Path, PathBuf};

pub fn discover_chromium_browser() -> Option<PathBuf> {
	std::env::var_os("NU_CDP_BROWSER")
		.map(PathBuf::from)
		.filter(|path| path.exists())
		.or_else(find_browser_on_host)
}

fn find_browser_on_host() -> Option<PathBuf> {
	#[cfg(target_os = "linux")]
	{
		for name in [
			"google-chrome",
			"google-chrome-stable",
			"chromium-browser",
			"chromium",
			"helium",
		] {
			if let Some(path) = find_in_path(name) {
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

fn find_in_path(binary: &str) -> Option<PathBuf> {
	let path_var = std::env::var_os("PATH")?;

	std::env::split_paths(&path_var)
		.map(|dir| dir.join(binary))
		.find(|candidate| is_executable(candidate))
}

fn is_executable(path: &Path) -> bool {
	path.is_file()
}
