use std/assert
use cdp.nu *
use cdp_live.nu *

def main [http_port: int, fixture_port: int] {
    cdp open (cdp discover $http_port) --name "browser-events" | ignore

    let page = (create-page "browser-events" $http_port "page-events")

    enable-page-basics $page.session
    cdp call $page.session "Network.enable" | ignore
    cdp call $page.session "Page.navigate" { url: "about:blank" } | ignore
    wait-for-load $page.session | ignore

    for _ in 0..20 {
        let pending = (cdp event $page.session --max-time 50ms)
        if (is nothing $pending) {
            break
        }
    }

    cdp call $page.session "Runtime.evaluate" {
        expression: "setTimeout(() => console.log('solo-event'), 50); true"
        returnByValue: true
    } | ignore

    let solo_event = (cdp event $page.session "Runtime.consoleAPICalled" --max-time 2sec)
    assert equal ($solo_event.params.args | get 0.value) "solo-event"

    let duplicate = (cdp event $page.session --max-time 250ms)
    assert nothing $duplicate "filtered events should not remain available via unfiltered reads"

    let ping_a = (fixture-url $fixture_port "event-a")
    let ping_b = (fixture-url $fixture_port "event-b")
    let storm_script = ([
        "(() => {"
        "    console.log('storm-begin')"
        (["    fetch('", $ping_a, "')"] | str join "")
        (["    setTimeout(() => fetch('", $ping_b, "'), 25)"] | str join "")
        "    setTimeout(() => console.log('storm-end'), 60)"
        "    return true"
        "})()"
    ] | str join "\n")

    cdp call $page.session "Runtime.evaluate" {
        expression: $storm_script
        returnByValue: true
    } | ignore

    let console_begin = (cdp event $page.session "Runtime.consoleAPICalled" --max-time 5sec)
    let request_a = (cdp event $page.session "Network.requestWillBeSent" --max-time 5sec)
    let request_b = (cdp event $page.session "Network.requestWillBeSent" --max-time 5sec)
    let console_end = (cdp event $page.session "Runtime.consoleAPICalled" --max-time 5sec)

    assert equal ($console_begin.params.args | get 0.value) "storm-begin"
    assert equal ($console_end.params.args | get 0.value) "storm-end"

    let request_urls = [$request_a.params.request.url $request_b.params.request.url] | str join "\n"
    assert str contains $request_urls "source=event-a"
    assert str contains $request_urls "source=event-b"

    mut drained_to_idle = false

    for _ in 0..20 {
        let next_event = (cdp event $page.session --max-time 100ms)
        if (is nothing $next_event) {
            $drained_to_idle = true
            break
        }
    }

    assert $drained_to_idle "event queue should drain to idle after the routed events are consumed"

    close-page "browser-events" $page.session $page.targetId
    cdp close "browser-events" | ignore
}
