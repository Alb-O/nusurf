const include_paths_separator = (char --integer 30)
const repo_root = (path self ..)

def print-output-section [
    label: string
    output?: string
    --stderr(-e)
] {
    let content = ($output | default "" | str trim)

    if $content != "" {
        let section = $"  ($label):\n($content)"

        if $stderr {
            print --stderr $section
        } else {
            print $section
        }
    }
}

def read-trimmed-file [path: string] {
    try {
        open $path | str trim
    } catch {
        ""
    }
}

def wait-for-file-content [
    path: string
    max_time: duration = 5sec
] {
    let deadline = ((date now) + $max_time)

    loop {
        let content = (read-trimmed-file $path)

        if ($content | is-not-empty) {
            return $content
        }

        if ((date now) >= $deadline) {
            error make {
                msg: $"Timed out waiting for fixture metadata at ($path)"
            }
        }

        sleep 50ms
    }
}

def resolve-repo-path [
    candidate: string
] {
    let expanded = (
        try {
            $candidate | path expand
        } catch {
            $"($repo_root)/($candidate)"
        }
    )

    $expanded
}

def start-fixture-server [
    fixture_binary: string
    mode: string
] {
    let metadata_file = (mktemp)
    let job_id = (
        job spawn --tag $"nushell-fixture-($mode)-($metadata_file | path basename)" {
            run-external $fixture_binary "--mode" $mode "--port" "0" "--port-file" $metadata_file | ignore
        }
    )
    let metadata = (wait-for-file-content $metadata_file)

    {
        jobId: $job_id
        metadataFile: $metadata_file
        metadata: (
            if $mode == "cdp" {
                $metadata | from json
            } else {
                $metadata | into int
            }
        )
    }
}

def run-suite-script [
    plugin_path: string
    script_path: string
    script_args: list<string>
    verbose: bool
] {
    if $verbose {
        run-nu-script $plugin_path $script_path ...$script_args --verbose
    } else {
        run-nu-script $plugin_path $script_path ...$script_args
    }
}

def stop-fixture-server [fixture_server?: record] {
    let job_id = ($fixture_server | get -o jobId)
    let metadata_file = ($fixture_server | get -o metadataFile)

    if $job_id != null {
        try { job kill $job_id }
    }

    if (($metadata_file != null) and ($metadata_file | path exists)) {
        rm -f $metadata_file
    }
}

def run-nu-script [
    plugin_path: string
    script_path: string
    ...script_args: string
    --verbose(-v)
] {
    let include_paths = (
        [
            $"($repo_root)/nu"
            $"($repo_root)/tests/support"
        ]
        | str join $include_paths_separator
    )
    let plugin_registry = (mktemp)
    let absolute_script_path = (resolve-repo-path $script_path)
    let timed_result = (
        timeit --output {
            ^nu --no-config-file --plugin-config $plugin_registry -I $include_paths --plugins $plugin_path -- $absolute_script_path ...$script_args
            | complete
        }
    )
    let _ = (rm -f $plugin_registry)
    let output = $timed_result.output

    if $verbose {
        print-output-section "stdout" $output.stdout
        print-output-section "stderr" $output.stderr --stderr
    }

    {
        path: $script_path
        duration: $timed_result.time
        exit_code: $output.exit_code
        stdout: $output.stdout
        stderr: $output.stderr
    }
}

def assert-run-ok [
    result: record
] {
    if $result.exit_code != 0 {
        print-output-section "stdout" $result.stdout --stderr
        print-output-section "stderr" $result.stderr --stderr
        error make {
            msg: $"Nu script failed: ($result.path)"
        }
    }

    {
        path: $result.path
        status: "ok"
        duration: $result.duration
    }
}

def run-ws-suite [
    plugin_path: string
    fixture_binary: string
    --verbose(-v)
] {
    let fixture = (start-fixture-server $fixture_binary "ws")
    mut results = []

    try {
        let ws_url = $"ws://127.0.0.1:($fixture.metadata)"
        let result = (run-suite-script $plugin_path "tests/ws/basic.nu" [$ws_url] $verbose)

        $results = [(assert-run-ok $result)]
    } finally {
        stop-fixture-server $fixture
    }

    $results
}

def run-cdp-suite [
    plugin_path: string
    fixture_binary: string
    --verbose(-v)
] {
    let fixture = (start-fixture-server $fixture_binary "cdp")
    mut results = []

    try {
        let http_port = ($fixture.metadata | get httpPort)
        let ws_port = ($fixture.metadata | get wsPort)
        let ws_url = $"ws://127.0.0.1:($ws_port)"
        let mock_result = (
            run-suite-script $plugin_path "tests/cdp/mock.nu" [($http_port | into string) $ws_url] $verbose
        )
        let schema_result = (run-suite-script $plugin_path "tests/cdp/schema.nu" [] $verbose)

        $results = [
            (assert-run-ok $mock_result)
            (assert-run-ok $schema_result)
        ]
    } finally {
        stop-fixture-server $fixture
    }

    $results
}

def main [
    suite: string = "all" # Nushell suite to run: ws, cdp, or all.
    --plugin(-p): string = "target/debug/nu_plugin_nusurf" # Plugin binary path to load in child Nu processes.
    --fixture-binary(-f): string = "target/debug/nusurf_live_fixture_server" # Fixture server binary used by mock-driven Nu scripts.
    --verbose(-v) # Print child script stdout and stderr even when scripts succeed.
] {
    let plugin_path = (resolve-repo-path $plugin)
    let fixture_binary_path = (resolve-repo-path $fixture_binary)

    if (not ($plugin_path | path exists)) {
        error make {
            msg: $"Plugin binary was not found at ($plugin_path)"
        }
    }

    if (not ($fixture_binary_path | path exists)) {
        error make {
            msg: $"Fixture binary was not found at ($fixture_binary_path)"
        }
    }

    let suite_results = (
        match $suite {
            "ws" => {
                if $verbose {
                    run-ws-suite $plugin_path $fixture_binary_path --verbose
                } else {
                    run-ws-suite $plugin_path $fixture_binary_path
                }
            }
            "cdp" => {
                if $verbose {
                    run-cdp-suite $plugin_path $fixture_binary_path --verbose
                } else {
                    run-cdp-suite $plugin_path $fixture_binary_path
                }
            }
            "all" => {
                let ws_results = (
                    if $verbose {
                        run-ws-suite $plugin_path $fixture_binary_path --verbose
                    } else {
                        run-ws-suite $plugin_path $fixture_binary_path
                    }
                )
                let cdp_results = (
                    if $verbose {
                        run-cdp-suite $plugin_path $fixture_binary_path --verbose
                    } else {
                        run-cdp-suite $plugin_path $fixture_binary_path
                    }
                )

                $ws_results | append $cdp_results
            }
            _ => {
                error make {
                    msg: $"Unknown Nushell suite: ($suite)"
                }
            }
        }
    )

    $suite_results | each {|result|
        {
            status: $result.status
            path: $result.path
            duration: ($result.duration | into string)
        }
    } | table --expand
}
