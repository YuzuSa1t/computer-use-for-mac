# OpenCUA Helper · JSON-RPC protocol

The helper listens on a Unix domain socket at `~/.opencua/helper.sock`
(mode `0600`). The bridge uses this protocol, but nothing forces you to — any
client that can write JSON lines to the socket can drive the helper directly.

- Transport: `AF_UNIX`, `SOCK_STREAM`
- Framing: one JSON object per line (`\n` terminated)
- No handshake, no auth beyond file permissions on the socket

## Envelope

Request:

```json
{"id": 1, "method": "app.state", "params": {"target_id": "Calculator"}}
```

`id` is optional for notifications (the request runs, no reply is sent).

Response:

```json
{"id": 1, "ok": true, "result": {"…": "…"}}
```

Failure:

```json
{"id": 1, "ok": false, "error": {"code": "APP_BLOCKED", "message": "target …"}}
```

An error object is identified by the presence of `code`. `result` is otherwise
free-form per method.

## Methods

### `health`

No parameters. Reports identity, permissions, activity and lifetime policy.

```json
{
  "ok": true,
  "version": "0.1.0",
  "protocol": "1",
  "permissions": {"accessibility": true, "screen_recording": true, "all_granted": true},
  "locked": false,
  "cursor": true,
  "announce": true,
  "auto_approve": true,
  "pid": 33564,
  "uptime_seconds": 12,
  "idle_seconds": 0,
  "clients": 1,
  "in_flight": 1,
  "auto_exit": {"grace_seconds": 20, "idle_seconds": 900}
}
```

`auto_exit` is the string `"disabled"` when `OPENCUA_KEEP_ALIVE=1`.

### `permissions.status` · `permissions.request`

`permissions.request` takes no parameters and triggers the macOS prompt before
returning the same payload as `permissions.status`.

### `policy.list` · `policy.set`

`policy.set` accepts `allow_add` and `allow_remove`, arrays of `target_id`.

```json
{"allow_add": ["com.apple.calculator"], "allow_remove": []}
```

### `lifecycle.set`

Pushes the calling client's policy to a possibly reused helper. A helper's own
environment is fixed at spawn time, so without this an `OPENCUA_*` flag set on a
later client would be ignored for the helper's whole life.

```json
{"exit_grace": 20, "idle_seconds": 900, "cursor": true, "announce": true, "lang": "zh"}
```

| Field | Meaning |
|---|---|
| `exit_grace` | seconds to live after the last client leaves |
| `idle_seconds` | seconds of inactivity before exiting with a client attached |
| `cursor` | show the software cursor |
| `announce` | outline the window + "OpenCUA is operating …" badge, held for the run |
| `lang` | `zh` or `en`, badge text only |

`cursor` and `announce` are assigned unconditionally: omit one and the override
is cleared, so the config file applies again. Whichever client spoke last owns
the visual policy.

The standing announcement — outline plus badge — is *state*, not a one-shot
notice. It is raised on the first action against an app, re-framed if the window
moves, and retired when the last client disconnects or after `30 s` of silence
(`OPENCUA_ENGAGEMENT_IDLE`). It is also dropped as soon as the announced window
becomes occluded, because an outline over the wrong window names the wrong
thing.

### `apps`

Lists running regular applications.

```json
{"apps": [{"target_id": "com.apple.finder", "name": "Finder", "pid": 512,
           "focused": true, "window_count": 1, "operable": true,
           "windows": [{"window_id": 1234, "title": "Documents", "frame": [0, 0, 1280, 800]}]}]}
```

Blocked apps carry `"compliance": {"blocked": true}` instead of `windows`.

### `app.open` · `app.open_url`

```json
{"app": "Calculator", "hidden": true}
{"url": "https://example.com", "app": "Safari"}
```

`hidden` defaults to `true`: the app launches without taking focus.

### `app.state`

The core call. Returns the accessibility tree, an optional screenshot, and the
identifiers needed for every later action.

```json
{"target_id": "com.apple.calculator", "window_id": 1234,
 "with_view": true, "max_nodes": 600, "max_depth": 14}
```

Response:

| Field | Meaning |
|---|---|
| `target_id` | canonical app identifier |
| `state_id` | token for `input.click` / `app.element` / `input.type` |
| `tree` | flat node array, parents referenced by index |
| `view` | `{view_id, width, height, scale}` when `with_view` |
| `tree_error` | present when AX returned no windows |
| `view_error` | present when capture failed |

Node shape:

