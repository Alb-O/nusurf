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

export def resolve-ws-url [target: any] {
    let target_type = ($target | describe)

    if $target_type == "int" {
        let info = (http get (json-version-url $target))
        let ws_url = ($info | get -o webSocketDebuggerUrl)

        if (is-nothing $ws_url) {
            error make { msg: $"No webSocketDebuggerUrl in ($target | into string)" }
        }

        return $ws_url
    }

    if $target_type == "string" {
        if (($target | str starts-with "ws://") or ($target | str starts-with "wss://")) {
            return $target
        }

        if (($target | str starts-with "http://") or ($target | str starts-with "https://") or ($target | str ends-with "/json/version")) {
            let info = (http get (json-version-url $target))
            let ws_url = ($info | get -o webSocketDebuggerUrl)

            if (is-nothing $ws_url) {
                error make { msg: $"No webSocketDebuggerUrl in ($target)" }
            }

            return $ws_url
        }
    }

    if ($target_type | str starts-with "record") {
        let ws_url = ($target | get -o webSocketDebuggerUrl)

        if (is-nothing $ws_url) {
            error make { msg: "Expected record with webSocketDebuggerUrl" }
        }

        return $ws_url
    }

    error make {
        msg: $"Unsupported CDP target type: ($target_type)"
    }
}

def browser-env-candidate [name: string] {
    let raw = ($env | get -o $name)

    if (is-nothing $raw) {
        return null
    }

    let raw_text = ($raw | into string | str trim)
    let direct = (resolve-path-candidate $raw_text)

    if (not (is-nothing $direct)) {
        return $direct
    }

    let first = (
        $raw_text
        | split row ":"
        | get -o 0
        | str trim
        | split row " "
        | get -o 0
    )

    if (is-nothing $first) {
        null
    } else {
        resolve-path-candidate $first
    }
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
        if (not (is-nothing $base)) {
            $candidates = ($candidates | append $"($base)/Google/Chrome/Application/chrome.exe")
            $candidates = ($candidates | append $"($base)/Microsoft/Edge/Application/msedge.exe")
        }
    }

    $candidates
}

def discover-browser-path [] {
    for candidate in [
        (browser-env-candidate "NU_CDP_BROWSER")
        (browser-env-candidate "BROWSER")
    ] {
        if (not (is-nothing $candidate)) {
            return $candidate
        }
    }

    for candidate in (chromium-browser-candidates) {
        let path = (resolve-path-candidate $candidate)
        if (not (is-nothing $path)) {
            return $path
        }
    }

    null
}

export def "cdp discover" [target: any] {
    resolve-ws-url $target
}

export def "cdp browser find" [
    --browser(-b): string
] {
    let path = if (is-nothing $browser) {
        discover-browser-path
    } else {
        resolve-path-candidate $browser
    }

    if (is-nothing $path) {
        error make {
            msg: "No Chromium-compatible browser was found. Set NU_CDP_BROWSER or BROWSER, or install a supported browser on PATH."
        }
    }

    $path
}

export def "cdp browser args" [
    --port(-p): int = 9222
    --headless(-h)
    --user-data-dir(-u): string
    --url: string
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
        "--disable-blink-features=AutomationControlled" # Otherwise can trigger bot detection
        "--disable-features=Translate"
        "--enable-features=NetworkService,NetworkServiceInProcess"
        "--metrics-recording-only"
        "--password-store=basic"
        "--use-mock-keychain"
    ]

    if $headless {
        $args = ($args | append "--headless=new")
    }

    if (not (is-nothing $user_data_dir)) {
        $args = ($args | append $"--user-data-dir=($user_data_dir)")
    }

    if (not (is-nothing $url)) {
        $args = ($args | append $url)
    }

    $args
}
