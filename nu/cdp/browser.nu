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

def ws-url-from-version-info [target: any, info: record] {
    let ws_url = ($info | get -o webSocketDebuggerUrl)

    if $ws_url == null {
        error make { msg: $"No webSocketDebuggerUrl in ($target | into string)" }
    }

    $ws_url
}

def http-ws-url [target: any] {
    ws-url-from-version-info $target (http get (json-version-url $target))
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
            | get -o 0
            | str trim
            | split words
            | get -o 0
        )
    ]
    | compact --empty
    | each {|candidate| resolve-path-candidate $candidate }
    | compact
    | first
}

def chromium-browser-candidates [] {
    mut candidates = [
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

    for base in [
        ($env | get -o ProgramFiles)
        ($env | get -o 'ProgramFiles(x86)')
    ] {
        if $base != null {
            $candidates = ($candidates | append $"($base)/Google/Chrome/Application/chrome.exe")
            $candidates = ($candidates | append $"($base)/Microsoft/Edge/Application/msedge.exe")
        }
    }

    $candidates
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

# Build Chromium launch args with remote debugging enabled.
export def "cdp browser args" [
    --port(-p): int = 9222 # Remote debugging port to expose.
    --headless(-h) # Launch Chromium in headless mode.
    --user-data-dir(-u): string # Browser profile directory to use.
    --url: string # Initial URL to open after launch.
] {
    mut args = [
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
    ]

    if $headless {
        $args = ($args | append "--headless=new")
    }

    if $user_data_dir != null {
        $args = ($args | append $"--user-data-dir=($user_data_dir)")
    }

    if $url != null {
        $args = ($args | append $url)
    }

    $args
}
