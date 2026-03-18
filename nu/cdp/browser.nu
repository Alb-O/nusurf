use common.nu *

def json-version-url []: any -> oneof<string, error> {
    let target = $in
    let target_type = ($target | describe)

    if $target_type == "int" {
        return $"http://127.0.0.1:($target)/json/version"
    }

    if $target_type == "string" {
        if ($target | str ends-with "/json/version") {
            return $target
        }

        if (($target | str starts-with "http://") or ($target | str starts-with "https://")) {
            let trimmed = ($target | str trim -r -c "/")
            return $"($trimmed)/json/version"
        }
    }

    error make {
        msg: $"Unsupported CDP discovery target type: ($target_type)"
    }
}

def http-ws-url [target: any]: nothing -> oneof<string, error> {
    ws-url-from-version-info $target (http get ($target | json-version-url))
}

def wait-for-ws-url [target: any, max_time: duration, interval: duration]: nothing -> any {
    let deadline = (date now) + $max_time

    loop {
        let ws_url = (
            try { resolve-ws-url $target }
        )

        if $ws_url != null {
            return $ws_url
        }

        if ((date now) >= $deadline) {
            error make {
                msg: (
                    $"Timed out waiting for a CDP target at ($target | into string). "
                    + "Launch a browser with remote debugging enabled or pass an existing DevTools URL."
                )
            }
        }

        sleep $interval
    }
}

def open-or-reuse-browser-session [name: string, ws_url: string, raw_buffer: int = 0]: nothing -> oneof<record, error> {
    let existing_session = (ws list | where id == $name | first)

    match $existing_session {
        null => (ws open $ws_url --name $name --raw-buffer $raw_buffer)
        {url: $url} if $url == $ws_url => $existing_session
        _ => {
            error make {
                msg: (
                    $"Session ($name) is already open for ($existing_session.url). "
                    + $"Close it first or use a different --name for ($ws_url)."
                )
            }
        }
    }
}

def focus-browser-context [browser_context: record]: nothing -> nothing {
    let current_page = $env.CDP_PAGE?
    let current_page_browser_session = $current_page.browserSession?

    $env.CDP_BROWSER = $browser_context

    if (
        ($current_page != null)
        and ($current_page_browser_session != $browser_context.session)
    ) {
        try { hide-env CDP_PAGE }
    }
}

# Resolve an HTTP discovery target, websocket URL, or version record to a CDP websocket URL.
export def resolve-ws-url [
    target: any # Browser port, discovery URL, websocket URL, or version record.
] : nothing -> oneof<string, error> {
    let target_type = ($target | describe)

    if $target_type == "int" {
        return (http-ws-url $target)
    }

    if $target_type == "string" {
        if (($target | str starts-with "ws://") or ($target | str starts-with "wss://")) {
            return $target
        }

        if (
            ($target | str starts-with "http://")
            or ($target | str starts-with "https://")
            or ($target | str ends-with "/json/version")
        ) {
            return (http-ws-url $target)
        }
    }

    if ($target_type | str starts-with "record") {
        return (ws-url-from-version-info $target $target)
    }

    error make {
        msg: $"Unsupported CDP target type: ($target_type)"
    }
}

def ws-url-from-version-info [target: any, info: record]: nothing -> oneof<string, error> {
    let ws_url = $info.webSocketDebuggerUrl?

    if $ws_url == null {
        error make { msg: $"No webSocketDebuggerUrl in ($target | into string)" }
    }

    $ws_url
}

def browser-env-candidate [name: string]: nothing -> oneof<path, nothing> {
    let raw = ($env | get -o $name)

    if $raw == null {
        return null
    }

    let raw_text = ($raw | into string | str trim)
    if ($raw_text | is-empty) {
        return null
    }

    [
        $raw_text
        (
            $raw_text
            | split row ":"
            | first
            | str trim
            | split words
            | first
        )
    ]
    | compact --empty
    | each {|candidate| $candidate | resolve-path-candidate }
    | compact
    | first
}

