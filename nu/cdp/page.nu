use common.nu [random-id]
use session.nu [
    "cdp call"
    "cdp close"
    "cdp open"
]

def ws-session-record [session_name: string] {
    let session = (ws list | where id == $session_name | get -o 0)

    if $session == null {
        error make {
            msg: $"CDP websocket session ($session_name) is not open"
        }
    }

    $session
}

def browser-devtools-root [browser_session: string] {
    let browser_url = ((ws-session-record $browser_session) | get url)
    let parts = ($browser_url | split row "/devtools/browser/")

    if (($parts | length) != 2) {
        error make {
            msg: $"Session ($browser_session) is not a browser DevTools session"
        }
    }

    $parts | get 0
}

def page-target-id-from-url [ws_url: string] {
    let parts = ($ws_url | split row "/devtools/page/")

    if (($parts | length) != 2) {
        null
    } else {
        $parts | get 1 | str trim -c "/"
    }
}

def resolve-browser-context [browser?: any] {
    let source = (
        [
            $browser
            ($env | get -o CDP_BROWSER)
            ($env | get -o CDP_PAGE | get -o browserSession)
        ]
        | compact
        | first
    )

    if $source == null {
        error make {
            msg: "No current browser is selected. Pass --browser or run `cdp use <browser>` first."
        }
    }

    let source_type = ($source | describe)
    let session_name = match $source_type {
        "string" => $source
        $record_type if ($record_type | str starts-with "record") => {
            $source
            | get -o session id
            | compact
            | first
        }
        _ => null
    }

    if $session_name == null {
        error make {
            msg: $"Unsupported browser context type: ($source_type)"
        }
    }

    let session = (ws-session-record $session_name)

    {
        session: $session.id
        url: $session.url
    }
}

def resolve-page-context [page?: any, browser?: any] {
    let source = (
        [
            $page
            ($env | get -o CDP_PAGE)
        ]
        | compact
        | first
    )

    if $source == null {
        error make {
            msg: "No current page is selected. Pass --page or run `cdp use <page>` first."
        }
    }

    let source_type = ($source | describe)
    let session_name = match $source_type {
        "string" => $source
        $record_type if ($record_type | str starts-with "record") => {
            $source
            | get -o session id
            | compact
            | first
        }
        _ => null
    }

    if $session_name == null {
        error make {
            msg: $"Unsupported page context type: ($source_type)"
        }
    }

    let session = (ws-session-record $session_name)
    let target_id = (
        [
            (
                if ($source_type | str starts-with "record") {
                    $source | get -o targetId
                }
            )
            (page-target-id-from-url $session.url)
        ]
        | compact
        | first
    )
    let browser_session = (
        [
            (
                if ($source_type | str starts-with "record") {
                    $source | get -o browserSession
                }
            )
            (
                if $browser != null {
                    (resolve-browser-context $browser).session
                }
            )
            ($env | get -o CDP_BROWSER | get -o session)
        ]
        | compact
        | first
    )

    if $target_id == null {
        error make {
            msg: $"Unsupported page context type: ($source_type)"
        }
    }

    {
        browserSession: $browser_session
        session: $session.id
        targetId: $target_id
        webSocketDebuggerUrl: $session.url
    }
}

def page-ws-url [browser_session: string, target_id: string] {
    let root = (browser-devtools-root $browser_session)
    $"($root)/devtools/page/($target_id)"
}

# Set the current browser and/or page context for agent-friendly CDP commands.
export def --env "cdp use" [
    context?: any # Browser/page record or websocket session name to make current.
    --browser(-b): any # Explicit browser record or websocket session name to make current.
    --page(-p): any # Explicit page record or websocket session name to make current.
    --clear(-c) # Clear the current browser and page context.
] {
    if $clear {
        try { hide-env CDP_BROWSER }
        try { hide-env CDP_PAGE }

        return {
            browser: null
            page: null
        }
    }

    let current_page = ($env | get -o CDP_PAGE)
    let current_page_browser_session = ($current_page | get -o browserSession)
    let page_context = (
        [
            (
                if $page != null {
                    resolve-page-context $page $browser
                }
            )
            (
                if (($page == null) and ($context != null)) {
                    try { resolve-page-context $context $browser }
                }
            )
        ]
        | compact
        | first
    )
    let browser_context = (
        [
            (
                if $browser != null {
                    resolve-browser-context $browser
                }
            )
            (
                if (($page_context != null) and ($page_context.browserSession != null)) {
                    resolve-browser-context $page_context.browserSession
                }
            )
            (
                if (($browser == null) and ($page == null) and ($context != null)) {
                    try { resolve-browser-context $context }
                }
            )
        ]
        | compact
        | first
    )

    if (($browser_context == null) and ($page_context == null)) {
        error make {
            msg: "No CDP browser or page context could be resolved"
        }
    }

    if $browser_context != null {
        $env.CDP_BROWSER = $browser_context
    }

    if $page_context != null {
        $env.CDP_PAGE = $page_context
    } else if (
        (($context != null) or ($browser != null))
        and (
            ($current_page == null)
            or ($browser_context == null)
            or ($current_page_browser_session != $browser_context.session)
        )
    ) {
        try { hide-env CDP_PAGE }
    }

    {
        browser: ($env | get -o CDP_BROWSER)
        page: ($env | get -o CDP_PAGE)
    }
}

