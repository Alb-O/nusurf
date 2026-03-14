use std/assert
use cdp.nu *
use cdp_live.nu *

def main [http_port: int, fixture_port: int] {
    cdp open (cdp discover $http_port) --name "browser-concurrent" | ignore

    let page_a = (create-page "browser-concurrent" $http_port "page-a")
    let page_b = (create-page "browser-concurrent" $http_port "page-b")

    for session in [$page_a.session $page_b.session] {
        enable-page-basics $session
        cdp call $session "Page.navigate" { url: "about:blank" } | ignore
        wait-for-load $session | ignore
    }
    let script_a = ([
        "(() => {"
        "    document.title = 'page-a'"
        "    document.body.innerHTML = '<main id=\"app\">boot-a</main>'"
        "    setTimeout(() => {"
        "        document.querySelector('#app').textContent = 'ready-a'"
        "        console.log('console-a')"
        "    }, 40)"
        "    return true"
        "})()"
    ] | str join "\n")
    let script_b = ([
        "(() => {"
        "    document.title = 'page-b'"
        "    document.body.innerHTML = '<main id=\"app\">boot-b</main>'"
        "    setTimeout(() => {"
        "        document.querySelector('#app').textContent = 'ready-b'"
        "        console.log('console-b')"
        "    }, 15)"
        "    return true"
        "})()"
    ] | str join "\n")

    cdp call $page_a.session "Runtime.evaluate" {
        expression: $script_a
        returnByValue: true
    } | ignore

    cdp call $page_b.session "Runtime.evaluate" {
        expression: $script_b
        returnByValue: true
    } | ignore

    let state_a = (
        cdp call $page_a.session "Runtime.evaluate" {
            expression: "new Promise(resolve => setTimeout(() => resolve({ title: document.title, text: document.querySelector(`#app`).textContent }), 250))"
            awaitPromise: true
            returnByValue: true
        }
    )
    let state_b = (
        cdp call $page_b.session "Runtime.evaluate" {
            expression: "new Promise(resolve => setTimeout(() => resolve({ title: document.title, text: document.querySelector(`#app`).textContent }), 250))"
            awaitPromise: true
            returnByValue: true
        }
    )

    assert equal $state_a.result.value.title "page-a"
    assert equal $state_a.result.value.text "ready-a"
    assert equal $state_b.result.value.title "page-b"
    assert equal $state_b.result.value.text "ready-b"

    let screenshot_a = (cdp call $page_a.session "Page.captureScreenshot" { format: "png" })
    let pdf_b = (
        cdp call $page_b.session "Page.printToPDF" {
            printBackground: true
            paperWidth: 8.27
            paperHeight: 11.69
        }
    )

    assert (($screenshot_a.data | str length) > 1000) "expected a non-trivial screenshot payload"
    assert (($pdf_b.data | str length) > 1000) "expected a non-trivial PDF payload"

    close-page "browser-concurrent" $page_a.session $page_a.targetId
    close-page "browser-concurrent" $page_b.session $page_b.targetId
    cdp close "browser-concurrent" | ignore
}