def chromium-browser-candidates []: nothing -> list<string> {
    let common_candidates = [
        "google-chrome"
        "google-chrome-stable"
        "chromium"
        "chromium-browser"
        "chrome"
        "brave-browser"
        "microsoft-edge"
        "microsoft-edge-stable"
        "vivaldi"
        "vivaldi-stable"
        "opera"
        "helium"
        "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
        "/Applications/Google Chrome Canary.app/Contents/MacOS/Google Chrome Canary"
        "/Applications/Chromium.app/Contents/MacOS/Chromium"
    ]
    let windows_candidates = (
        [
            ($env | get -o ProgramFiles)
            ($env | get -o 'ProgramFiles(x86)')
        ]
        | compact
        | each {|base|
            [
                $"($base)/Google/Chrome/Application/chrome.exe"
                $"($base)/Microsoft/Edge/Application/msedge.exe"
            ]
        }
        | flatten
    )

    [$common_candidates $windows_candidates] | flatten
}

def discover-browser-path []: nothing -> oneof<path, nothing> {
    let env_candidate = (browser-env-candidate "NU_CDP_BROWSER" | default { browser-env-candidate "BROWSER" })

    if $env_candidate != null {
        return $env_candidate
    }

    chromium-browser-candidates
    | each {|candidate| $candidate | resolve-path-candidate }
    | compact
    | first
}

# Resolve a CDP discovery target to its websocket URL.
export def discover [
    target: any # Browser port, discovery URL, websocket URL, or version record.
] : nothing -> oneof<string, error> {
    resolve-ws-url $target
}

# Find a Chromium-compatible browser executable.
export def find [
    --browser(-b): string # Explicit browser path or command name to resolve.
] : nothing -> oneof<path, error> {
    let path = if $browser == null {
        discover-browser-path
    } else {
        $browser | resolve-path-candidate
    }

    if $path == null {
        error make {
            msg: (
                "No Chromium-compatible browser was found. "
                + "Set NU_CDP_BROWSER or BROWSER, "
                + "or install a supported browser on PATH."
            )
        }
    }

    $path
}

# Wait for a browser target to expose a DevTools websocket URL.
export def wait [
    target: any = 9222 # Browser port, discovery URL, websocket URL, or version record.
    --max-time(-m): duration = 10sec # Maximum time to wait for the browser target.
    --interval(-i): duration = 100ms # Delay between discovery attempts.
] : nothing -> oneof<string, error> {
    wait-for-ws-url $target $max_time $interval
}

# Wait for a browser target and open a stable websocket session to it.
export def --env open [
    target: any = 9222 # Browser port, discovery URL, websocket URL, or version record.
    --name(-n): string = "browser" # Session name to register locally.
    --raw-buffer(-r): int = 128 # Number of raw websocket messages to retain for `ws recv`.
    --max-time(-m): duration = 10sec # Maximum time to wait for the browser target.
    --interval(-i): duration = 100ms # Delay between discovery attempts.
    --focus # Make the opened browser current via `cdp focus`.
] : nothing -> oneof<record, error> {
    let browser_session = (
        open-or-reuse-browser-session $name (wait-for-ws-url $target $max_time $interval) $raw_buffer
    )
    let browser_context = {
        session: $browser_session.id
        url: $browser_session.url
    }

    if $focus {
        focus-browser-context $browser_context
    }

    $browser_session
}

