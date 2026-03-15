use ../../nu/cdp.nu *

const live_browser_suites_file = (path self ../live_browser_suites.nuon)
const include_paths_separator = (char --integer 30)

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
                status: $result.status
                path: $result.path
                duration: (format-duration-compact $result.duration)
                fixture: $result.fixture
                exit_code: $result.exit_code
            }
        } else {
            {
                status: $result.status
                path: $result.path
                duration: (format-duration-compact $result.duration)
            }
        }
    }
}

def suite-summary-record [
    suite: string
    script_count: int
    suite_duration: duration
    run_results: list<record>
    status: string
] {
    if $status == "ok" {
        {
            suite: $suite
            status: $status
            scripts: $script_count
            duration: (format-duration-compact $suite_duration)
        }
    } else {
        {
            suite: $suite
            status: $status
            scripts: $script_count
            completed: ($run_results | length)
            passed: ($run_results | where status == "ok" | length)
            failed: ($run_results | where status == "fail" | length)
            duration: (format-duration-compact $suite_duration)
        }
    }
}

def run-live-script [
    repo_root: string
    plugin_path: string
    script_path: string
    script_args: list<string>
    --verbose(-v)
] {
    let child_script_path = (
        try {
            $script_path | path expand
        } catch {
            $"($repo_root)/($script_path)"
        }
    )
    let include_paths = (
        [
            $"($repo_root)/nu"
            $"($repo_root)/tests/support"
        ]
        | str join $include_paths_separator
    )
    let timed_result = (
        timeit --output {
            ^nu --no-config-file -I $include_paths --plugins $plugin_path -- $child_script_path ...$script_args
            | complete
        }
    )
    let duration = $timed_result.time
    let result = $timed_result.output

    if $verbose {
        print-output-section "stdout" $result.stdout
        print-output-section "stderr" $result.stderr --stderr
    }

    {
        path: $script_path
        duration: $duration
        exitCode: $result.exit_code
        stdout: $result.stdout
        stderr: $result.stderr
    }
}

def live-browser-suite-config [] {
    open $live_browser_suites_file
}

def suite-script-ids [suite: string] {
    let config = (live-browser-suite-config)
    let script_ids = ($config | get -o suites | get -o $suite)

    if $script_ids == null {
        error make {
            msg: $"Unknown live browser suite: ($suite)"
        }
    }

    $script_ids
}

def resolve-suite-script [suite: string, script_id: string] {
    let config = (live-browser-suite-config)
    let script = ($config | get -o scripts | get -o $script_id)

    if $script == null {
        error make {
            msg: $"Unknown live browser script id in suite ($suite): ($script_id)"
        }
    }

    $script
}

def suite-scripts [suite: string] {
    suite-script-ids $suite | each {|script_id|
        resolve-suite-script $suite $script_id
    }
}

def active-suite-scripts [suite: string] {
    suite-scripts $suite | where {|script|
        not (($script | get -o ignore) | default false)
    }
}

def wait-for-file-content [path: string, max_time: duration] {
    let deadline = (date now) + $max_time

    loop {
        if (($path | path exists) and (((open $path | str trim) | is-not-empty))) {
            return (open $path | str trim)
        }

        if ((date now) >= $deadline) {
            error make {
                msg: $"Timed out waiting for fixture server port file at ($path)"
            }
        }

        sleep 100ms
    }
}

def start-fixture-server [fixture_binary: string] {
    let port_file = (mktemp)
    let job_id = (
        job spawn --tag $"fixture-server-($port_file | path basename)" {
            run-external $fixture_binary "--port" "0" "--port-file" $port_file | ignore
        }
    )
    let port = (wait-for-file-content $port_file 10sec | into int)

    {
        jobId: $job_id
        port: $port
        portFile: $port_file
    }
}

def stop-fixture-server [fixture_server?: record] {
    let job_id = ($fixture_server | get -o jobId)
    let port_file = ($fixture_server | get -o portFile)

    if $job_id != null {
        try { job kill $job_id }
    }

    if (($port_file != null) and ($port_file | path exists)) {
        rm -f $port_file
    }
}

