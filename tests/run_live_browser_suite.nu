use ../nu/cdp.nu *

const live_browser_suites_file = (path self live_browser_suites.nuon)

def run-live-script [repo_root: string, plugin_path: string, script_path: string, script_args: list<string>] {
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
        | str join (char --integer 30)
    )
    let result = (
        ^nu --no-config-file -I $include_paths --plugins $plugin_path -- $child_script_path ...$script_args
        | complete
    )

    if $result.exit_code != 0 {
        error make {
            msg: (
                $"Live browser script failed: ($script_path)\n"
                + $"stdout:\n($result.stdout)\n"
                + $"stderr:\n($result.stderr)"
            )
        }
    }
}

def suite-scripts [suite: string] {
    let suites = (open $live_browser_suites_file)
    let scripts = ($suites | get -o $suite)

    if $scripts == null {
        error make {
            msg: $"Unknown live browser suite: ($suite)"
        }
    }

    $scripts
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

def main [
    suite: string = "browser-no-fixture" # Live browser suite to run.
    --plugin(-p): string = "target/debug/nu_plugin_ws" # Plugin binary path to load in child Nu processes.
    --fixture-binary(-f): string = "target/debug/nu_ws_live_fixture_server" # Fixture server binary for suites that need one.
    --browser(-b): string # Explicit Chromium-compatible browser path or command name.
    --port: int # Remote debugging port to launch on; random by default.
    --max-time(-m): duration = 20sec # Maximum time to wait for browser startup.
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
    let scripts = (suite-scripts $suite)
    let needs_fixture = ($scripts | any {|script| $script.needsFixture })

    if ($needs_fixture and (not ($fixture_binary_path | path exists))) {
        error make {
            msg: $"Fixture server binary was not found at ($fixture_binary_path)"
        }
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

    try {
        for script in $scripts {
            print $"==> ($script.path)"
            let script_args = (
                if $script.needsFixture {
                    [$chosen_port ($fixture_server.port | into string)]
                } else {
                    [$chosen_port]
                }
            )
            run-live-script $repo_root $plugin_path $script.path $script_args
        }
    } finally {
        stop-fixture-server $fixture_server
        cdp browser stop $browser_workflow
    }
}
