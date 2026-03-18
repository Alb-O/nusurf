use std/assert
use ../../../nu/cdp
use cdp_live.nu *

def main [http_port: int, fixture_port: int] {
    cdp open (cdp discover $http_port) --name "browser-concurrent" | ignore

    try {
        let page_a = (create-page "browser-concurrent" $http_port "page-a")

        try {
            let page_b = (create-page "browser-concurrent" $http_port "page-b")

            try {
                for session in [$page_a.session $page_b.session] {
                    enable-page-basics $session
                    cdp call $session "Network.enable" | ignore
                    cdp call $session "Page.navigate" { url: "about:blank" } | ignore
                    wait-for-load $session | ignore
                    drain-events $session
                }
                let ping_a = (fixture-url $fixture_port "page-a")
                let ping_b = (fixture-url $fixture_port "page-b")
                let script_a = ([
                    "(() => {"
                    "    document.title = 'page-a'"
                    "    document.body.innerHTML = '<main id=\"app\">boot-a</main>'"
                    "    setTimeout(() => {"
                    "        document.querySelector('#app').textContent = 'ready-a'"
                    "        console.log('console-a')"
                    (["        fetch('", $ping_a, "')"] | str join "")
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
                    (["        fetch('", $ping_b, "')"] | str join "")
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

                let console_a = (
                    cdp event $page_a.session "Runtime.consoleAPICalled" --max-time 5sec
                )
                let console_b = (
                    cdp event $page_b.session "Runtime.consoleAPICalled" --max-time 5sec
                )
                let request_a = (
                    cdp event $page_a.session "Network.requestWillBeSent" --max-time 5sec
                )
                let request_b = (
                    cdp event $page_b.session "Network.requestWillBeSent" --max-time 5sec
                )
                let failed_a = (cdp event $page_a.session "Network.loadingFailed" --max-time 5sec)
                let failed_b = (cdp event $page_b.session "Network.loadingFailed" --max-time 5sec)

                assert equal ($console_a.params.args | get 0.value) "console-a"
                assert equal ($console_b.params.args | get 0.value) "console-b"
                assert str contains $request_a.params.request.url "source=page-a"
                assert str contains $request_b.params.request.url "source=page-b"
                assert equal $failed_a.params.errorText "net::ERR_FAILED"
                assert equal $failed_b.params.errorText "net::ERR_FAILED"

                let state_a = (
                    cdp call $page_a.session "Runtime.evaluate" {
                        expression: (
                            "new Promise(resolve => setTimeout(() => "
                            + "resolve({ title: document.title, "
                            + "text: document.querySelector(`#app`).textContent }), 250))"
                        )
                        awaitPromise: true
                        returnByValue: true
                    }
                )
                let state_b = (
                    cdp call $page_b.session "Runtime.evaluate" {
                        expression: (
                            "new Promise(resolve => setTimeout(() => "
                            + "resolve({ title: document.title, "
                            + "text: document.querySelector(`#app`).textContent }), 250))"
                        )
                        awaitPromise: true
                        returnByValue: true
                    }
                )

                assert equal $state_a.result.value.title "page-a"
                assert equal $state_a.result.value.text "ready-a"
                assert equal $state_b.result.value.title "page-b"
                assert equal $state_b.result.value.text "ready-b"

                let metrics_a = (cdp call $page_a.session "Page.getLayoutMetrics")
                let metrics_b = (cdp call $page_b.session "Page.getLayoutMetrics")

                assert ($metrics_a.cssContentSize.width > 0) "expected page-a layout metrics"
                assert ($metrics_b.cssContentSize.width > 0) "expected page-b layout metrics"
            } finally {
                close-page "browser-concurrent" $page_b.session $page_b.targetId
            }
        } finally {
            close-page "browser-concurrent" $page_a.session $page_a.targetId
        }
    } finally {
        close-browser "browser-concurrent"
    }
}
