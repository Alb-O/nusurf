use ../../nu/cdp

const suite_catalog_file = (path self ../suites.nuon)
const include_paths_separator = (char --integer 30)

def read-trimmed-file [path: string] {
    try {
        open $path | str trim
    } catch {
        ""
    }
}

def resolve-repo-path [
    repo_root: string
    candidate: string
] {
    try {
        $candidate | path expand
    } catch {
        $"($repo_root)/($candidate)"
    }
}

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

def print-table [
    value: any
    --expanded(-e)
    --stderr(-s)
] {
    let rendered = (
        (
            if $expanded {
                $value | table --expand
            } else {
                $value | table -i false
            }
        )
        | str trim --right
    )

    if $stderr {
        print --stderr --raw --no-newline $"($rendered)\n"
    } else {
        print --raw --no-newline $"($rendered)\n"
    }
}

def format-duration-compact [duration: duration] {
    let total_ns = ($duration | into int)

    if $total_ns >= 1_000_000 {
        (($total_ns // 1_000_000) | into duration --unit ms | into string)
    } else {
        "<1ms"
    }
}

def summarize-run-results [
    run_results: list<record>
    --failed(-f)
] {
    $run_results | each {|result|
        if $failed {
            {
                suite: $result.suite
                harness: $result.harness
                status: $result.status
                path: $result.path
                duration: (format-duration-compact $result.duration)
                exit_code: $result.exit_code
            }
        } else {
            {
                suite: $result.suite
                harness: $result.harness
                status: $result.status
                path: $result.path
                duration: (format-duration-compact $result.duration)
            }
        }
    }
}

def suite-summary-record [
    suite: string
    harness: string
    script_count: int
    suite_duration: duration
    run_results: list<record>
    status: string
] {
    if $status == "ok" {
        {
            suite: $suite
            harness: $harness
            status: $status
            scripts: $script_count
            duration: (format-duration-compact $suite_duration)
        }
    } else {
        {
            suite: $suite
            harness: $harness
            status: $status
            scripts: $script_count
            completed: ($run_results | length)
            passed: ($run_results | where status == "ok" | length)
            failed: ($run_results | where status == "fail" | length)
            duration: (format-duration-compact $suite_duration)
        }
    }
}

def wait-for-file-content [path: string, max_time: duration] {
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

        sleep 100ms
    }
}

def suite-catalog [] {
    open $suite_catalog_file
}

def catalog-entry [group: string, key: string, label: string] {
    let entry = (suite-catalog | get -o $group | get -o $key)

    if $entry == null {
        error make {
            msg: $"Unknown ($label): ($key)"
        }
    }

    $entry
}

def catalog-script [script_id: string] {
    catalog-entry "scripts" $script_id "suite script"
}

def catalog-harness [harness_id: string] {
    catalog-entry "harnesses" $harness_id "suite harness" | upsert id $harness_id
}

def catalog-suite [suite: string] {
    catalog-entry "suites" $suite "test suite" | upsert name $suite
}

def leaf-suite-runs [suite: string] {
    let suite_record = (catalog-suite $suite)
    let included = $suite_record.includes?

    if $included != null {
        # suite composition stays in the catalog so wrappers only choose entrypoints.
        return (
            $included
            | each {|child_suite| leaf-suite-runs $child_suite }
            | flatten
        )
    }

    let harness_id = ($suite_record | get harness)
    let harness = (catalog-harness $harness_id)
    let scripts = (
        $suite_record
        | get scripts
        | each {|script_id|
            let script = (catalog-script $script_id)

            $script | upsert id $script_id
        }
        | where {|script| not ($script.ignore? | default false) }
    )

    [
        {
            suite: $suite
            harness: $harness
            scripts: $scripts
        }
    ]
}

def start-fixture-server [
    fixture_binary: string
    mode: string
] {
    let metadata_file = (mktemp)
    let job_id = (
        job spawn --tag $"suite-fixture-($mode)-($metadata_file | path basename)" {
            run-external $fixture_binary "--mode" $mode "--port" "0" "--port-file" $metadata_file | ignore
        }
    )
    let metadata = (wait-for-file-content $metadata_file 10sec)

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

def stop-fixture-server [fixture_server?: record] {
    let job_id = if $fixture_server != null { $fixture_server.jobId? }
    let metadata_file = if $fixture_server != null { $fixture_server.metadataFile? }

    if $job_id != null {
        try { job kill $job_id }
    }

    if (($metadata_file != null) and ($metadata_file | path exists)) {
        rm -f $metadata_file
    }
}

def run-child-script [
    repo_root: string
    plugin_path: string
    script_path: string
    script_args: list<string>
    verbose: bool
] {
    let include_paths = (
        [
            $"($repo_root)/nu"
            $"($repo_root)/tests/support"
        ]
        | str join $include_paths_separator
    )
    # child Nu runs should not inherit a stale global plugin registry.
    let plugin_registry = (mktemp)
    let absolute_script_path = (resolve-repo-path $repo_root $script_path)
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

def run-script-record [
    repo_root: string
    suite: string
    harness: string
    plugin_path: string
    script: record
    script_args: list<string>
    verbose: bool
] {
    let run_result = (run-child-script $repo_root $plugin_path $script.path $script_args $verbose)

    if $run_result.exit_code != 0 {
        print-output-section "stdout" $run_result.stdout --stderr
        print-output-section "stderr" $run_result.stderr --stderr
        error make {
            msg: $"Test script failed: ($script.path)"
        }
    }

    {
        suite: $suite
        harness: $harness
        status: "ok"
        path: $script.path
        duration: $run_result.duration
        exit_code: $run_result.exit_code
    }
}

def script-args [
    harness: record
    script: record
    context: record
] {
    let args_mode = $script.args_mode?

    # most scripts follow their harness convention; a few opt out with args_mode.
    match ($args_mode | default $harness.kind) {
        "none" => []
        "mock_ws" => [$context.ws_url]
        "mock_cdp" => [($context.http_port | into string) $context.ws_url]
        "live_browser" => (
            if ($harness.needs_fixture? | default false) {
                [($context.http_port | into string) ($context.fixture_port | into string)]
            } else {
                [($context.http_port | into string)]
            }
        )
        _ => (
            error make {
                msg: $"Unsupported script args mode: ($args_mode)"
            }
        )
    }
}

def run-suite-scripts [
    repo_root: string
    suite_run: record
    plugin_path: string
    script_context: record
    verbose: bool
] {
    $suite_run.scripts | each {|script|
        run-script-record $repo_root $suite_run.suite $suite_run.harness.id $plugin_path $script (
            script-args $suite_run.harness $script $script_context
        ) $verbose
    }
}

def run-mock-ws-suite [
    repo_root: string
    suite_run: record
    plugin_path: string
    fixture_binary: string
    verbose: bool
] {
    let fixture = (start-fixture-server $fixture_binary "ws")
    mut run_results = []

    try {
        let ws_url = $"ws://127.0.0.1:($fixture.metadata)"
        let script_context = {
            ws_url: $ws_url
        }

        $run_results = (run-suite-scripts $repo_root $suite_run $plugin_path $script_context $verbose)
    } finally {
        stop-fixture-server $fixture
    }

    $run_results
}

def run-mock-cdp-suite [
    repo_root: string
    suite_run: record
    plugin_path: string
    fixture_binary: string
    verbose: bool
] {
    let fixture = (start-fixture-server $fixture_binary "cdp")
    mut run_results = []

    try {
        let http_port = ($fixture.metadata | get httpPort)
        let ws_port = ($fixture.metadata | get wsPort)
        let ws_url = $"ws://127.0.0.1:($ws_port)"
        let script_context = {
            http_port: $http_port
            ws_url: $ws_url
        }

        $run_results = (run-suite-scripts $repo_root $suite_run $plugin_path $script_context $verbose)
    } finally {
        stop-fixture-server $fixture
    }

    $run_results
}

def run-live-browser-suite [
    repo_root: string
    suite_run: record
    plugin_path: string
    fixture_binary: string
    max_time: duration
    verbose: bool
    browser?: string
    port?: int
] {
    let chosen_port = ($port | default (random int 20000..60000))
    let needs_fixture = ($suite_run.harness.needs_fixture? | default false)
    let browser_workflow = (
        cdp browser start --browser $browser --port $chosen_port --name $"runner-browser-($chosen_port)" --max-time (
            $max_time
        )
    )
    let fixture_server = (
        if $needs_fixture {
            start-fixture-server $fixture_binary "live-http"
        }
    )
    mut run_results = []

    try {
        let script_context = {
            http_port: $chosen_port
            fixture_port: (if $fixture_server != null { $fixture_server.metadata? })
        }

        $run_results = (run-suite-scripts $repo_root $suite_run $plugin_path $script_context $verbose)
    } finally {
        stop-fixture-server $fixture_server
        cdp browser stop $browser_workflow
    }

    $run_results
}

def run-suite-harness [
    repo_root: string
    suite_run: record
    plugin_path: string
    fixture_binary: string
    max_time: duration
    verbose: bool
    browser?: string
    port?: int
] {
    # harness adapters own environment setup; scripts stay focused on assertions.
    match $suite_run.harness.kind {
        "mock_ws" => (run-mock-ws-suite $repo_root $suite_run $plugin_path $fixture_binary $verbose)
        "mock_cdp" => (run-mock-cdp-suite $repo_root $suite_run $plugin_path $fixture_binary $verbose)
        "live_browser" => (
            run-live-browser-suite $repo_root $suite_run $plugin_path $fixture_binary $max_time $verbose $browser $port
        )
        _ => (
            error make {
                msg: $"Unsupported suite harness kind: ($suite_run.harness.kind)"
            }
        )
    }
}

# Run a named test suite from the shared suite catalog.
export def "run-test-suite" [
    suite: string = "mock_all" # Suite name from tests/suites.nuon.
    --plugin(-p): string = "target/debug/nu_plugin_nusurf" # Plugin binary path to load in child Nu processes.
    --fixture-binary(-f): string = "target/debug/nusurf_live_fixture_server" # Fixture server binary for mock and live-browser suites.
    --browser(-b): string # Explicit Chromium-compatible browser path or command name for live-browser suites.
    --port: int # Remote debugging port to launch on for live-browser suites.
    --max-time(-m): duration = 20sec # Maximum time to wait for browser startup.
    --verbose(-v) # Print child script stdout and stderr even when scripts succeed.
] {
    let repo_root = ($env.PWD | path expand)
    let plugin_path = (resolve-repo-path $repo_root $plugin)
    let fixture_binary_path = (resolve-repo-path $repo_root $fixture_binary)
    let suite_runs = (leaf-suite-runs $suite)

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

    mut all_results = []
    mut summaries = []

    for suite_run in $suite_runs {
        let suite_started_at = (date now)
        let suite_name = $suite_run.suite
        let harness_name = $suite_run.harness.id
        let script_count = ($suite_run.scripts | length)
        let suite_outcome = (
            try {
                {
                    error: null
                    results: (
                        run-suite-harness $repo_root $suite_run $plugin_path $fixture_binary_path $max_time $verbose $browser $port
                    )
                }
            } catch {|err|
                {
                    error: $err
                    results: []
                }
            }
        )
        let suite_results = $suite_outcome.results
        let suite_error = $suite_outcome.error
        let suite_duration = ((date now) - $suite_started_at)

        if $suite_error != null {
            if (not ($suite_results | is-empty)) {
                print-table (summarize-run-results $suite_results --failed) --stderr
            }
            print-table (suite-summary-record $suite_name $harness_name $script_count $suite_duration $suite_results "fail") --expanded --stderr
            error make $suite_error
        }

        $all_results = ([$all_results $suite_results] | flatten)

        if $script_count > 1 {
            print-table (summarize-run-results $suite_results)
        }

        let suite_summary = (suite-summary-record $suite_name $harness_name $script_count $suite_duration $suite_results "ok")
        $summaries = ($summaries | append $suite_summary)
        print-table $suite_summary --expanded
    }

    if (($summaries | length) > 1) {
        print-table (
            $summaries
            | each {|summary|
                {
                    suite: $summary.suite
                    harness: $summary.harness
                    status: $summary.status
                    scripts: $summary.scripts
                    duration: $summary.duration
                }
            }
        ) --expanded
    }

    $all_results
}
