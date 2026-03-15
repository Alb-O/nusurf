use common.nu *

def json-version-url [target: any] {
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

def http-ws-url [target: any] {
    ws-url-from-version-info $target (http get (json-version-url $target))
}

def wait-for-ws-url [target: any, max_time: duration, interval: duration] {
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

def open-or-reuse-browser-session [name: string, ws_url: string, raw_buffer: int = 0] {
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

# Resolve an HTTP discovery target, websocket URL, or version record to a CDP websocket URL.
export def resolve-ws-url [
    target: any # Browser port, discovery URL, websocket URL, or version record.
] {
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

def ws-url-from-version-info [target: any, info: record] {
    let ws_url = ($info | get -o webSocketDebuggerUrl)

    if $ws_url == null {
        error make { msg: $"No webSocketDebuggerUrl in ($target | into string)" }
    }

    $ws_url
}

def browser-env-candidate [name: string] {
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
    | each {|candidate| resolve-path-candidate $candidate }
    | compact
    | first
}

def chromium-browser-candidates [] {
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

def discover-browser-path [] {
    let env_candidate = (
        [
            (browser-env-candidate "NU_CDP_BROWSER")
            (browser-env-candidate "BROWSER")
        ]
        | compact
        | first
    )

    if $env_candidate != null {
        return $env_candidate
    }

    chromium-browser-candidates
    | each {|candidate| resolve-path-candidate $candidate }
    | compact
    | first
}

# Resolve a CDP discovery target to its websocket URL.
export def "cdp discover" [
    target: any # Browser port, discovery URL, websocket URL, or version record.
] {
    resolve-ws-url $target
}

# Find a Chromium-compatible browser executable.
export def "cdp browser find" [
    --browser(-b): string # Explicit browser path or command name to resolve.
] {
    let path = if $browser == null {
        discover-browser-path
    } else {
        resolve-path-candidate $browser
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
export def "cdp browser wait" [
    target: any = 9222 # Browser port, discovery URL, websocket URL, or version record.
    --max-time(-m): duration = 10sec # Maximum time to wait for the browser target.
    --interval(-i): duration = 100ms # Delay between discovery attempts.
] {
    wait-for-ws-url $target $max_time $interval
}

# Wait for a browser target and open a stable websocket session to it.
export def "cdp browser open" [
    target: any = 9222 # Browser port, discovery URL, websocket URL, or version record.
    --name(-n): string = "browser" # Session name to register locally.
    --raw-buffer(-r): int = 128 # Number of raw websocket messages to retain for `ws recv`.
    --max-time(-m): duration = 10sec # Maximum time to wait for the browser target.
    --interval(-i): duration = 100ms # Delay between discovery attempts.
] {
    open-or-reuse-browser-session $name (wait-for-ws-url $target $max_time $interval) $raw_buffer
}

# Launch or attach to a browser and return a record agents can keep using.
export def "cdp browser start" [
    --browser(-b): string # Explicit browser path or command name to launch.
    --port(-p): int = 9222 # Remote debugging port to attach on.
    --name(-n): string = "browser" # Session name to register locally.
    --raw-buffer(-r): int = 128 # Number of raw websocket messages to retain for `ws recv`.
    --headless(-h) = true # Launch Chromium headless by default.
    --user-data-dir(-u): string # Browser profile directory; a temp dir is used by default.
    --url: string = "about:blank" # Initial URL to open after launch.
    --job-tag(-t): string # Background job tag for the launched browser process.
    --max-time(-m): duration = 10sec # Maximum time to wait for the browser target.
    --interval(-i): duration = 100ms # Delay between discovery attempts.
] {
    let existing_ws_url = (
        try { resolve-ws-url $port }
    )

    if $existing_ws_url != null {
        let session = (open-or-reuse-browser-session $name $existing_ws_url $raw_buffer)

        return {
            launched: false
            session: $session.id
            url: $session.url
            port: $port
        }
    }

    let browser_path = (cdp browser find --browser $browser)
    let profile_dir = if $user_data_dir == null {
        mktemp -d
    } else {
        $user_data_dir | path expand
    }
    let args = (
        cdp browser args --port $port --headless=$headless --user-data-dir $profile_dir --url $url
    )
    let launch_tag = ($job_tag | default $"cdp-browser-($port)")
    let job_id = (
        job spawn --tag $launch_tag {
            run-external $browser_path ...$args | ignore
        }
    )
    let ws_url = (wait-for-ws-url $port $max_time $interval)
    let session = (open-or-reuse-browser-session $name $ws_url $raw_buffer)

    {
        launched: true
        browser: $browser_path
        session: $session.id
        url: $session.url
        port: $port
        jobId: $job_id
        jobTag: $launch_tag
        userDataDir: $profile_dir
    }
}

# Close a started browser workflow record and clean up its local session state.
export def "cdp browser stop" [
    browser?: any # Record returned by `cdp browser start`, or a session name.
    --session(-s): string # Explicit session name to close.
    --job-id(-j): int # Background job id to kill.
    --user-data-dir(-u): string # Profile directory to remove.
] {
    let browser_record = match ($browser | describe) {
        $kind if ($kind | str starts-with "record") => $browser
        _ => null
    }
    let session_name = (
        [
            $session
            ($browser_record | get -o session)
            (if (($browser_record == null) and ($browser != null)) {
                $browser | into string
            })
            "browser"
        ]
        | compact
        | first
    )
    let job_to_kill = (
        [
            $job_id
            ($browser_record | get -o jobId)
        ]
        | compact
        | first
    )
    let profile_dir = (
        [
            $user_data_dir
            ($browser_record | get -o userDataDir)
        ]
        | compact
        | first
    )

    if $session_name != null {
        try { cdp call $session_name "Browser.close" | ignore }

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
export def "cdp browser args" [
    --port(-p): int = 9222 # Remote debugging port to expose.
    --headless(-h) # Launch Chromium in headless mode.
    --user-data-dir(-u): string # Browser profile directory to use.
    --url: string # Initial URL to open after launch.
] {
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
