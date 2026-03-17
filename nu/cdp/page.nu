use common.nu [random-id]
use session.nu [
    "cdp call"
    "cdp close"
    "cdp open"
]

def ws-session-record [session_name: string]: nothing -> oneof<record, error> {
    let session = (ws list | where id == $session_name | first)

    if $session == null {
        error make {
            msg: $"CDP websocket session ($session_name) is not open"
        }
    }

    $session
}

def browser-devtools-root [browser_session: string]: nothing -> oneof<string, error> {
    let browser_url = ((ws-session-record $browser_session) | get url)
    let parts = ($browser_url | split row "/devtools/browser/")

    if (($parts | length) != 2) {
        error make {
            msg: $"Session ($browser_session) is not a browser DevTools session"
        }
    }

    $parts | get 0
}

def page-target-id-from-url [ws_url: string]: nothing -> oneof<string, nothing> {
    let parts = ($ws_url | split row "/devtools/page/")

    if (($parts | length) == 2) {
        $parts | get 1 | str trim -c "/"
    }
}

def resolve-browser-context [browser?: any]: nothing -> oneof<record, error> {
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

def resolve-page-context [page?: any, browser?: any]: nothing -> oneof<record, error> {
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

def page-ws-url [browser_session: string, target_id: string]: nothing -> string {
    let root = (browser-devtools-root $browser_session)
    $"($root)/devtools/page/($target_id)"
}

const page_wait_states = [
    {
        value: "present"
        description: "Selector resolves to at least one element"
    }
    {
        value: "visible"
        description: "A matching element exists and is visible"
    }
    {
        value: "hidden"
        description: "Matching elements exist but none are visible"
    }
    {
        value: "gone"
        description: "No matching element remains"
    }
]

def js-literal [value: any]: nothing -> string {
    $value | default null | to json -r
}

def dom-helper-expression [
    selector: string
    text?: any
    action: string = "inspect"
    value?: any
] : nothing -> string {
    let selector_json = (js-literal $selector)
    let text_json = (js-literal $text)
    let action_json = (js-literal $action)
    let value_json = (js-literal $value)

    [
        "(function () {"
        $"  const selector = ($selector_json);"
        $"  const textNeedle = ($text_json);"
        $"  const action = ($action_json);"
        $"  const fillValue = ($value_json);"
        "  const hasText = textNeedle !== null;"
        "  const isVisible = (element) => {"
        "    const style = window.getComputedStyle(element);"
        "    if (style === null) {"
        "      return false;"
        "    }"
        "    if (style.display === 'none' || style.visibility === 'hidden') {"
        "      return false;"
        "    }"
        "    return element.getClientRects().length > 0;"
        "  };"
        "  const normalize = (element) => ({"
        "    selector,"
        "    tag: element.tagName.toLowerCase(),"
        "    id: element.id || null,"
        "    classes: Array.from(element.classList),"
        "    text: element.textContent ?? '',"
        "    value: 'value' in element ? element.value : null,"
        "    visible: isVisible(element),"
        "    disabled: !!element.disabled,"
        "    href: element.href ?? null,"
        "    html: element.outerHTML ?? null,"
        "  });"
        "  const records = [];"
        "  let firstRecord = null;"
        "  let firstVisibleRecord = null;"
        "  let visibleCount = 0;"
        "  for (const element of document.querySelectorAll(selector)) {"
        "    if (hasText && !(element.textContent ?? '').includes(textNeedle)) {"
        "      continue;"
        "    }"
        "    if (action === 'click') {"
        "      const record = normalize(element);"
        "      element.scrollIntoView({ block: 'center', inline: 'center' });"
        "      if (typeof element.focus === 'function') {"
        "        element.focus();"
        "      }"
        "      element.click();"
        "      return record;"
        "    }"
        "    if (action === 'fill') {"
        "      if ('value' in element) {"
        "        element.value = fillValue;"
        "      } else {"
        "        element.setAttribute('value', fillValue);"
        "      }"
        "      element.dispatchEvent(new Event('input', { bubbles: true }));"
        "      element.dispatchEvent(new Event('change', { bubbles: true }));"
        "      return normalize(element);"
        "    }"
        "    const record = normalize(element);"
        "    if (firstRecord === null) {"
        "      firstRecord = record;"
        "    }"
        "    if (record.visible) {"
        "      visibleCount += 1;"
        "      if (firstVisibleRecord === null) {"
        "        firstVisibleRecord = record;"
        "      }"
        "    }"
        "    records.push(record);"
        "  }"
        "  if (action !== 'inspect') {"
        "    return null;"
        "  }"
        "  return {"
        "    selector,"
        "    matches: records,"
        "    first: firstRecord,"
        "    firstVisible: firstVisibleRecord,"
        "    visibleCount,"
        "  };"
        "})()"
    ] | str join "\n"
}

def inspect-page-elements [
    selector: string
    --text: any
    --page(-p): any
    --max-time(-m): duration = 30sec
] : nothing -> any {
    cdp page eval (dom-helper-expression $selector $text) --page $page --max-time $max_time
}

def act-on-page-element [
    selector: string
    action: string
    --value: any
    --page(-p): any
    --max-time(-m): duration = 30sec
] : nothing -> any {
    cdp page eval (dom-helper-expression $selector null $action $value) --page $page --max-time $max_time
}

def run-page-action [
    selector: string
    action: string
    max_time: duration
    interval: duration
    --value: any
    --page(-p): any
] : nothing -> any {
    let deadline = (date now) + $max_time

    loop {
        let result = (
            act-on-page-element $selector $action --value $value --page $page --max-time $max_time
        )

        if $result != null {
            return $result
        }

        if ((date now) >= $deadline) {
            error make {
                msg: (selector-timeout-message $selector "present" $max_time)
            }
        }

        sleep $interval
    }
}

def state-is-valid [state: string]: nothing -> bool {
    $page_wait_states | any {|entry| $entry.value == $state }
}

def wait-state-match [inspection: record, state: string]: nothing -> record {
    let first = ($inspection | get -o first)
    let first_visible = ($inspection | get -o firstVisible)
    let visible_count = ($inspection | get -o visibleCount | default 0)

    match $state {
        "present" => {
            matched: ($first != null)
            value: $first
        }
        "visible" => {
            matched: ($first_visible != null)
            value: $first_visible
        }
        "hidden" => {
            matched: (($first != null) and ($visible_count == 0))
            value: $first
        }
        "gone" => {
            matched: ($first == null)
            value: null
        }
    }
}

def selector-timeout-message [
    selector: string
    state: string
    max_time: duration
    text?: any
] : nothing -> string {
    let text_suffix = if $text == null {
        ""
    } else {
        $" with text containing ($text | into string)"
    }

    $"Timed out waiting for selector ($selector) to become ($state) within ($max_time)($text_suffix)"
}

def wait-for-page-selector [
    selector: string
    state: string
    max_time: duration
    interval: duration
    --text: any
    --page(-p): any
] : nothing -> any {
    if (not (state-is-valid $state)) {
        error make {
            msg: $"Unsupported page wait state: ($state)"
        }
    }

    let deadline = (date now) + $max_time

    loop {
        let inspection = (inspect-page-elements $selector --text $text --page $page --max-time $max_time)
        let state_match = (wait-state-match $inspection $state)

        if $state_match.matched {
            return $state_match.value
        }

        if ((date now) >= $deadline) {
            error make {
                msg: (selector-timeout-message $selector $state $max_time $text)
            }
        }

        sleep $interval
    }
}

export def complete-cdp-page-wait-state [
    context: string
] : nothing -> record {
    let needle = ($context | split words | last | default "" | str downcase)

    {
        options: {
            completion_algorithm: substring
            sort: true
            case_sensitive: false
        }
        completions: (
            $page_wait_states
            | where {|state| ($state.value | str downcase | str contains $needle) }
        )
    }
}

# Set the current browser and/or page context for agent-friendly CDP commands.
export def --env "cdp use" [
    context?: any # Browser/page record or websocket session name to make current.
    --browser(-b): any # Explicit browser record or websocket session name to make current.
    --page(-p): any # Explicit page record or websocket session name to make current.
    --clear(-c) # Clear the current browser and page context.
] : nothing -> oneof<record, error> {
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
    --raw-buffer(-r): int = 128 # Number of raw websocket messages to retain for `ws recv`.
    --max-time(-m): duration = 30sec # Maximum time to wait for target creation and setup.
] : nothing -> oneof<record, error> {
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
] : nothing -> oneof<list<any>, error> {
    let browser_context = (resolve-browser-context $browser)
    let current_target_id = ($env | get -o CDP_PAGE | get -o targetId)
    let sessions = (ws list)
    let targets = (cdp call $browser_context.session "Target.getTargets" | get targetInfos)

    $targets
    | where type == "page"
    | each {|target|
        let ws_url = (page-ws-url $browser_context.session $target.targetId)
        let session_name = ($sessions | where url == $ws_url | get -o id | first)

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
] : nothing -> oneof<record, error> {
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
    --wait-for: string # CSS selector to wait for after the normal navigation wait.
    --wait-state: string@complete-cdp-page-wait-state = "present" # Selector wait state when using `--wait-for`.
    --wait-text: string # Optional text substring filter for selector waits.
    --interval(-i): duration = 100ms # Delay between selector wait attempts.
    --no-wait # Return after `Page.navigate` instead of waiting for `Page.loadEventFired`.
] : nothing -> oneof<record, error> {
    if (($no_wait == true) and ($wait_for != null)) {
        error make {
            msg: "`cdp page goto` cannot combine --no-wait with --wait-for"
        }
    }

    let page_context = (resolve-page-context $page)
    let navigation = (
        cdp call $page_context.session "Page.navigate" {
            url: $url
        } --max-time $max_time
    )

    if (not $no_wait) {
        cdp event $page_context.session "Page.loadEventFired" --max-time $max_time | ignore
    }

    if $wait_for != null {
        wait-for-page-selector $wait_for $wait_state $max_time $interval --text $wait_text --page $page_context
        | ignore
    }

    $navigation
}

# Wait for a page selector to reach a target state.
export def "cdp page wait" [
    selector: string # CSS selector to wait for.
    --state: string@complete-cdp-page-wait-state = "present" # Wait condition: present, visible, hidden, or gone.
    --text: string # Optional text substring that matching elements must contain.
    --max-time(-m): duration = 30sec # Maximum time to wait for the selector state.
    --interval(-i): duration = 100ms # Delay between selector checks.
    --page(-p): any # Page record or websocket session name; defaults to the current page.
] : nothing -> oneof<any, error> {
    wait-for-page-selector $selector $state $max_time $interval --text $text --page $page
}

# Query page elements and return the first match or all matches.
export def "cdp page query" [
    selector: string # CSS selector to inspect.
    --all # Return every match instead of only the first match.
    --page(-p): any # Page record or websocket session name; defaults to the current page.
    --max-time(-m): duration = 30sec # Maximum time to wait for the evaluation result.
] : nothing -> oneof<any, error> {
    let inspection = (inspect-page-elements $selector --page $page --max-time $max_time)

    if $all {
        $inspection | get matches
    } else {
        $inspection | get -o first
    }
}

# Click the first matching page element after it appears.
export def "cdp page click" [
    selector: string # CSS selector to click.
    --max-time(-m): duration = 30sec # Maximum time to wait for the element to appear.
    --interval(-i): duration = 100ms # Delay between selector checks.
    --page(-p): any # Page record or websocket session name; defaults to the current page.
] : nothing -> oneof<any, error> {
    run-page-action $selector "click" $max_time $interval --page $page
}

# Fill the first matching page element after it appears.
export def "cdp page fill" [
    selector: string # CSS selector to fill.
    value: string # New value to assign to the element.
    --max-time(-m): duration = 30sec # Maximum time to wait for the element to appear.
    --interval(-i): duration = 100ms # Delay between selector checks.
    --page(-p): any # Page record or websocket session name; defaults to the current page.
] : nothing -> oneof<any, error> {
    run-page-action $selector "fill" $max_time $interval --value $value --page $page
}

# Evaluate JavaScript in a page, defaulting to the current page context.
export def "cdp page eval" [
    expression: string # JavaScript expression to evaluate in the page.
    --page(-p): any # Page record or websocket session name; defaults to the current page.
    --await-promise(-a) = true # Await promise results before returning.
    --full(-f) # Return the full `Runtime.evaluate` result record.
    --max-time(-m): duration = 30sec # Maximum time to wait for the evaluation result.
] : nothing -> oneof<any, error> {
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
