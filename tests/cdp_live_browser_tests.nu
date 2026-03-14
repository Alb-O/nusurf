use std/assert
use cdp.nu *

def main [http_port: int] {
    let browser_ws = (cdp discover $http_port)
    assert (($browser_ws | str starts-with "ws://"))

    let browser = (cdp open $browser_ws --name "browser-e2e")
    assert equal $browser.id "browser-e2e"

    let version = (cdp call "browser-e2e" "Browser.getVersion")
    assert (($version.product | str contains "Chrome"))

    cdp close "browser-e2e" | ignore

    let page_ws = (
        http get $"http://127.0.0.1:($http_port)/json/list"
        | where type == "page"
        | get 0.webSocketDebuggerUrl
    )

    let page = (cdp open $page_ws --name "page-e2e")
    assert equal $page.id "page-e2e"

    cdp call "page-e2e" "Page.enable" | ignore
    cdp call "page-e2e" "Runtime.enable" | ignore
    cdp call "page-e2e" "Page.navigate" {
        url: "data:text/html,<title>nu-e2e</title><main id=\"app\">ok</main>"
    } | ignore

    let load = (cdp event "page-e2e" "Page.loadEventFired" --max-time 5sec)
    assert (($load | describe) != "nothing")

    let title = (
        cdp call "page-e2e" "Runtime.evaluate" {
            expression: "document.title"
            returnByValue: true
        }
    )
    assert equal $title.result.value "nu-e2e"

    let html = (
        cdp call "page-e2e" "Runtime.evaluate" {
            expression: "document.querySelector(`#app`).textContent"
            returnByValue: true
        }
    )
    assert equal $html.result.value "ok"

    cdp close "page-e2e" | ignore
}