# Create a page target, open a websocket session to it, and enable the common CDP domains.
export def "cdp page new" [
    --browser(-b): any # Browser record or websocket session name; defaults to the current browser.
    --name(-n): string # Page websocket session name to register locally.
    --url(-u): string = "about:blank" # Initial URL to open in the new page target.
    --raw-buffer(-r): int = 0 # Number of raw websocket messages to retain for `ws recv`.
    --max-time(-m): duration = 30sec # Maximum time to wait for target creation and setup.
] {
    let browser_context = (resolve-browser-context $browser)
    let target = (
        cdp call $browser_context.session "Target.createTarget" {
            url: $url
        } --max-time $max_time
    )
    let page_session_name = ($name | default $"page-((random-id))")
    let page_session = (
        cdp open (page-ws-url $browser_context.session $target.targetId) --name $page_session_name --raw-buffer (
            $raw_buffer
        )
    )

    cdp call $page_session.id "Page.enable" --max-time $max_time | ignore
    cdp call $page_session.id "Runtime.enable" --max-time $max_time | ignore

    {
        browserSession: $browser_context.session
        session: $page_session.id
        targetId: $target.targetId
        webSocketDebuggerUrl: $page_session.url
    }
}

# List the current browser's page targets, including any matching local page session names.
export def "cdp page list" [
    --browser(-b): any # Browser record or websocket session name; defaults to the current browser.
] {
    let browser_context = (resolve-browser-context $browser)
    let current_target_id = ($env | get -o CDP_PAGE | get -o targetId)
    let sessions = (ws list)
    let targets = (cdp call $browser_context.session "Target.getTargets" | get targetInfos)

    $targets
    | where type == "page"
    | each {|target|
        let ws_url = (page-ws-url $browser_context.session $target.targetId)
        let session_name = ($sessions | where url == $ws_url | get -o 0.id)

        $target | merge {
            browserSession: $browser_context.session
            session: $session_name
            webSocketDebuggerUrl: $ws_url
            current: ($target.targetId == $current_target_id)
        }
    }
}

# Close a page target and its websocket session, defaulting to the current page context.
export def --env "cdp page close" [
    --page(-p): any # Page record or websocket session name; defaults to the current page.
    --browser(-b): any # Browser record or websocket session name; defaults to the current browser.
    --max-time(-m): duration = 30sec # Maximum time to wait for the target close command.
] {
    let page_context = (resolve-page-context $page $browser)

    if $page_context.targetId == null {
        error make {
            msg: "A page target id is required to close a page"
        }
    }

    if $page_context.browserSession == null {
        error make {
            msg: "A browser session is required to close a page"
        }
    }

    cdp call $page_context.browserSession "Target.closeTarget" {
        targetId: $page_context.targetId
    } --max-time $max_time | ignore

    try { cdp close $page_context.session | ignore }

    if (($env | get -o CDP_PAGE | get -o session) == $page_context.session) {
        try { hide-env CDP_PAGE }
    }

    $page_context
}

# Navigate a page to a URL, defaulting to the current page context.
export def "cdp page goto" [
    url: string # URL to navigate the page to.
    --page(-p): any # Page record or websocket session name; defaults to the current page.
    --max-time(-m): duration = 30sec # Maximum time to wait for navigation and load.
    --no-wait # Return after `Page.navigate` instead of waiting for `Page.loadEventFired`.
] {
    let page_context = (resolve-page-context $page)
    let navigation = (
        cdp call $page_context.session "Page.navigate" {
            url: $url
        } --max-time $max_time
    )

    if (not $no_wait) {
        cdp event $page_context.session "Page.loadEventFired" --max-time $max_time | ignore
    }

    $navigation
}

# Evaluate JavaScript in a page, defaulting to the current page context.
export def "cdp page eval" [
    expression: string # JavaScript expression to evaluate in the page.
    --page(-p): any # Page record or websocket session name; defaults to the current page.
    --await-promise(-a) = true # Await promise results before returning.
    --full(-f) # Return the full `Runtime.evaluate` result record.
    --max-time(-m): duration = 30sec # Maximum time to wait for the evaluation result.
] {
    let page_context = (resolve-page-context $page)
    let evaluation = (
        cdp call $page_context.session "Runtime.evaluate" {
            expression: $expression
            returnByValue: (not $full)
            awaitPromise: $await_promise
        } --max-time $max_time
    )
    let exception = ($evaluation | get -o exceptionDetails)

    if $exception != null {
        error make {
            msg: $"Page evaluation failed: ($exception.text | default $exception)"
        }
    }

    if $full {
        $evaluation
    } else {
        $evaluation | get -o result.value
    }
}
