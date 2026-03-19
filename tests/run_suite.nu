use support/suite_runner.nu [run-test-suite]

def main [
    suite: string = "mock_all" # Suite name from tests/suites.nuon.
    --plugin(-p): string = "../nu_session/target/debug/nu_plugin_nusurf" # Plugin binary path to load in child Nu processes.
    --fixture-binary(-f): string = "../nu_session/target/debug/nusurf_live_fixture_server" # Fixture server binary for mock and live-browser suites.
    --browser(-b): string # Explicit Chromium-compatible browser path or command name for live-browser suites.
    --port: int # Remote debugging port to launch on for live-browser suites.
    --max-time(-m): duration = 20sec # Maximum time to wait for browser startup.
    --verbose(-v) # Print child script stdout and stderr even when scripts succeed.
] {
    run-test-suite $suite --plugin $plugin --fixture-binary $fixture_binary --browser $browser --port $port --max-time (
        $max_time
    ) --verbose=$verbose
}
