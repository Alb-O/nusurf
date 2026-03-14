use std/assert
use cdp.nu *
use cdp_live.nu *

def main [http_port: int] {
    cdp open (cdp discover $http_port) --name "browser-e2e" | ignore

    let version = (cdp call "browser-e2e" "Browser.getVersion")
    assert (($version.product | str contains "Chrome"))

    let page = (create-page "browser-e2e" $http_port "page-e2e")

    enable-page-basics $page.session
    cdp call $page.session "Page.navigate" {
        url: "data:text/html,<title>nu-e2e</title><main id=\"app\">ok</main>"
    } | ignore

    wait-for-load $page.session | ignore

    let title = (
        cdp call $page.session "Runtime.evaluate" {
            expression: "document.title"
            returnByValue: true
        }
    )
    assert equal $title.result.value "nu-e2e"

    let html = (
        cdp call $page.session "Runtime.evaluate" {
            expression: "document.querySelector(`#app`).textContent"
            returnByValue: true
        }
    )
    assert equal $html.result.value "ok"

    let screenshot = (
        cdp call $page.session "Page.captureScreenshot" { format: "png" } --max-time 60sec
    )
    assert (($screenshot.data | str length) > 1000) "expected a non-trivial screenshot payload"

    close-page "browser-e2e" $page.session $page.targetId
    cdp close "browser-e2e" | ignore
}
