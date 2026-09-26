# The launch file

`runlaunch <file> [name]` reads one YAML file that says what to run and, optionally, how
to show it. The smallest file is a list of processes:

```yaml
processes:
  Web: python app.py --port 8000
  Worker: .\worker.exe
```

`runlaunch launch.yml` starts both. `runlaunch launch.yml Web` starts one. Everything else
in this document is optional and can be ignored until it is needed.

## Sections

| Key          | What it is                                                                 |
|--------------|----------------------------------------------------------------------------|
| `processes`  | `Name: command line`, one per line. Required.                              |
| `groups`     | `Name: [process, process, ...]`: a set started together.                    |
| `configs`    | A list of `- name: ...` entries with the extra settings for one process or group. |
| `colorRules` | Colour rules applied to every view.                                        |
| `script`     | Command lines run once everything started at launch has a view.            |
| `default`    | The process or group `runlaunch <file>` starts when no name is given.       |

Names are shared between processes and groups and must be unique across the two. A name
cannot be `_`, start with `~` or contain `:` (scripts use those). Any unknown key, anywhere,
is an error that names the key and lists the valid ones, so a typo cannot silently
disable a setting.

### processes

The value is the command line, split on whitespace: the first token is the program, the
rest its arguments. Double quotes group a token with spaces (`"C:\Program Files\x.exe"`);
inside them `\"` is a literal quote and every other backslash is kept as written. Single
quotes group too, with no escapes.

How the line is run depends on the process' `type` (see `configs`):

| `type`   | The command line is...                                                       |
|----------|------------------------------------------------------------------------------|
| `native` | spawned as is (the default)                                                  |
| `python` | run as `py -u <command line>` (`python3 -u` off Windows): a script path, or `-m module` |
| `shell`  | handed whole to `cmd.exe /c` (`sh -c` off Windows), so pipes and built-ins work |

The view is titled with the process name. One caveat for `shell` on Linux: `stop` kills the
shell, and `sh` (dash on Ubuntu) runs the command as a child rather than replacing itself, so
a long-running command may keep running after the shell is gone. Use `native` for commands
you expect to stop, or `sh -c 'exec ...'` style entries with `native`.

### groups

```yaml
groups:
  Backend: [Web, Worker]
```

Every member must exist in `processes`; a missing or repeated member is an error. Starting
a group runs the group's `preTask` first; once it has exited with code 0, each member starts
after its own `preTask` (a task shared by several members runs once). The group's `script`
and `colorRules` apply to the members' views. At shutdown the members' `postTask`s and the
group's run.

### configs

```yaml
configs:
  - name: Web
    type: python
    args: ['--debug']          # appended after the command line's own arguments
    env:                       # extra environment for the process
      DEBUG: '1'
    preTask: Build             # runs first: this entry starts once it has exited 0
    postTask: Cleanup          # a process started at shutdown, after this one is stopped
    script:                    # runs once this process' view exists
      - ': hide Warning'
    colorRules:                # applied to this process' view
      - pattern: error
        foreground_color: '220,6,6'
        just_pattern: true
  - name: Backend              # a group takes preTask, postTask, script and colorRules
    script: ['_: wrap on']
```

Every field is optional. `type`, `args` and `env` are for processes only. `env` is a map,
or a list of `KEY=VALUE` strings. One config entry per name.

A `preTask`/`postTask` names a process; that process then counts as a task and is left out
when "everything" is started (it is started with the entry that needs it). A pre task runs
first: the entry starts once the task has exited with code 0. If the task exits with any
other code, is stopped, or cannot be started, the entry is not started and a view with the
entry's name says why; fix the task and `start` the entry again. A task shared by several
entries runs once per start. A task's own `preTask`/`postTask` are not run. A post task
starts at shutdown, after the entry's processes have been stopped, and is waited for.

### colorRules

```yaml
colorRules:
  - pattern: '\[Info\]'         # a regex
    foreground_color: '39,174,96'
    background_color: '30,30,30'
    just_pattern: true          # colour only the match; default: the whole line
```

A rule needs a `pattern` and at least one colour. File-level rules apply to every view, a
process' rules to its view, a group's rules to each member's view, in that order. Rules
from `.debugUi.json` (user profile, then working directory) still apply and come first.

### script

A list of `select: command` lines, exactly what the command bar accepts (`?` in the app
lists the commands):

```yaml
script:
  - '_: color debug red'         # every view
  - 'Web: hide Warning'          # the view titled Web
  - ': merge merged --all'       # the focused view
```

When a script runs:

