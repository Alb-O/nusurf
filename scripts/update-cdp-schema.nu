#!/usr/bin/env nu

const repo_root = (path self .. | path dirname)
const schema_dir = (path self ../schema/cdp)

def fetch-schema [url: string, output: path] {
    http get -r $url
    | save -f $output
}

def main [] {
    let tmp_dir = (mktemp -td)

    mkdir $schema_dir

    let browser_tmp = ($tmp_dir | path join browser_protocol.json)
    let js_tmp = ($tmp_dir | path join js_protocol.json)

    fetch-schema "https://raw.githubusercontent.com/ChromeDevTools/devtools-protocol/master/json/browser_protocol.json" $browser_tmp
    fetch-schema "https://raw.githubusercontent.com/ChromeDevTools/devtools-protocol/master/json/js_protocol.json" $js_tmp

    mv -f $browser_tmp ($schema_dir | path join browser_protocol.json)
    mv -f $js_tmp ($schema_dir | path join js_protocol.json)

    rm -rf $tmp_dir

    print $"Updated CDP schema in ($schema_dir)"
}
