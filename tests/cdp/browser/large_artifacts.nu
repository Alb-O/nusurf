use std/assert
use cdp.nu *
use cdp_live.nu *

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
            } --max-time 120sec | ignore

            let screenshot = (
                cdp call $page.session "Page.captureScreenshot" { format: "png" } --max-time 180sec
            )
            let pdf = (
                cdp call $page.session "Page.printToPDF" {
                    printBackground: true
                    paperWidth: 8.27
                    paperHeight: 11.69
                } --max-time 60sec
            )

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
