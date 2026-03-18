use std/assert
use ../../../nu/cdp
use cdp_live.nu *

def capture-page-artifacts [http_port: int, target_id: string] {
    let artifact_session = "page-large-artifacts-capture"
    let ws_url = (wait-for-target-ws $http_port $target_id)

    # use a fresh page session for the oversized artifact responses.
    # in live runs, the page state stayed healthy and a second session could
    # fetch the screenshot/pdf promptly, while the original setup session could
    # sit waiting on the same response for minutes. keeping setup and giant
    # artifact reads on separate sockets makes the suite deterministic without
    # changing the transport layer.
    cdp open $ws_url --name $artifact_session | ignore

    try {
        let screenshot = (
            cdp call $artifact_session "Page.captureScreenshot" { format: "png" } --max-time 45sec
        )
        let pdf = (
            cdp call $artifact_session "Page.printToPDF" {
                printBackground: true
                paperWidth: 8.27
                paperHeight: 11.69
            } --max-time 45sec
        )

        {
            screenshot: $screenshot
            pdf: $pdf
        }
    } finally {
        try { cdp close $artifact_session | ignore }
    }
}

def main [http_port: int] {
    cdp open (cdp discover $http_port) --name "browser-large-artifacts" | ignore

    try {
        let page = (create-page "browser-large-artifacts" $http_port "page-large-artifacts")

        try {
            cdp call $page.session "Page.enable" | ignore
            cdp call $page.session "Runtime.enable" | ignore
            cdp call $page.session "Emulation.setDeviceMetricsOverride" {
                width: 4096
                height: 4096
                deviceScaleFactor: 1
                mobile: false
            } | ignore
            cdp call $page.session "Page.navigate" {
                url: "data:text/html,<html><body style='margin:0'></body></html>"
            } | ignore

            wait-for-load $page.session | ignore

            cdp call $page.session "Runtime.evaluate" {
                expression: (
                    "(() => { "
                    + "const canvas = document.createElement('canvas'); "
                    + "canvas.width = 4096; "
                    + "canvas.height = 4096; "
                    + "const context = canvas.getContext('2d'); "
                    + "const image = context.createImageData(4096, 4096); "
                    + "const pixels = new Uint32Array(image.data.buffer); "
                    + "for (let index = 0; index < pixels.length; index++) { "
                    + "pixels[index] = (Math.random() * 0xffffffff) >>> 0; "
                    + "} "
                    + "context.putImageData(image, 0, 0); "
                    + "document.body.appendChild(canvas); "
                    + "return pixels.length; "
                    + "})()"
                )
                returnByValue: true
                awaitPromise: true
            # the canvas build is the slow setup step before the large payload
            # commands. keep its timeout generous, but bounded, so we fail fast
            # on real setup regressions instead of misattributing the delay to
            # the later screenshot/pdf capture.
            } --max-time 60sec | ignore

            let artifacts = (capture-page-artifacts $http_port $page.targetId)
            let screenshot = $artifacts.screenshot
            let pdf = $artifacts.pdf

            assert (
                ($screenshot.data | str length) > 50000000
            ) "expected a screenshot payload well above the historical websocket frame limit"
            assert (($pdf.data | str length) > 1000) "expected a non-trivial PDF payload"
        } finally {
            close-page "browser-large-artifacts" $page.session $page.targetId
        }
    } finally {
        close-browser "browser-large-artifacts"
    }
}