| Script                | Runs once...                                                    |
|-----------------------|-----------------------------------------------------------------|
| a process' `script`   | that process' view exists                                       |
| a group's `script`    | every member's view exists (each time the group is started)     |
| the file's `script`   | every process started from the command line has a view          |

Scripts run in that order when one view completes several of them.

### default

```yaml
default: Backend
```

What `runlaunch <file>` starts without a name. Without `default:` it starts everything:
every process that is not somebody's `preTask`/`postTask`, in file order, each after its own
pre task (a task shared by several processes starts once).

## `${...}` in values

Command lines, `args` entries and `env` values may use `${env:NAME}` (an environment
variable; unset is an error), `${cwd}` (the working directory) and the VS Code-style names
`${workspaceFolder}`, `${file}` and friends, which are looked up as environment variables.
Expansion happens per token, so a value with spaces stays one argument. Quote any value
that contains `${...}`: the YAML library reads an unquoted `${env:NAME}` as a map key.

Only the first `${...}` in a value is expanded (an existing limitation of `expand.zig`).

## YAML that the library does not take

The YAML library is a partial implementation. What it rejects, it rejects with a
line/column message; what it would crash on, `runlaunch` catches first:

- write maps in block style (`env:` then `KEY: value` on the next lines), not `{a: 1, b: 2}`;
- keys cannot be quoted; values can;
- a value that contains a quote must be quoted as a whole with the other kind:
  `Count: 'cmd.exe /c "echo hi"'`, not `Count: cmd.exe /c "echo hi"`;
- quote a value that contains `${...}`, `: ` or ` #`;
- an apostrophe opens a quoted string even inside a word, so quote values such as `"it's"`
  (and since the command line splitter reads quotes the same way, an apostrophe inside a
  command line argument needs double quotes around the argument: `'echo "it''s"'`);
- `\"` inside a double-quoted value is not understood: to pass a literal `"` to a program,
  single-quote the value (`'say "hi"'`);
- a quoted value must close on the same line;
- JSON files are not supported (JSON is a subset of YAML, but not of this library's).

## Where the old fields went

The previous format was VS Code's `launch.json` + `tasks.json`. Fields whose behaviour
exists were carried over under the new names; fields that never did anything were dropped.

| Old (`configurations[]`)              | Now                                                             |
|----------------------------------------|-----------------------------------------------------------------|
| `name`                                 | the key under `processes:`                                      |
| `type: python`/`debugpy`               | `configs: type: python`                                         |
| `type: cppdbg`/`cppvsdbg`              | `configs: type: native` (the default; the entry can be left out) |
| `program`                              | the command line                                                |
| `module`                               | `-m module` in the command line, with `type: python`            |
| `program` as the interpreter (with `module`) | dropped: use `type: native` with the interpreter in the command line |
| `args`                                 | `configs: args` (now also `${...}`-expanded)                    |
| `env`                                  | `configs: env` (values now `${...}`-expanded)                   |
| `preLaunchTask` / `postDebugTask`      | `configs: preTask` / `postTask`, naming a process               |
| `request`, `consoleTitle`, `console`, `stopOnEntry`, `envFile`, `connect` | dropped: no behaviour was implemented |
| `version`                              | dropped                                                         |

| Old (`compounds[]`)                    | Now                                                             |
|----------------------------------------|-----------------------------------------------------------------|
| `name`, `configurations`               | the key and list under `groups:`                                |
| `preLaunchTask` / `postDebugTask`      | `configs: preTask` / `postTask` on the group                    |
| `stopAll`                              | dropped: no behaviour was implemented                           |

| Old (`tasks[]`)                        | Now                                                             |
|----------------------------------------|-----------------------------------------------------------------|
| `label`, `command`, `args`             | an ordinary process (its name, its command line)                |
| `type: shell`                          | `configs: type: shell` (new: tasks used to be spawned directly) |
| `group`, `presentation`, `problemMatcher` | dropped: no behaviour was implemented                        |

New in this format: `default`, `groups` validation (a missing member is an error, not
silently skipped), `script` at every level, `colorRules` in the launch file, `type: shell`,
and a `preTask` that must finish with exit code 0 before its process starts (VS Code asks
whether to continue; `runlaunch` leaves the process unstarted and says so in its view).

### Behaviour kept as it was (worth knowing)

- `postTask` processes start at shutdown, after the launched processes are stopped, and
  are waited for.
- `env` replaces the child's environment rather than extending it (the child sees only the
  listed variables).
- The view title is now the process name; it used to be the program path, module or task
  label. Colour rules in `.debugUi.json` match on that title.
