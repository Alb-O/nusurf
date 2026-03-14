use std/assert
use cdp.nu *
use cdp_live.nu *

def main [http_port: int] {
    cdp open (cdp discover $http_port) --name "browser-disconnect" | ignore

    try {
        let page = (create-page "browser-disconnect" $http_port "page-disconnect")

        try {
            enable-page-basics $page.session
            cdp call $page.session "Page.navigate" { url: "about:blank" } | ignore
            wait-for-load $page.session | ignore

            cdp call "browser-disconnect" "Target.closeTarget" { targetId: $page.targetId } | ignore

            mut saw_detached = false

            for _ in 0..20 {
                let next_event = (
                    try {
                        cdp event $page.session --max-time 250ms
                    } catch {|err|
                        let message = ($err.msg | str downcase)

                        if (
                            ($message | str contains "not found")
                            or ($message | str contains "closed")
                        ) {
                            null
                        } else {
                            error make $err
                        }
                    }
                )

                if (is nothing $next_event) {
                    break
                }

                if $next_event.method == "Inspector.detached" {
                    $saw_detached = true
                    break
                }
            }

            let call_error = (
                try {
                    cdp call $page.session "Runtime.evaluate" {
                        expression: "1 + 1"
                        returnByValue: true
                    } | ignore

                    ""
                } catch {|err|
                    $err.msg
                }
            )

            assert (
                ($call_error | str length) > 0
            ) "expected a closed target to reject new commands"
            assert str contains-any (
                $call_error | str downcase
            ) [
                "closed"
                "not found"
                "timed out waiting for cdp response"
                "worker is no longer running"
            ] "closed-target failures should surface as deterministic transport errors"

            let recovery_page = (create-page "browser-disconnect" $http_port "page-recovery")

            try {
                enable-page-basics $recovery_page.session
                cdp call $recovery_page.session "Page.navigate" { url: "about:blank" } | ignore
                wait-for-load $recovery_page.session | ignore

                let recovery = (
                    cdp call $recovery_page.session "Runtime.evaluate" {
                        expression: "21 * 2"
                        returnByValue: true
                    }
                )
                assert equal $recovery.result.value 42
            } finally {
                close-page "browser-disconnect" $recovery_page.session $recovery_page.targetId
            }
        } finally {
            close-page "browser-disconnect" $page.session $page.targetId
        }
    } finally {
        close-browser "browser-disconnect"
    }
}
