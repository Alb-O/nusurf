use support/live_browser_runner.nu [run-live-browser-suite]

def main [
    suite: string = "browser-no-fixture" # Live browser suite to run.
    --plugin(-p): string = "target/debug/nu_plugin_ws" # Plugin binary path to load in child Nu processes.
    --fixture-binary(-f): string = "target/debug/nu_ws_live_fixture_server" # Fixture server binary for suites that need one.
    --browser(-b): string # Explicit Chromium-compatible browser path or command name.
    --port: int # Remote debugging port to launch on; random by default.
    --max-time(-m): duration = 20sec # Maximum time to wait for browser startup.
    --verbose(-v) # Print child script stdout and stderr even when scripts succeed.
] {
    if $verbose {
        run-live-browser-suite $suite --plugin $plugin --fixture-binary $fixture_binary --browser $browser --port $port --max-time (
            $max_time
        ) --verbose
    } else {
        run-live-browser-suite $suite --plugin $plugin --fixture-binary $fixture_binary --browser $browser --port $port --max-time (
            $max_time
        )
    }
}
