#!/usr/bin/env node
// OpenCUA CLI — computer use for agents and scripts that don't speak MCP.
// Every capability of the MCP server, from the shell:
//
//   cua doctor                          # check helper, permissions, versions
//   cua apps [--json]                    # list operable apps (compact table)
//   cua state "Calculator" [--no-view]  # element tree + screenshot state
//   cua shot "Safari" [-o shot.png]     # screenshot to file
//   cua click "Calculator" --element 12 # element click (instant AX)
//   cua click "Calculator" 176 317 --view V  # coordinate click (glide cursor)
//   cua type "TextEdit" "hello 世界" --element 4
//   cua key "Safari" cmd+t
//   cua scroll "Safari" 400 300 --direction down
//   cua drag "Finder" 100 100 400 100
//   cua open "Calculator"
//   cua openurl "https://example.com" [--app Safari]
//   cua policy [--allow X --deny Y]     # view / edit allowlist
//   cua start                           # pre-warm the helper
//   cua stop                            # stop the helper now (it also self-exits)

import { HelperClient, CUAError } from "./lib/client.mjs";
import { writeFileSync } from "node:fs";

const [, , cmd, ...rest] = process.argv;
const args = parseArgs(rest);

const client = new HelperClient();
client.approvalHandler = async (target) => {
  const policy = (process.env.OPENCUA_AUTO_APPROVE ?? "all").toLowerCase();
  if (policy === "none") return { allow: false };
  if (policy === "all") return { allow: true };
  return { allow: policy.split(",").map((s) => s.trim()).includes(target) };
};

function parseArgs(argv) {
  const out = { _: [] };
  // A token that looks like a flag itself — `--long` or `-s` — must never be
  // swallowed as the previous flag's value. A bare `-12` is a negative number,
  // not a flag, so it is allowed through as a value.
  const isFlag = (t) => /^--?[A-Za-z]/.test(t);
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a.startsWith("--")) {
      const key = a.slice(2);
      const next = argv[i + 1];
      if (next === undefined || isFlag(next)) out[key] = true;
      else { out[key] = next; i++; }
    } else if (a.startsWith("-") && a.length > 1 && !/^-\d/.test(a)) {
      // Short flag, possibly bundled (`-ab`). `cua shot <app> -o out.png` is in
      // the README, so these have to work, not just the long forms.
      const letters = a.slice(1).split("");
      const next = argv[i + 1];
      const takesValue = next !== undefined && !isFlag(next);
      for (let k = 0; k < letters.length; k++) {
        const isLast = k === letters.length - 1;
        if (isLast && takesValue) { out[letters[k]] = next; i++; }
        else out[letters[k]] = true;
      }
    } else out._.push(a);
  }
  return out;
}

function print(obj) {
  console.log(JSON.stringify(obj, null, 2));
}

async function main() {
  switch (cmd) {
    case "doctor": {
      const health = await client.call("health");
      print(health);
      if (!health.permissions?.all_granted) {
        console.error("\nPermissions incomplete. Open System Settings → Privacy & Security and grant:");
        console.error("  - 辅助功能 (Accessibility)  → \"OpenCUA Helper\"");
        console.error("  - 屏幕录制 (Screen Recording) → \"OpenCUA Helper\"");
        console.error("Then rerun `cua doctor`.");
      }
      break;
    }
    case "apps": {
      const res = await client.call("apps");
      if (args.json) { print(res); break; }
      const rows = (res.apps ?? []).map((a) => ({
        target_id: a.target_id,
        name: a.name,
        windows: a.window_count,
        state: a.compliance?.blocked ? "blocked" : (a.focused ? "focused" : (a.operable ? "" : "no-window")),
      }));
      const w = Math.max(9, ...rows.map((r) => r.target_id.length));
      for (const r of rows) {
        console.log(`${r.target_id.padEnd(w)}  ${r.name}${r.state ? "  [" + r.state + "]" : ""}`);
      }
      console.log(`\n${rows.length} apps`);
      break;
    }

    case "state": {
      const [target] = args._;
      if (!target) { console.error("usage: cua state <app>"); process.exit(2); }
      const res = await client.call("app.state", {
        target_id: target, with_view: !args["no-view"],
      });
      print(res);
      break;
    }

    case "shot": {
      const [target] = args._;
      if (!target) { console.error("usage: cua shot <app> [-o out.png]"); process.exit(2); }
      const res = await client.call("screen.shot", { target_id: target });
      if (res.png_base64) {
        const file = args.o ?? `shot-${Date.now()}.png`;
        writeFileSync(file, Buffer.from(res.png_base64, "base64"));
        console.log(`screenshot saved to ${file}`);
      } else print(res);
      break;
    }

    case "click": {
      const [target, a, b] = args._;
      const params = { target_id: target };
      if (args.element !== undefined) {
        params.state_id = args.state;
        params.element = Number(args.element);
      } else if (a !== undefined && b !== undefined) {
        params.view_id = args.view;
        params.coordinate = [Number(a), Number(b)];
      } else { console.error("usage: cua click <app> --element N --state S  |  cua click <app> x y --view V"); process.exit(2); }
      if (args.button) params.button = args.button;
      if (args.count) params.count = Number(args.count);
      print(await client.call("input.click", params));
      break;
    }

    case "type": {
      const [target, text] = args._;
      const params = { target_id: target, text };
      if (args.element !== undefined) { params.state_id = args.state; params.element = Number(args.element); }
      if (args.mode) params.mode = args.mode;
      print(await client.call("input.type", params));
      break;
    }

    case "key": {
      const [target] = args._;
      const keys = args._.slice(1).flatMap((s) => s.split("+"));
      print(await client.call("input.key", { target_id: target, keys }));
      break;
    }

    case "scroll": {
      const [target, x, y] = args._;
      const params = {
        target_id: target,
        coordinate: [Number(x ?? 0), Number(y ?? 0)],
        view_id: args.view,
        direction: args.direction ?? "down",
        pixels: Number(args.pixels ?? 300),
      };
      print(await client.call("input.scroll", params));
      break;
    }

    case "drag": {
      const [target, x1, y1, x2, y2] = args._;
      print(await client.call("input.drag", {
        target_id: target, view_id: args.view,
        from: [Number(x1), Number(y1)], to: [Number(x2), Number(y2)],
      }));
      break;
    }

    case "open": {
      const [app] = args._;
      print(await client.call("app.open", { app, hidden: !(args.show) }));
      break;
    }

    case "openurl": {
      const [url] = args._;
      print(await client.call("app.open_url", { url, app: args.app }));
      break;
    }

    case "policy": {
      if (args.allow) {
        print(await client.call("policy.set", { allow_add: [args.allow] }));
      } else if (args.deny) {
        print(await client.call("policy.set", { allow_remove: [args.deny] }));
      } else print(await client.call("policy.list"));
      break;
    }

    case "start": {
      await client.ensureRunning();
      print(await client.call("health"));
      break;
    }

    case "stop": {
      const stopped = await client.stop();
      print({ stopped, note: stopped ? "helper asked to exit" : "helper was not running" });
      return;
    }

    default:
      console.error(`OpenCUA CLI — commands: doctor apps state shot click type key scroll drag open openurl policy start stop`);
      process.exit(cmd ? 2 : 0);
  }
  client.close();
}

main().catch((err) => {
  if (err instanceof CUAError) console.error(`ERROR [${err.code}]: ${err.message}`);
  else console.error(err.stack ?? err.message);
  process.exit(1);
});
