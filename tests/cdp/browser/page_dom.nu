use std/assert
use cdp.nu *
use cdp_live.nu *

def data-page-url [html: string] {
    $"data:text/html,($html | url encode)"
}

def with-page [
    browser: any
    name: string
    body: closure
] {
    let page = (cdp page new --browser $browser --name $name)

    try {
        cdp use --browser $browser --page $page | ignore
        do $body $page
    } finally {
        try { cdp page close --page $page --browser $browser | ignore }
    }
}

def "test page goto wait-for and query" [browser: any] {
    with-page $browser "page-dom-goto" {|page|
        let html = '
            <!doctype html>
            <html>
            <body>
              <main id="status">booting</main>
              <ul>
                <li class="item">first</li>
                <li class="item">second</li>
              </ul>
              <script>
                setTimeout(() => {
                  const ready = document.createElement("button");
                  ready.id = "delayed";
                  ready.textContent = "ready now";
                  document.body.appendChild(ready);
                }, 150);
              </script>
            </body>
            </html>
        '

        cdp page goto (data-page-url $html) --page $page --wait-for "#delayed" --wait-state visible --max-time (
            5sec
        ) --interval 50ms | ignore

        let delayed = (cdp page query "#delayed" --page $page)
        let items = (cdp page query ".item" --all --page $page)
        let missing = (cdp page query "#missing" --page $page)

        assert equal $delayed.selector "#delayed"
        assert equal $delayed.tag "button"
        assert equal $delayed.id "delayed"
        assert equal $delayed.visible true
        assert (($delayed.text | str contains "ready now"))

        assert equal ($items | length) 2
        assert equal (($items | get 0.selector)) ".item"
        assert equal (($items | get 0.tag)) "li"
        assert equal (($items | get 1.text)) "second"

        assert nothing $missing
    }
}

def "test page wait states" [browser: any] {
    with-page $browser "page-dom-wait" {|page|
        let html = '
            <!doctype html>
            <html>
            <body>
              <main id="status">waiting</main>
              <div id="hide-later">hide me</div>
              <div id="gone-later">remove me</div>
              <script>
                setTimeout(() => {
                  const late = document.createElement("div");
                  late.id = "show-later";
                  late.textContent = "ready and visible";
                  document.body.appendChild(late);
                }, 120);
                setTimeout(() => {
                  document.querySelector("#hide-later").style.display = "none";
                }, 180);
                setTimeout(() => {
                  document.querySelector("#gone-later").remove();
                }, 220);
              </script>
            </body>
            </html>
        '

        cdp page goto (data-page-url $html) --page $page --max-time 5sec | ignore

        let present = (cdp page wait "#show-later" --page $page --max-time 5sec --interval 50ms)
        let visible = (
            cdp page wait "#show-later" --page $page --state visible --text "visible" --max-time (
                5sec
            ) --interval 50ms
        )
        let hidden = (cdp page wait "#hide-later" --page $page --state hidden --max-time 5sec --interval 50ms)
        let gone = (cdp page wait "#gone-later" --page $page --state gone --max-time 5sec --interval 50ms)

        assert equal $present.id "show-later"
        assert equal $present.visible true
        assert equal $visible.id "show-later"
        assert equal $visible.visible true
        assert equal $hidden.id "hide-later"
        assert equal $hidden.visible false
        assert nothing $gone
    }
}

def "test page wait timeout" [browser: any] {
    with-page $browser "page-dom-timeout" {|page|
        cdp page goto "about:blank" --page $page --max-time 5sec | ignore

        let timeout_error = (
            try {
                cdp page wait "#never" --page $page --max-time 300ms --interval 50ms
                "wait unexpectedly succeeded"
            } catch {|err|
                $err.msg
            }
        )

        assert equal $timeout_error "Timed out waiting for selector #never to become present within 300ms"
    }
}

