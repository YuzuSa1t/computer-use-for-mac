#!/usr/bin/env node
// OpenCUA MCP server — universal computer use for any MCP-capable agent
// (Claude Code, Cursor, Cline, Windsurf, WorkBuddy, ...).
//
// Design goals:
//   - dual-track: AX element actions first (instant, reliable), screenshot
//     coordinates as fallback (with glide-cursor animation)
//   - background CGEvent injection: your real cursor and focus are untouched
//   - per-app approvals, deny-list, lock-screen guardian
//
// Zero npm dependencies. Hand-rolled MCP over stdio (newline-delimited JSON).

import { HelperClient, CUAError } from "./lib/client.mjs";

const VERSION = "0.1.0";
const PROTOCOL = "2025-06-18";

// Sent ONCE in the initialize `instructions` field. Repeating this guide inside
// every tool description cost ~17KB of schema on every single request, which is
// exactly the kind of payload that turns a two-line answer into a status report.
const INSTRUCTIONS = `
OpenCUA — macOS computer use. Operate apps in the background; the user's mouse,
focus and frontmost app are never disturbed.

LOOP: cua_apps → cua_app_state(target_id) → act → cua_app_state to verify.

1. cua_apps gives target_id values (bundle id or app name).
2. cua_app_state returns { state_id, tree, view_id, image }. Each tree node is
   { i, p, role, title, desc, value, frame, press }: i = element index, p = parent,
   press = AX-pressable.
3. Click: prefer cua_click with state_id + element (instant AX press). Fall back to
   view_id + [x,y] in screenshot pixels (top-left origin) only when no element
   matches — coordinate clicks are best-effort: recent macOS silently drops
   synthetic input aimed at a non-frontmost app, so verify with cua_app_state
   and report failure instead of retrying blindly.
4. Type: prefer cua_type with element index — background-safe, no IME. Use
   mode "keyboard" only for apps that ignore AX.
5. Re-read state after each meaningful action, like a human looking again.

Coordinates are always in the pixel space of a captured view; pass the same view_id
back. If the window moved you get VIEW_STALE — call cua_app_state again.

REPLY STYLE — as important as the tool call:
- Answer in 1-2 short sentences: what you did, and the visible outcome.
- Never narrate mechanics to the user: no element indices, no ax/cg routes, no
  permission status, no helper lifetime, no "focus untouched", no step logs.
  Bad:  "Pressed C (element 11), then 5 (19), 2 (23), 0 (27) ... all via route ax."
  Good: "已清空并输入 5201314，计算器显示 5,201,314。"
- On error: one line with the code plus the fix, then stop.

NOT_APPROVED → tell the user, stop for that app. APP_BLOCKED → app is on the deny
list; do not retry or work around it.`;

// ---------------------------------------------------------------- tool defs

function tool(name, description, schema) {
  return {
    name,
    description: description.trim(),
    inputSchema: { type: "object", properties: schema.props, required: schema.required || [] },
  };
}

