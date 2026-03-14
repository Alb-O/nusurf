use std/assert
use cdp.nu *
use cdp_live.nu *

def main [http_port: int, fixture_port: int] {
    cdp open (cdp discover $http_port) --name "browser-attached" | ignore

    let page_a = (create-attached-page "browser-attached" "attached-a")
    let page_b = (create-attached-page "browser-attached" "attached-b")

    for attached in [$page_a.attachedSessionId $page_b.attachedSessionId] {
        cdp call "browser-attached" "Page.enable" --session-id $attached | ignore
        cdp call "browser-attached" "Runtime.enable" --session-id $attached | ignore
        cdp call "browser-attached" "Network.enable" --session-id $attached | ignore
        cdp call "browser-attached" "Page.navigate" { url: "about:blank" } --session-id $attached | ignore
        let load = (cdp event "browser-attached" "Page.loadEventFired" --session-id $attached --max-time 5sec)
        assert some $load $"Timed out waiting for attached load event on ($attached)"
        drain-events "browser-attached" --max-time 25ms
    }

    let ping_a = (fixture-url $fixture_port "attached-a")
    let ping_b = (fixture-url $fixture_port "attached-b")
    let script_a = ([
        "(() => {"
        "    document.title = 'attached-a'"
        "    document.body.innerHTML = '<main id=\"app\">boot-a</main>'"
        "    setTimeout(() => {"
        "        document.querySelector('#app').textContent = 'ready-a'"
        "        console.log('attached-console-a')"
        (["        fetch('", $ping_a, "')"] | str join "")
        "    }, 25)"
        "    return true"
        "})()"
    ] | str join "\n")
    let script_b = ([
        "(() => {"
        "    document.title = 'attached-b'"
        "    document.body.innerHTML = '<main id=\"app\">boot-b</main>'"
        "    setTimeout(() => {"
        "        document.querySelector('#app').textContent = 'ready-b'"
        "        console.log('attached-console-b')"
        (["        fetch('", $ping_b, "')"] | str join "")
        "    }, 10)"
        "    return true"
        "})()"
    ] | str join "\n")

    cdp call "browser-attached" "Runtime.evaluate" {
        expression: $script_a
        returnByValue: true
    } --session-id $page_a.attachedSessionId | ignore

    cdp call "browser-attached" "Runtime.evaluate" {
        expression: $script_b
        returnByValue: true
    } --session-id $page_b.attachedSessionId | ignore

    let console_a = (cdp event "browser-attached" "Runtime.consoleAPICalled" --session-id $page_a.attachedSessionId --max-time 5sec)
    let console_b = (cdp event "browser-attached" "Runtime.consoleAPICalled" --session-id $page_b.attachedSessionId --max-time 5sec)
    let request_a = (cdp event "browser-attached" "Network.requestWillBeSent" --session-id $page_a.attachedSessionId --max-time 5sec)
    let request_b = (cdp event "browser-attached" "Network.requestWillBeSent" --session-id $page_b.attachedSessionId --max-time 5sec)
    let failed_a = (cdp event "browser-attached" "Network.loadingFailed" --session-id $page_a.attachedSessionId --max-time 5sec)
    let failed_b = (cdp event "browser-attached" "Network.loadingFailed" --session-id $page_b.attachedSessionId --max-time 5sec)

    assert equal ($console_a.params.args | get 0.value) "attached-console-a"
    assert equal ($console_b.params.args | get 0.value) "attached-console-b"
    assert str contains $request_a.params.request.url "source=attached-a"
    assert str contains $request_b.params.request.url "source=attached-b"
    assert equal $failed_a.params.errorText "net::ERR_FAILED"
    assert equal $failed_b.params.errorText "net::ERR_FAILED"

    let state_a = (
        cdp call "browser-attached" "Runtime.evaluate" {
            expression: "new Promise(resolve => setTimeout(() => resolve({ title: document.title, text: document.querySelector(`#app`).textContent }), 200))"
            awaitPromise: true
            returnByValue: true
        } --session-id $page_a.attachedSessionId
    )
    let state_b = (
        cdp call "browser-attached" "Runtime.evaluate" {
            expression: "new Promise(resolve => setTimeout(() => resolve({ title: document.title, text: document.querySelector(`#app`).textContent }), 200))"
            awaitPromise: true
            returnByValue: true
        } --session-id $page_b.attachedSessionId
    )

    assert equal $state_a.result.value.title "attached-a"
    assert equal $state_a.result.value.text "ready-a"
    assert equal $state_b.result.value.title "attached-b"
    assert equal $state_b.result.value.text "ready-b"

    let metrics_a = (
        cdp call "browser-attached" "Page.getLayoutMetrics" {} --session-id $page_a.attachedSessionId
    )
    let pdf_b = (
        cdp call "browser-attached" "Page.printToPDF" {
            printBackground: true
            paperWidth: 8.27
            paperHeight: 11.69
        } --session-id $page_b.attachedSessionId --max-time 60sec
    )

    assert ($metrics_a.cssContentSize.width > 0) "expected attached-session layout metrics"
    assert (($pdf_b.data | str length) > 1000) "expected attached-session PDF payload"

    close-attached-page "browser-attached" $page_a.attachedSessionId $page_a.targetId
    close-attached-page "browser-attached" $page_b.attachedSessionId $page_b.targetId
    cdp close "browser-attached" | ignore
}
