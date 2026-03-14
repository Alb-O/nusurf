# Nu style guide

## Formatting

### Basic

Assume no extra spaces/tabs unless a rule below allows them
Use one space around pipes, cmds, subcmds, flags, args
Avoid repeated spaces unless inside a string
Omit commas between list items

### One-line

One-line for non-script cmds, simple lists/records in scripts, pipelines under 80 chars
Note where spaces should and shouldn't go

```nu
# Correct examples
[[status]; [UP] [UP]] | all {|el| $el.status == UP }
[1 2 3 4] | reduce {|elt, acc| $elt + $acc }
{x: 1, y: 2}
[1 2] | zip [3 4]
(1 + 2) * 3
```

### Multi-line

Prefer multi-line format for scripts, long/nested lists/records and pipelines over 80 chars

Rules:

Follow one-line rules unless overridden here
Put each pipeline in a block/closure body on its own line
Put each record field on its own line in multi-line records
Put each list item on its own line in multi-line lists
Break around brackets only when it helps structure; avoid lines with single lone parenthesis

```nu
# Correct examples
[[status]; [UP] [UP]] | all {|el|
    $el.status == UP
}

[1 2 3 4] | reduce {|elt, acc|
    $elt + $acc
}

[
  {name: "Teresa", age: 24}
  {name: "Thomas", age: 26}
]
```

## Naming

Prefer full concise words over obscure abbrevs (common acronyms fine)
Commands, subcommands, and flags kebab-case
Variables and cmd params snake_case
Env vars SCREAMING_SNAKE_CASE
Flag vals use underscores in Nushell vars even if the flag name uses dashes

```nu
# Correct examples
def "login basic-auth" [username: string password: string --all-caps] {}
let user_id = 123
$env.APP_VERSION = "1.0.0"
```

## Custom command inputs

Keep positional params to 2 or fewer if possible
Prefer positional params for required inputs
Use options mutually dependent inputs when at least one of several vals must be set
Provide both long and short options

## Documentation

Document every exported entity and its inputs (with grammar)
Dev only inline comments should be lower-case (less grammar)