const TOOLS = [
  tool("cua_apps", `
List running apps with target_id. Call this first.`, {}),

  tool("cua_app_state", `
Read app state: element tree + screenshot + view_id. Also defines state_id.`, {
    props: {
      target_id: { type: "string", description: "app bundle id or name from cua_apps" },
      window_id: { type: "integer", description: "specific window (defaults to frontmost on-screen window)" },
      with_view: { type: "boolean", description: "capture screenshot (default true)" },
      max_nodes: { type: "integer", description: "max AX nodes returned (default 600)" },
    },
    required: ["target_id"],
  }),

  tool("cua_click", `
Click by element index (AX press, preferred) or by [x,y] in view pixels.`, {
    props: {
      target_id: { type: "string" },
      state_id: { type: "string", description: "state id from cua_app_state (element clicks)" },
      element: { type: "integer", description: "element index from the tree (preferred)" },
      view_id: { type: "string", description: "view id from cua_app_state (coordinate clicks)" },
      coordinate: { type: "array", items: { type: "number" }, description: "[x, y] in screenshot pixels" },
      button: { type: "string", enum: ["left", "right"], description: "default left" },
      count: { type: "integer", description: "1 = single, 2 = double, 3 = triple" },
      hold_keys: { type: "array", items: { type: "string" }, description: 'modifiers, e.g. ["cmd"]' },
    },
    required: ["target_id"],
  }),

  tool("cua_type", `
Type text into a field (element index preferred; background-safe, no IME).`, {
    props: {
      target_id: { type: "string" },
      text: { type: "string" },
      state_id: { type: "string" },
      element: { type: "integer", description: "text field index from the tree" },
      mode: { type: "string", enum: ["auto", "ax", "keyboard"] },
    },
    required: ["target_id", "text"],
  }),

  tool("cua_key", `
Press a key chord, e.g. ["cmd","c"].`, {
    props: {
      target_id: { type: "string" },
      keys: { type: "array", items: { type: "string" }, description: 'e.g. ["cmd","shift","3"]' },
    },
    required: ["target_id", "keys"],
  }),

  tool("cua_scroll", `
Scroll at a point in view pixels.`, {
    props: {
      target_id: { type: "string" },
      view_id: { type: "string" },
      coordinate: { type: "array", items: { type: "number" } },
      direction: { type: "string", enum: ["up", "down", "left", "right"], description: "default down" },
      pixels: { type: "integer", description: "default 300" },
    },
    required: ["target_id"],
  }),

  tool("cua_drag", `
Drag from one point to another in view pixels.`, {
    props: {
      target_id: { type: "string" },
      view_id: { type: "string" },
      from: { type: "array", items: { type: "number" } },
      to: { type: "array", items: { type: "number" } },
    },
    required: ["target_id", "from", "to"],
  }),

  tool("cua_screenshot", `
Capture an app window as an image.`, {
    props: {
      target_id: { type: "string" },
      view_id: { type: "string", description: "re-capture an existing view" },
      window_id: { type: "integer" },
      max_edge: { type: "integer", description: "longest edge in px, default 1600" },
    },
    required: ["target_id"],
  }),

  tool("cua_open_app", `
Launch an app in the background (show=true to bring it forward).`, {
    props: {
      app: { type: "string", description: "app name or bundle id" },
      show: { type: "boolean", description: "bring to front (default false)" },
    },
    required: ["app"],
  }),

  tool("cua_open_url", `
Open a URL, optionally in a specific app.`, {
    props: {
      url: { type: "string" },
      app: { type: "string" },
    },
    required: ["url"],
  }),

  tool("cua_permissions", `
Check Accessibility / Screen Recording permission status.`, {}),

  tool("cua_policy", `
View or update the per-app allowlist (arrays of target_ids).`, {
    props: {
      allow_add: { type: "array", items: { type: "string" } },
      allow_remove: { type: "array", items: { type: "string" } },
    },
  }),

  tool("cua_stop", `
Stop the helper now. It also self-exits when idle; next call restarts it.`, {}),
];

// ---------------------------------------------------------------- MCP core

const server = new HelperClient();
let clientCapabilities = null;
let nextElicitationId = 1;
const elicitations = new Map(); // not used for responses here; approvals are simpler

let outputPaused = false;
const outQueue = [];

function sendMessage(obj) {
  const line = JSON.stringify(obj) + "\n";
  outQueue.push(line);
  flushOut();
}

function flushOut() {
  if (outputPaused || outQueue.length === 0) return;
  const blob = outQueue.splice(0).join("");
  process.stdout.write(blob, (err) => { if (err) process.exit(1); });
}

function reply(id, result) { sendMessage({ jsonrpc: "2.0", id, result }); }
function replyError(id, code, message) {
  sendMessage({ jsonrpc: "2.0", id, error: { code, message } });
}

// Approval handling: use MCP elicitation when the client supports it,
// otherwise fall back to OPENCUA_AUTO_APPROVE (all / none / csv list).
const AUTO_APPROVE = (process.env.OPENCUA_AUTO_APPROVE ?? "all").trim().toLowerCase();