def "test page fill and click" [browser: any] {
    with-page $browser "page-dom-actions" {|page|
        let html = '
            <!doctype html>
            <html>
            <body>
              <input id="name" value="">
              <button id="submit">save</button>
              <output id="result"></output>
              <script>
                window.fillEvents = [];
                const input = document.querySelector("#name");
                input.addEventListener("input", () => {
                  window.fillEvents.push(`input:${input.value}`);
                });
                input.addEventListener("change", () => {
                  window.fillEvents.push(`change:${input.value}`);
                });
                document.querySelector("#submit").addEventListener("click", () => {
                  document.body.dataset.clicked = "yes";
                  document.querySelector("#result").textContent = input.value;
                });
              </script>
            </body>
            </html>
        '

        cdp page goto (data-page-url $html) --page $page --max-time 5sec | ignore

        let filled = (cdp page fill "#name" "Ada Lovelace" --page $page --max-time 5sec --interval 50ms)
        let clicked = (cdp page click "#submit" --page $page --max-time 5sec --interval 50ms)
        let result = (
            cdp page wait "#result" --page $page --text "Ada Lovelace" --max-time 5sec --interval 50ms
        )
        let fill_events = (cdp page eval "window.fillEvents" --page $page)
        let clicked_flag = (cdp page eval "document.body.dataset.clicked" --page $page)

        assert equal $filled.id "name"
        assert equal $filled.value "Ada Lovelace"
        assert equal $clicked.id "submit"
        assert equal $result.id "result"
        assert (($result.text | str contains "Ada Lovelace"))
        assert equal $clicked_flag "yes"
        assert equal ($fill_events | length) 2
        assert equal ($fill_events | get 0) "input:Ada Lovelace"
        assert equal ($fill_events | get 1) "change:Ada Lovelace"
    }
}

def "test page click handles first-query removal race" [browser: any] {
    with-page $browser "page-dom-click-race" {|page|
        let html = '
            <!doctype html>
            <html>
            <body>
              <button id="trap">trap</button>
              <script>
                const originalQuerySelectorAll = document.querySelectorAll.bind(document);
                let trapQueries = 0;
                document.querySelectorAll = (...args) => {
                  const result = originalQuerySelectorAll(...args);
                  if (args[0] === "#trap" && trapQueries == 0) {
                    trapQueries += 1;
                    queueMicrotask(() => {
                      document.querySelector("#trap")?.remove();
                    });
                  }
                  return result;
                };
              </script>
            </body>
            </html>
        '

        cdp page goto (data-page-url $html) --page $page --max-time 5sec | ignore

        let clicked = (cdp page click "#trap" --page $page --max-time 5sec --interval 50ms)

        assert equal $clicked.id "trap"
        assert equal $clicked.tag "button"
        assert (not ("matches" in ($clicked | columns))) "click should return the action record shape"
    }
}

def "test raw buffer defaults" [http_port: int] {
    let browser_open = (cdp browser open $http_port --name "browser-raw-open")

    try {
        cdp call $browser_open.id "Browser.getVersion" | ignore

        let raw_browser = (ws recv $browser_open.id --max-time 2sec --full)

        assert some $raw_browser "expected raw browser-open traffic"
        assert equal $raw_browser.type "text"
    } finally {
        try { cdp close $browser_open.id | ignore }
    }

    let browser_start = (cdp browser start --port $http_port --name "browser-raw-start")

    try {
        cdp call $browser_start.session "Browser.getVersion" | ignore

        let raw_started = (ws recv $browser_start.session --max-time 2sec --full)

        assert some $raw_started "expected raw browser-start traffic"
        assert equal $raw_started.type "text"
    } finally {
        if ($browser_start.launched | default false) {
            cdp browser stop $browser_start
        } else {
            try { cdp close $browser_start.session | ignore }
        }
    }

    let browser_page = (cdp browser open $http_port --name "browser-raw-page")

    try {
        cdp use $browser_page | ignore

        let page = (cdp page new --name "page-raw-default")

        try {
            cdp page eval "1 + 1" --page $page | ignore

            let raw_page = (ws recv $page.session --max-time 2sec --full)

            assert some $raw_page "expected raw page-new traffic"
            assert equal $raw_page.type "text"
        } finally {
            try { cdp page close --page $page --browser $browser_page | ignore }
        }
    } finally {
        try { cdp close $browser_page.id | ignore }
    }
}

def "test goto wait validation" [browser: any] {
    with-page $browser "page-dom-goto-flags" {|page|
        let goto_error = (
            try {
                cdp page goto "about:blank" --page $page --no-wait --wait-for "#later"
                "goto unexpectedly succeeded"
            } catch {|err|
                $err.msg
            }
        )

        assert equal $goto_error "`cdp page goto` cannot combine --no-wait with --wait-for"
    }
}

def main [http_port: int] {
    let browser = (cdp browser open $http_port --name "browser-page-dom")

    try {
        cdp use $browser | ignore

        test page goto wait-for and query $browser
        test page wait states $browser
        test page wait timeout $browser
        test page fill and click $browser
        test page click handles first-query removal race $browser
        test raw buffer defaults $http_port
        test goto wait validation $browser
    } finally {
        try { cdp close $browser.id | ignore }
    }
}
