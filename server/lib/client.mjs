#!/usr/bin/env node
// OpenCUA helper client — connects to (and lazily spawns) the OpenCUA Helper
// over a Unix-domain socket, speaking newline-delimited JSON-RPC.
//
// Zero dependencies by design: works on any machine with Node >= 18,
// no install step, no network access.

import { spawn } from "node:child_process";
import { existsSync, mkdirSync } from "node:fs";
import { homedir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

export const SOCKET_PATH = path.join(homedir(), ".opencua", "helper.sock");

const HERE = path.dirname(fileURLToPath(import.meta.url));

const HELPER_CANDIDATES = [
  process.env.OPENCUA_HELPER,
  path.join(homedir(), ".opencua", "bin", "OpenCUA Helper.app", "Contents", "MacOS", "opencua-helper"),
  path.resolve(HERE, "..", "..", "dist", "OpenCUA Helper.app", "Contents", "MacOS", "opencua-helper"),
].filter(Boolean);

export class HelperClient {
  constructor() {
    this.socket = null;
    this.nextId = 1;
    this.pending = new Map();      // id -> {resolve, reject, timer}
    this.approvalHandler = null;  // async (target) => boolean
    this.buffer = "";
    this.lifecycleSynced = false; // lifetime policy pushed to the current helper
  }

  async ensureRunning() {
    if (await this.probe()) return true;
    for (const bin of HELPER_CANDIDATES) {
      if (!existsSync(bin)) continue;
      try {
        const child = spawn(bin, [], { detached: true, stdio: "ignore" });
        child.unref();
        await sleep(700);
        if (await this.probe()) return true;
        // last resort: the helper may be slow; retry a few times
        for (let i = 0; i < 5; i++) {
          await sleep(500);
          if (await this.probe()) return true;
        }
      } catch (err) {
        process.stderr.write(`[opencua] failed to launch helper: ${err.message}\n`);
      }
    }
    throw new Error(
      "OpenCUA Helper not running and not found. Build it with `scripts/build.sh` " +
      "or set OPENCUA_HELPER to the helper binary path."
    );
  }

  async probe() {
    try {
      // raw call — must NOT re-enter ensureRunning
      const res = await this._call("health", {}, { timeoutMs: 1500 });
      return res?.ok === true;
    } catch {
      return false;
    }
  }

  connect() {
    // deprecated no-op kept for API stability; use call()
    return this.socket;
  }

  async _getSocket() {
    if (this.socket) return this.socket;
    const { default: net } = await import("node:net");
    return await new Promise((resolve, reject) => {
      const sock = net.createConnection(SOCKET_PATH);
      sock.setNoDelay(true);
      sock.on("connect", () => {
        this.socket = sock;
        sock.on("data", (chunk) => this._onData(chunk));
        sock.on("error", (err) => this._onError(err));
        sock.on("close", () => this._onClose());
        resolve(sock);
      });
      sock.on("error", (err) => reject(err));
    });
  }

  _onData(chunk) {
    this.buffer += chunk.toString("utf8");
    let idx;
    while ((idx = this.buffer.indexOf("\n")) >= 0) {
      const line = this.buffer.slice(0, idx);
      this.buffer = this.buffer.slice(idx + 1);
      if (!line.trim()) continue;
      let msg;
      try { msg = JSON.parse(line); } catch { continue; }
      this._onMessage(msg);
    }
  }

  _onMessage(msg) {
    // server-initiated request (approval flow)
    if (msg.method === "approval.request") {
      const target = msg.params?.target;
      if (this.approvalHandler && target) {
        this.approvalHandler(target)
          .then((decision) => this.notify("approval.respond", {
            target, allow: decision.allow, always: decision.always === true,
          }))
          .catch(() => this.notify("approval.respond", { target, allow: false }));
      } else {
        // no handler: deny by default (safety-first; MCP server installs a handler)
        this.notify("approval.respond", { target, allow: false });
      }
      return;
    }
    if (msg.id !== undefined && this.pending.has(msg.id)) {
      const entry = this.pending.get(msg.id);
      this.pending.delete(msg.id);
      clearTimeout(entry.timer);
      if (msg.ok) entry.resolve(msg.result);
      else entry.reject(new CUAError(msg.error?.code || "ERROR", msg.error?.message || "helper error"));
    }
  }

  _onError(err) {
    for (const [, entry] of this.pending) {
      entry.reject(new CUAError("SOCKET", err.message));
    }
    this.pending.clear();
    this.socket = null;
    this.lifecycleSynced = false;
  }

  _onClose() {
    for (const [, entry] of this.pending) {
      entry.reject(new CUAError("SOCKET_CLOSED", "helper socket closed"));
    }
    this.pending.clear();
    this.socket = null;
    this.lifecycleSynced = false;
  }

  async call(method, params = {}, { timeoutMs = 120000, quiet = false } = {}) {
    await this.ensureRunning();
    await this.syncLifecycle();
    return this._call(method, params, { timeoutMs, quiet });
  }

  /// Push this process's policy to a (possibly reused) helper, so that
  /// OPENCUA_EXIT_GRACE / OPENCUA_IDLE_TIMEOUT / OPENCUA_CURSOR /
  /// OPENCUA_ANNOUNCE take effect even when the helper was originally spawned
  /// by a different client. A helper's own environment is fixed at spawn time,
  /// so anything set on a later process would otherwise be silently ignored.
  async syncLifecycle() {
    if (this.lifecycleSynced) return;
    this.lifecycleSynced = true;
    const grace = Number(process.env.OPENCUA_EXIT_GRACE ?? 20);
    const idle = Number(process.env.OPENCUA_IDLE_TIMEOUT ?? 900);
    if (!Number.isFinite(grace) || !Number.isFinite(idle)) return;
    const payload = { exit_grace: grace, idle_seconds: idle };
    if (process.env.OPENCUA_CURSOR !== undefined) {
      payload.cursor = process.env.OPENCUA_CURSOR !== "0";
    }
    if (process.env.OPENCUA_ANNOUNCE !== undefined) {
      payload.announce = process.env.OPENCUA_ANNOUNCE !== "0";
    }
    // The announcement is a pill with a sentence in it, so its language matters
    // independently of the OS locale: a person reading Chinese UI may still run
    // their shell in English.
    if (process.env.OPENCUA_LANG) {
      payload.lang = process.env.OPENCUA_LANG;
    }
    try {
      await this._call("lifecycle.set", payload, { timeoutMs: 3000 });
    } catch {
      // older helper without lifecycle.set — harmless
    }
  }

  async _call(method, params = {}, { timeoutMs = 120000, quiet = false } = {}) {
    const sock = await this._getSocket();
    const id = this.nextId++;
    return await new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new CUAError("TIMEOUT", `${method} timed out after ${timeoutMs}ms`));
      }, timeoutMs);
      this.pending.set(id, { resolve, reject, timer });
      const line = JSON.stringify({ id, method, params }) + "\n";
      sock.write(line, (err) => {
        if (err) {
          this.pending.delete(id);
          clearTimeout(timer);
          reject(new CUAError("SOCKET", err.message));
        }
      });
    });
  }

  async notify(method, params = {}) {
    try {
      const sock = await this._getSocket();
      sock.write(JSON.stringify({ method, params }) + "\n");
    } catch (err) {
      if (!quiet) process.stderr.write(`[opencua] notify failed: ${err.message}\n`);
    }
  }

  close() {
    if (this.socket) {
      this.socket.destroy();
      this.socket = null;
    }
  }

  /**
   * Ask the helper to shut itself down and release the socket.
   *
   * Never spawns a helper: if none is running this is a no-op. Returns true when
   * a live helper was asked to stop. The helper also exits on its own once the
   * last client disconnects, so calling this is an optimisation, not a duty.
   */
  async stop() {
    if (!(await this.probe())) {
      this.close();
      return false;
    }
    try {
      await this._call("shutdown", {}, { timeoutMs: 3000 });
    } catch {
      // the socket may already be torn down before the reply lands — fine
    }
    this.close();
    return true;
  }
}

export class CUAError extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
    this.name = "CUAError";
  }
}

export function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

export function resultToText(result) {
  return JSON.stringify(result, null, 2);
}