```json
{"i": 20, "p": 5, "role": "AXButton", "desc": "One", "id": "One",
 "frame": [2900, 550, 48, 48], "kids": 0, "press": true}
```

| Field | Meaning |
|---|---|
| `i` | element index, unique within this `state_id` |
| `p` | parent index (`-1` for the window node) |
| `role` | AX role, e.g. `AXButton` |
| `id` | AX identifier, present only when the app sets one |
| `title`, `desc` | AX title / description, truncated to 120 chars |
| `value` | AX value, as a string (200 chars) or a number |
| `frame` | `[x, y, w, h]` in global top-left points |
| `kids` | child count (children follow the parent in the flat array) |
| `press` | `true` when the node accepts `kAXPressAction` |

The tree is flat, ordered parent-before-child. Every optional field is omitted
rather than sent as `null`, so a node carries only what the app exposes.

### `app.element`

Performs an AX action on a node, without coordinates.

```json
{"target_id": "Calculator", "state_id": "…", "element": 20,
 "action": "press"}
```

`action` is one of `press`, `raise`, `show_menu`, `increment`, `decrement`,
`confirm`, `cancel`, `pick`, or `set_value` (requires `value`).

### `screen.shot`

Captures a window, with or without a prior state read.

```json
{"target_id": "Calculator", "view_id": "…", "window_id": 1234, "max_edge": 1600}
```

Response: `{"view_id": "…", "png_base64": "…"}`.

### `input.click`

Two mutually exclusive forms.

Element form — instant AX press, works on background apps:

```json
{"target_id": "Calculator", "state_id": "…", "element": 20}
```

Coordinate form — synthesized event at a point in view pixels:

```json
{"target_id": "Calculator", "view_id": "…", "coordinate": [105, 188]}
```

Optional: `button` (`left`/`right`), `count`, `hold_keys`, `instant` (skip the
cursor animation delay). Without `view_id` the coordinate is treated as a global
top-left point when `coordinate_space` is `"global_top_left"`.

Response: `{"ok": true, "route": "ax"}` or
`{"ok": true, "route": "cg", "global": [x, y]}`.

### `input.drag`

```json
{"target_id": "Finder", "view_id": "…", "from": [100, 100], "to": [400, 100]}
```

### `input.scroll`

```json
{"target_id": "Safari", "view_id": "…", "coordinate": [400, 300],
 "direction": "down", "pixels": 300}
```

### `input.key`

```json
{"target_id": "Safari", "keys": ["cmd", "t"]}
```

### `input.type`

`mode` defaults to `"ax"`.

```json
{"target_id": "Notes", "text": "hello 世界", "state_id": "…", "element": 58}
```

| mode | Behaviour |
|---|---|
| `ax` (default) | set the field value directly — no input method involved |
| `auto` | try AX, fall back to keyboard events |
| `keyboard` | post Unicode key events to the process |

`mode: "ax"` without an element targets the app's focused element; if there is
none it returns `NO_FIELD`.

### `shutdown` · `stop`

Replies `{"stopping": true}`, then closes the listener and exits. The next
client request spawns a fresh helper.

## Server-initiated

### `approval.request`

Broadcast to every connected client when an app needs approval and
`auto_approve` is off:

```json
{"method": "approval.request", "params": {"target": "com.apple.calculator"}}
```

Clients answer with:

```json
{"method": "approval.respond",
 "params": {"target": "com.apple.calculator", "allow": true, "always": false}}
```

The first response wins. No response within 90 seconds resolves to refusal
(`NOT_APPROVED`).

## Error codes

| Code | Cause |
|---|---|
| `APP_BLOCKED` | target is on the deny-list |
| `NOT_APPROVED` | approval denied or timed out |
| `LOCKED` | screen is locked |
| `VIEW_STALE` | window moved since the view was captured |
| `TARGET_NOT_FOUND` | app not running or not resolvable |
| `BAD_ELEMENT` | unknown `state_id` / element index |
| `BAD_PARAMS` | missing or malformed parameter |
| `NO_WINDOW` | target has no on-screen window |
| `NO_FIELD` | AX typing requested but nothing is focused |
| `SET_FAILED` | AX value could not be written |
| `AX_FAILED` | AX press failed |
| `AX_ACTION_FAILED` | generic AX action failed |
| `EVENT_FAILED` | event synthesis failed |
| `CAPTURE_FAILED` | screen capture failed |
| `OPEN_FAILED` | app could not be launched |
| `UNKNOWN_METHOD` | unrecognized method |