# Run a named live browser suite with a managed browser session and optional fixture server.
export def "run-live-browser-suite" [
    suite: string = "browser_no_fixture" # Live browser suite to run.
    --plugin(-p): string = "target/debug/nu_plugin_nusurf" # Plugin binary path to load in child Nu processes.
    --fixture-binary(-f): string = "target/debug/nusurf_live_fixture_server" # Fixture server binary for suites that need one.
    --browser(-b): string # Explicit Chromium-compatible browser path or command name.
    --port: int # Remote debugging port to launch on; random by default.
    --max-time(-m): duration = 20sec # Maximum time to wait for browser startup.
    --verbose(-v) # Print child script stdout and stderr even when scripts succeed.
] {
    let repo_root = ($env.PWD | path expand)
    let plugin_path = ($plugin | path expand)
    let fixture_binary_path = ($fixture_binary | path expand)

    if (not ($plugin_path | path exists)) {
        error make {
            msg: $"Plugin binary was not found at ($plugin_path)"
        }
    }

    let chosen_port = ($port | default (random int 20000..60000))
    let scripts = (active-suite-scripts $suite)
    let script_count = ($scripts | length)
    let needs_fixture = ($scripts | any {|script| $script.needsFixture })

    if ($needs_fixture and (not ($fixture_binary_path | path exists))) {
        error make {
            msg: $"Fixture server binary was not found at ($fixture_binary_path)"
        }
    }

    let suite_started_at = (date now)

    if $script_count == 0 {
        print-table (suite-summary-record $suite 0 ((date now) - $suite_started_at) [] "ok") --expanded
        return
    }

    let browser_workflow = (
        cdp browser start --browser $browser --port $chosen_port --name $"runner-browser-($chosen_port)" --max-time (
            $max_time
        )
    )
    let fixture_server = (
        if $needs_fixture {
            start-fixture-server $fixture_binary_path
        } else {
            null
        }
    )

    mut run_results = []

    let suite_error = (
        try {
            for script in ($scripts | enumerate) {
            let index = $script.index + 1
            let script_record = $script.item
            let script_args = (
                if $script_record.needsFixture {
                    [($chosen_port | into string) ($fixture_server.port | into string)]
                } else {
                    [($chosen_port | into string)]
                }
            )
            let run_result = (
                if $verbose {
                    run-live-script $repo_root $plugin_path $script_record.path $script_args --verbose
                } else {
                    run-live-script $repo_root $plugin_path $script_record.path $script_args
                    }
                )

                if $run_result.exitCode != 0 {
                    $run_results = (
                        $run_results | append {
                            index: $index
                            status: "fail"
                            path: $script_record.path
                            fixture: $script_record.needsFixture
                            duration: $run_result.duration
                            exit_code: $run_result.exitCode
                        }
                    )
                    print-output-section "stdout" $run_result.stdout --stderr
                    print-output-section "stderr" $run_result.stderr --stderr
                    error make {
                        msg: $"Live browser script failed: ($script_record.path)"
                    }
                }

                $run_results = (
                    $run_results | append {
                        index: $index
                        status: "ok"
                        path: $script_record.path
                        fixture: $script_record.needsFixture
                        duration: $run_result.duration
                        exit_code: $run_result.exitCode
                    }
                )
            }

            let suite_duration = ((date now) - $suite_started_at)
            if $script_count > 1 {
                print-table (summarize-run-results $run_results)
            }
            print-table (suite-summary-record $suite $script_count $suite_duration $run_results "ok") --expanded
            null
        } catch {|err|
            $err
        }
    )

    stop-fixture-server $fixture_server
    cdp browser stop $browser_workflow

    if $suite_error != null {
        let suite_duration = ((date now) - $suite_started_at)

        if (($run_results | length) > 0) {
            print-table (summarize-run-results $run_results --failed) --stderr
        }
        print-table (suite-summary-record $suite $script_count $suite_duration $run_results "fail") --expanded --stderr
        error make $suite_error
    }
}