server.approvalHandler = async (target) => {
  if (clientCapabilities?.elicitation) {
    return await new Promise((resolve) => {
      const id = nextElicitationId++;
      let settled = false;
      const finish = (decision) => {
        if (settled) return;
        settled = true;
        resolve(decision);
      };
      pendingElicitations.set(id, (result) => {
        const action = result?.action;
        if (action === "accept") finish({ allow: true, always: false });
        else if (action === "decline") finish({ allow: false });
        else finish({ allow: false });
      });
      sendMessage({
        jsonrpc: "2.0",
        id,
        method: "elicitation/create",
        params: {
          message: `Allow OpenCUA to operate the app "${target}"? (accept = allow for this session, decline/cancel = refuse)`,
          requestedSchema: { type: "object", properties: {} },
        },
      });
      setTimeout(() => finish({ allow: false }), 120000);
    });
  }
  if (AUTO_APPROVE === "none") return { allow: false };
  if (AUTO_APPROVE === "all") {
    process.stderr.write(`[opencua] auto-approved "${target}" (set OPENCUA_AUTO_APPROVE=none or a csv allowlist to restrict)\n`);
    return { allow: true };
  }
  const list = AUTO_APPROVE.split(",").map((s) => s.trim()).filter(Boolean);
  return { allow: list.includes(target) };
};

const pendingElicitations = new Map();

// ------------------------------------------------------------- tool dispatch

/// Move a base64 PNG out of the JSON payload and onto `res.image`, which the
/// tools/call responder turns into a proper MCP image content part.
function liftImage(res, holder) {
  const src = holder ?? res;
  if (!src?.png_base64) return res;
  res.image = { data: src.png_base64, mimeType: "image/png" };
  delete src.png_base64;
  if (src.view_id && !res.view_id) res.view_id = src.view_id;
  return res;
}

async function callTool(name, args) {
  const t = args.target_id ?? args.target ?? args.app;
  switch (name) {
    case "cua_apps": {
      const res = await server.call("apps");
      // 21 apps × (pid, window_count, window dicts) is mostly dead weight: the
      // caller only needs an id to pass back, a name, and whether it can act.
      const apps = (res?.apps ?? []).map((a) => {
        const o = { target_id: a.target_id, name: a.name };
        if (a.focused) o.focused = true;
        if (!a.operable) o.operable = false;
        if (a.compliance?.blocked) o.blocked = true;
        return o;
      });
      return { apps };
    }
    case "cua_app_state": {
      const res = await server.call("app.state", args);
      // app.state nests the capture under `view`; the PNG must travel as a real
      // image part, not as a ~70KB base64 string inside the text payload
      return liftImage(res, res?.view);
    }
    case "cua_click": {
      const params = {
        target_id: t, state_id: args.state_id, element: args.element,
        view_id: args.view_id, coordinate: args.coordinate,
        button: args.button, count: args.count, hold_keys: args.hold_keys,
      };
      return await server.call("input.click", params);
    }
    case "cua_type": return await server.call("input.type", {
      target_id: t, text: args.text, state_id: args.state_id,
      element: args.element, mode: args.mode,
    });
    case "cua_key": return await server.call("input.key", { target_id: t, keys: args.keys });
    case "cua_scroll": return await server.call("input.scroll", {
      target_id: t, view_id: args.view_id, coordinate: args.coordinate,
      direction: args.direction, pixels: args.pixels,
    });
    case "cua_drag": return await server.call("input.drag", {
      target_id: t, view_id: args.view_id, from: args.from, to: args.to,
    });
    case "cua_screenshot": {
      const res = await server.call("screen.shot", {
        target_id: t, view_id: args.view_id, window_id: args.window_id, max_edge: args.max_edge,
      });
      return liftImage(res);
    }
    case "cua_open_app": return await server.call("app.open", { app: args.app, hidden: !(args.show ?? false) });
    case "cua_open_url": return await server.call("app.open_url", { url: args.url, app: args.app });
    case "cua_permissions": return await server.call("permissions.status");
    case "cua_policy": {
      if (args.allow_add || args.allow_remove) {
        return await server.call("policy.set", {
          allow_add: args.allow_add ?? [], allow_remove: args.allow_remove ?? [],
        });
      }
      return await server.call("policy.list");
    }
    case "cua_stop": {
      const stopped = await server.stop();
      return { stopped, note: "helper exited; the next tool call restarts it" };
    }
    default:
      throw new CUAError("UNKNOWN_TOOL", `unknown tool ${name}`);
  }
}