# Launch or attach to a browser and return a record agents can keep using.
export def --env start [
    --browser(-b): string # Explicit browser path or command name to launch.
    --port(-p): int = 9222 # Remote debugging port to attach on.
    --name(-n): string = "browser" # Session name to register locally.
    --raw-buffer(-r): int = 128 # Number of raw websocket messages to retain for `ws recv`.
    --headless(-h) = true # Launch Chromium headless by default.
    --user-data-dir(-u): path # Browser profile directory; a temp dir is used by default.
    --url: string = "about:blank" # Initial URL to open after launch.
    --job-tag(-t): string # Background job tag for the launched browser process.
    --max-time(-m): duration = 10sec # Maximum time to wait for the browser target.
    --interval(-i): duration = 100ms # Delay between discovery attempts.
    --focus # Make the opened browser current via `cdp focus`.
] : nothing -> oneof<record, error> {
    let existing_ws_url = (
        try { resolve-ws-url $port }
    )

    if $existing_ws_url != null {
        let session = (open-or-reuse-browser-session $name $existing_ws_url $raw_buffer)
        let browser_context = {
            launched: false
            session: $session.id
            url: $session.url
            port: $port
        }

        if $focus {
            focus-browser-context $browser_context
        }

        return $browser_context
    }

    let browser_path = (find --browser $browser)
    let profile_dir = if $user_data_dir == null {
        mktemp -d
    } else {
        $user_data_dir | path expand
    }
    let args = (
        args --port $port --headless=$headless --user-data-dir $profile_dir --url $url
    )
    let launch_tag = ($job_tag | default $"cdp-browser-($port)")
    let job_id = (
        job spawn --tag $launch_tag {
            run-external $browser_path ...$args | ignore
        }
    )
    let ws_url = (wait-for-ws-url $port $max_time $interval)
    let session = (open-or-reuse-browser-session $name $ws_url $raw_buffer)

    let browser_context = {
        launched: true
        browser: $browser_path
        session: $session.id
        url: $session.url
        port: $port
        jobId: $job_id
        jobTag: $launch_tag
        userDataDir: $profile_dir
    }

    if $focus {
        focus-browser-context $browser_context
    }

    $browser_context
}

# Close a started browser workflow record and clean up its local session state.
export def stop [
    browser?: any # Record returned by `cdp browser start`, or a session name.
    --session(-s): string # Explicit session name to close.
    --job-id(-j): int # Background job id to kill.
    --user-data-dir(-u): path # Profile directory to remove.
] : nothing -> nothing {
    let session_name = if $session != null {
        $session
    } else {
        match $browser {
            {session: $browser_session} => $browser_session
            $browser_text if (($browser_text | describe) == "string") => $browser_text
            _ => "browser"
        }
    }
    let job_to_kill = if $job_id != null {
        $job_id
    } else {
        match $browser {
            {jobId: $browser_job_id} => $browser_job_id
            _ => null
        }
    }
    let profile_dir = if $user_data_dir != null {
        $user_data_dir
    } else {
        match $browser {
            {userDataDir: $browser_user_data_dir} => $browser_user_data_dir
            _ => null
        }
    }

    if $session_name != null {
        let request_id = (random-id)
        {
            id: $request_id
            method: "Browser.close"
        } | ws send-json $session_name

        try { ws await $session_name $request_id --max-time 5sec | ignore }

        try { ws close $session_name | ignore }
    }

    if $job_to_kill != null {
        try { job kill $job_to_kill }
    }

    if (($profile_dir != null) and (($profile_dir | path exists))) {
        rm -rf $profile_dir
    }
}

# Build Chromium launch args with remote debugging enabled.
export def args [
    --port(-p): int = 9222 # Remote debugging port to expose.
    --headless(-h) # Launch Chromium in headless mode.
    --user-data-dir(-u): path # Browser profile directory to use.
    --url: string # Initial URL to open after launch.
] : nothing -> list<string> {
    [
        $"--remote-debugging-port=($port)"
        "--remote-allow-origins=*"
        "--no-first-run"
        "--no-default-browser-check"
        "--disable-background-networking"
        "--disable-backgrounding-occluded-windows"
        "--disable-component-update"
        "--disable-default-apps"
        "--disable-hang-monitor"
        "--disable-popup-blocking"
        "--disable-prompt-on-repost"
        "--disable-sync"
        "--disable-blink-features=AutomationControlled" # otherwise can trigger anti-bot
        "--disable-features=Translate"
        "--enable-features=NetworkService,NetworkServiceInProcess"
        "--metrics-recording-only"
        "--password-store=basic"
        "--use-mock-keychain"
        (if $headless { "--headless=new" })
        (if $user_data_dir != null { $"--user-data-dir=($user_data_dir)" })
        (if $url != null { $url })
    ] | compact
}
