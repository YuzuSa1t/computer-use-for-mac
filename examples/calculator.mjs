#!/usr/bin/env node
// Example: drive Calculator without touching the user's mouse or focus.
//
//   node examples/calculator.mjs 2026
//
// Demonstrates the intended shape of a computer-use task: open the app, read
// state, act on elements, verify by reading state again.

import { HelperClient } from "../server/lib/client.mjs";

const digits = (process.argv[2] ?? "520").replace(/[^0-9]/g, "").slice(0, 9);

const cua = new HelperClient();
cua.approvalHandler = async () => ({ allow: true });

try {
  // 1. Launch in the background. `hidden: true` means it will not take focus.
  await cua.call("app.open", { app: "Calculator", hidden: true });
  await sleep(600);

  // 2. Read the accessibility tree.
  let state = await cua.call("app.state", { target_id: "Calculator", with_view: false });
  const find = (label) =>
    state.tree.find((n) => n.role === "AXButton" && (n.id === label || n.desc === label || n.title === label));

  const clear = find("Clear") ?? find("AllClear");
  if (clear) await press(clear);

  // 3. Press one element per digit. Each press is a direct AX action, so it
  //    lands regardless of which app is frontmost.
  const names = ["Zero", "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine"];
  for (const d of digits) {
    const button = find(names[Number(d)]);
    if (!button) throw new Error(`button for "${d}" not found in the element tree`);
    await press(button);
  }

  // 4. Verify by re-reading state, never by assuming the presses landed.
  state = await cua.call("app.state", { target_id: "Calculator", with_view: false });
  const display = state.tree.find((n) => n.role === "AXStaticText");
  console.log(`display: ${display?.value ?? "(unknown)"}`);

  async function press(element) {
    await cua.call("input.click", {
      target_id: "Calculator",
      state_id: state.state_id,
      element: element.i,
    });
  }
} catch (err) {
  console.error(`${err.code ?? "ERROR"}: ${err.message}`);
  process.exitCode = 1;
} finally {
  cua.close();
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