// ---------------------------------------------------------------- stdio loop

let buffer = "";
// Computer use is inherently sequential — one window, one focus, one cursor.
// A host that pipelines several tools/call messages would otherwise have them
// race: presses land out of order, or get dropped entirely by the target app.
// Chain every message so calls execute in the order they arrived.
let chain = Promise.resolve();

process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk) => {
  buffer += chunk;
  let idx;
  while ((idx = buffer.indexOf("\n")) >= 0) {
    const line = buffer.slice(0, idx);
    buffer = buffer.slice(idx + 1);
    if (!line.trim()) continue;
    let msg;
    try { msg = JSON.parse(line); } catch { continue; }
    chain = chain.then(() => handleMessage(msg)).catch((err) => {
      process.stderr.write(`[opencua] handler error: ${err.stack ?? err.message}\n`);
    });
  }
});

async function handleMessage(msg) {
  if (msg.method === "initialize") {
    clientCapabilities = msg.params?.capabilities ?? {};
    reply(msg.id, {
      protocolVersion: PROTOCOL,
      capabilities: { tools: { listChanged: false } },
      serverInfo: { name: "opencua", version: VERSION },
      instructions: INSTRUCTIONS.trim(),
    });
    return;
  }
  if (msg.method === "notifications/initialized" || msg.method === "notifications/cancelled") return;
  if (msg.method === "ping") { reply(msg.id, {}); return; }

  // client answering our elicitation request
  if (msg.method === undefined && msg.id !== undefined && msg.result !== undefined) {
    const cb = pendingElicitations.get(msg.id);
    if (cb) { pendingElicitations.delete(msg.id); cb(msg.result); }
    return;
  }
  if (msg.error && pendingElicitations.has(msg.id)) {
    const cb = pendingElicitations.get(msg.id);
    pendingElicitations.delete(msg.id);
    cb(null);
    return;
  }

  if (msg.method === "tools/list") { reply(msg.id, { tools: TOOLS }); return; }

  if (msg.method === "tools/call") {
    const name = msg.params?.name;
    const args = msg.params?.arguments ?? {};
    inFlight += 1;
    try {
      const result = await callTool(name, args);
      const content = [];
      if (result?.image) {
        content.push({ type: "image", data: result.image.data, mimeType: result.image.mimeType });
        delete result.image;
      }
      // Compact, single copy: the payload used to be sent twice (pretty text +
      // structuredContent), which alone doubled the token cost of every call.
      content.push({ type: "text", text: JSON.stringify(result) });
      reply(msg.id, { content, isError: false });
    } catch (err) {
      const content = [{
        type: "text",
        text: `ERROR [${err.code ?? "ERROR"}]: ${err.message}`,
      }];
      reply(msg.id, { content, isError: true });
    } finally {
      inFlight -= 1;
    }
    return;
  }

  if (msg.id !== undefined) replyError(msg.id, -32601, `method not found: ${msg.method}`);
}

// The host closes our stdin when the agent session ends. Disconnect, but do NOT
// force the helper down: a host that spawns one server process per tool call
// would otherwise tear the helper down between calls, throwing away state_id and
// breaking every element click. The helper's own idle watchdog exits it shortly
// after the last client leaves — that is the whole point of the grace period.
// `cua_stop` remains available when an immediate exit is actually wanted.
let inFlight = 0;
let leaving = false;
async function leave(reason) {
  if (leaving) return;
  leaving = true;
  const deadline = Date.now() + 3000;
  while (inFlight > 0 && Date.now() < deadline) {
    await new Promise((r) => setTimeout(r, 50));
  }
  server.close();
  process.stderr.write(`[opencua] mcp server exiting (${reason})\n`);
  process.exit(0);
}

process.stdin.on("end", () => { void leave("stdin closed"); });
process.stdin.on("close", () => { void leave("stdin closed"); });
for (const sig of ["SIGTERM", "SIGINT", "SIGHUP"]) {
  process.on(sig, () => { void leave(`signal ${sig}`); });
}
process.stderr.write(`[opencua] MCP server ${VERSION} ready\n`);
