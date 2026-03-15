use support/suite_runner.nu [run-test-suite]

def main [
    suite: string = "mock_all" # Mock-driven suite to run from the shared suite catalog.
    --plugin(-p): string = "target/debug/nu_plugin_nusurf" # Plugin binary path to load in child Nu processes.
    --fixture-binary(-f): string = "target/debug/nusurf_live_fixture_server" # Fixture server binary used by mock-driven suites.
    --verbose(-v) # Print child script stdout and stderr even when scripts succeed.
] {
    if $verbose {
        run-test-suite $suite --plugin $plugin --fixture-binary $fixture_binary --verbose
    } else {
        run-test-suite $suite --plugin $plugin --fixture-binary $fixture_binary
    }
}
