#!/usr/bin/env nu

const schema_dir = (path self ../schema/cdp)
const combined_schema = (path self ../schema/cdp/protocol.nuon)
const browser_protocol_url = (
    "https://raw.githubusercontent.com/ChromeDevTools/"
    + "devtools-protocol/master/json/browser_protocol.json"
)
const js_protocol_url = (
    "https://raw.githubusercontent.com/ChromeDevTools/"
    + "devtools-protocol/master/json/js_protocol.json"
)

def fetch-schema [url: string, output: path]: nothing -> nothing {
    http get -r $url | save -f $output
}

def main []: nothing -> nothing {
    let tmp_dir = (mktemp -td)

    mkdir $schema_dir
    let browser_tmp = ($tmp_dir | path join browser_protocol.json)
    let js_tmp = ($tmp_dir | path join js_protocol.json)
    fetch-schema $browser_protocol_url $browser_tmp
    fetch-schema $js_protocol_url $js_tmp
    let protocol = {
        domains: ([
            (open $browser_tmp | get domains)
            (open $js_tmp | get domains)
        ] | flatten)
    }
    $protocol | to nuon --raw | save -f $combined_schema
    rm -rf $tmp_dir
    print $"Updated CDP schema in ($combined_schema)"
}
