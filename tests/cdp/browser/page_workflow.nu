use std/assert
use cdp.nu *

def main [http_port: int] {
    let browser = (cdp browser open $http_port --name "browser-page-workflow" --use)

    try {
        assert equal $env.CDP_BROWSER.session "browser-page-workflow"
        assert (($env | get -o CDP_PAGE | describe) == "nothing")

        let page = (cdp page new --name "page-workflow" --use)

        assert equal $env.CDP_BROWSER.session "browser-page-workflow"
        assert equal $env.CDP_PAGE.session "page-workflow"
        assert equal $env.CDP_PAGE.targetId $page.targetId

        let browser_again = (cdp use --browser $browser)
        assert equal $browser_again.browser.session "browser-page-workflow"
        assert equal $browser_again.page.session "page-workflow"
        assert equal $env.CDP_PAGE.session "page-workflow"

        let pages = (cdp page list)
        assert (($pages | where targetId == $page.targetId | length) == 1)
        assert (($pages | where current == true | get 0.targetId) == $page.targetId)

        cdp page goto "data:text/html,<title>nu-page</title><main id=\"app\">ok</main>" | ignore

        let title = (cdp page eval "document.title")
        let text = (cdp page eval "document.querySelector(`#app`).textContent")
        let full = (cdp page eval "({answer: 42})" --full)
        let explicit = (cdp page eval "1 + 1" --page $page)

        assert equal $title "nu-page"
        assert equal $text "ok"
        assert equal $full.result.type "object"
        assert equal $explicit 2

        let closed = (cdp page close)
        assert equal $closed.session "page-workflow"
        assert (($env | get -o CDP_PAGE | describe) == "nothing")
        assert (($env | get -o CDP_BROWSER.session) == "browser-page-workflow")
        assert (($pages | where session == "page-workflow" | length) == 1)

        let remaining = (cdp page list | where targetId == $page.targetId | length)
        assert equal $remaining 0

        let browser_only = (cdp use $browser)
        assert equal $browser_only.browser.session "browser-page-workflow"
        assert (($browser_only.page | describe) == "nothing")
    } finally {
        try { cdp page close --page "page-workflow" --browser $browser.id | ignore }
        cdp close $browser.id | ignore
    }
}
