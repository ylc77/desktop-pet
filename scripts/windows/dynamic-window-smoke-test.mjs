import { execFileSync, spawn } from "node:child_process";
import { access, mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { createServer } from "node:net";
import { basename, dirname, isAbsolute, join, resolve } from "node:path";
import { tmpdir } from "node:os";
import WebSocket from "ws";

function readArguments(argv) {
  const values = new Map();
  for (let index = 0; index < argv.length; index += 2) {
    const key = argv[index];
    const value = argv[index + 1];
    if (!key?.startsWith("--") || !value) throw new Error(`Invalid argument near ${key ?? "end of command"}.`);
    values.set(key.slice(2), value);
  }
  const executable = values.get("executable");
  if (!executable) throw new Error("--executable is required.");
  const result = values.get("result");
  return {
    executable: isAbsolute(executable) ? executable : resolve(process.cwd(), executable),
    result: result ? (isAbsolute(result) ? result : resolve(process.cwd(), result)) : null,
  };
}

function delay(milliseconds) {
  return new Promise((resolveDelay) => setTimeout(resolveDelay, milliseconds));
}

async function reservePort() {
  const server = createServer();
  await new Promise((resolveListen, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolveListen);
  });
  const address = server.address();
  const port = typeof address === "object" && address ? address.port : null;
  await new Promise((resolveClose, reject) => server.close((error) => error ? reject(error) : resolveClose()));
  if (!port) throw new Error("Could not reserve a WebView2 diagnostics port.");
  return port;
}

function hasPreexistingProcess(executableName) {
  if (process.platform !== "win32") return false;
  const output = execFileSync("tasklist.exe", ["/FI", `IMAGENAME eq ${executableName}`, "/FO", "CSV", "/NH"], {
    encoding: "utf8",
    windowsHide: true,
  });
  const expected = `"${executableName}"`.toLocaleLowerCase("en-US");
  return output.split(/\r?\n/).some((line) => line.trim().toLocaleLowerCase("en-US").startsWith(expected));
}

function sanitizeFailureMessage(message) {
  return message
    .replace(/[A-Za-z]:\\[^\r\n"']+/g, "<local-path>")
    .replace(/[A-Za-z]:\/[^\r\n"']+/g, "<local-path>");
}

async function fetchTargets(port) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 2_000);
  try {
    const response = await fetch(`http://127.0.0.1:${port}/json/list`, { signal: controller.signal });
    if (!response.ok) throw new Error(`DevTools endpoint returned HTTP ${response.status}.`);
    return await response.json();
  } finally {
    clearTimeout(timeout);
  }
}

async function waitForMainTarget(port, child, timeoutMilliseconds = 30_000) {
  const deadline = Date.now() + timeoutMilliseconds;
  while (Date.now() < deadline) {
    if (child.exitCode !== null) throw new Error(`Application exited before WebView2 was ready (exitCode=${child.exitCode}).`);
    try {
      const targets = await fetchTargets(port);
      const main = targets.find((target) => target.type === "page" && target.url !== "about:blank");
      if (main) return main;
    } catch {
      // WebView2 has not opened the diagnostics endpoint yet.
    }
    await delay(250);
  }
  throw new Error("Main WebView2 target did not appear within 30 seconds.");
}

async function evaluate(target, expression, timeoutMilliseconds = 20_000) {
  const socket = new WebSocket(target.webSocketDebuggerUrl);
  let sequence = 0;
  const pending = new Map();
  socket.on("message", (data) => {
    const message = JSON.parse(data.toString());
    const request = pending.get(message.id);
    if (!request) return;
    pending.delete(message.id);
    if (message.error) request.reject(new Error(JSON.stringify(message.error)));
    else request.resolve(message.result);
  });
  await new Promise((resolveOpen, reject) => {
    socket.once("open", resolveOpen);
    socket.once("error", reject);
  });
  const request = (method, params = {}) => new Promise((resolveRequest, reject) => {
    const id = ++sequence;
    pending.set(id, { resolve: resolveRequest, reject });
    socket.send(JSON.stringify({ id, method, params }));
  });
  const timeout = new Promise((_, reject) => {
    setTimeout(() => reject(new Error("DevTools evaluation timed out.")), timeoutMilliseconds);
  });
  try {
    const response = await Promise.race([
      request("Runtime.evaluate", { expression, awaitPromise: true, returnByValue: true }),
      timeout,
    ]);
    if (response.exceptionDetails) throw new Error(response.exceptionDetails.text ?? "WebView evaluation failed.");
    return response.result?.value;
  } finally {
    socket.close();
  }
}

async function waitForSecondaryWindows(port, child, timeoutMilliseconds = 20_000) {
  const deadline = Date.now() + timeoutMilliseconds;
  let states = [];
  while (Date.now() < deadline) {
    if (child.exitCode !== null) throw new Error(`Application exited while opening secondary windows (exitCode=${child.exitCode}).`);
    const targets = await fetchTargets(port);
    states = [];
    for (const target of targets.filter((candidate) => candidate.type === "page")) {
      try {
        const value = await evaluate(target, `JSON.stringify({
          url: location.href,
          title: document.title,
          ready: document.readyState,
          rootChildren: document.getElementById('root')?.childElementCount || 0,
          bodyText: (document.body?.innerText || '').slice(0, 2000)
        })`, 5_000);
        states.push({
          targetId: target.id,
          webSocketDebuggerUrl: target.webSocketDebuggerUrl,
          targetUrl: target.url,
          targetTitle: target.title,
          ...JSON.parse(value),
        });
      } catch {
        // A target may be replaced while WebView2 is navigating; retry the full set.
      }
    }
    const settings = states.find((state) => state.bodyText.includes("七酱桌宠设置"));
    const appearance = states.find((state) => state.bodyText.includes("外观中心"));
    if (settings?.ready === "complete" && settings.rootChildren > 0 && appearance?.ready === "complete" && appearance.rootChildren > 0) {
      return { states, settings, appearance };
    }
    await delay(250);
  }
  return { states, settings: null, appearance: null };
}

async function waitForTargetClosed(port, targetId, child, timeoutMilliseconds = 5_000) {
  const deadline = Date.now() + timeoutMilliseconds;
  while (Date.now() < deadline) {
    if (child.exitCode !== null) throw new Error(`Application exited while closing a secondary window (exitCode=${child.exitCode}).`);
    const targets = await fetchTargets(port);
    if (!targets.some((target) => target.id === targetId)) return true;
    await delay(100);
  }
  return false;
}

async function stopChild(child, executableName) {
  if (child && child.exitCode === null && child.signalCode === null) {
    child.kill();
    const exited = await Promise.race([
      new Promise((resolveExit) => child.once("exit", () => resolveExit(true))),
      delay(5_000).then(() => false),
    ]);
    if (!exited && process.platform === "win32") {
      execFileSync("taskkill.exe", ["/PID", String(child.pid), "/T", "/F"], { stdio: "ignore", windowsHide: true });
    }
  }
  if (process.platform !== "win32" || !executableName) {
    return Boolean(child && child.exitCode === null && child.signalCode === null);
  }
  const deadline = Date.now() + 5_000;
  while (Date.now() < deadline) {
    if (!hasPreexistingProcess(executableName)) return false;
    await delay(100);
  }
  return hasPreexistingProcess(executableName);
}

const result = {
  schemaVersion: 1,
  executable: null,
  status: "failed",
  commandsResolved: false,
  settingsRendered: false,
  appearanceRendered: false,
  settingsClosed: false,
  appearanceClosed: false,
  aboutBlankTargetCount: null,
  processSurvived: false,
  processRemainingAfterCleanup: false,
};

let child = null;
let profileRoot = null;
let outputPath = null;
let exitCode = 2;
try {
  const options = readArguments(process.argv.slice(2));
  outputPath = options.result;
  result.executable = basename(options.executable);
  await access(options.executable);
  if (hasPreexistingProcess(result.executable)) {
    throw new Error(`Dynamic window smoke test requires no pre-existing '${result.executable}' process.`);
  }
  const port = await reservePort();
  profileRoot = await mkdtemp(join(tmpdir(), "qijiang-dynamic-window-smoke-"));
  await Promise.all([
    mkdir(join(profileRoot, "AppData"), { recursive: true }),
    mkdir(join(profileRoot, "LocalAppData"), { recursive: true }),
    mkdir(join(profileRoot, "Temp"), { recursive: true }),
  ]);
  const browserArguments = (process.env.WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS ?? "")
    .replace(/--remote-debugging-port=\S+/g, "")
    .trim();
  const environment = {
    ...process.env,
    APPDATA: join(profileRoot, "AppData"),
    LOCALAPPDATA: join(profileRoot, "LocalAppData"),
    TEMP: join(profileRoot, "Temp"),
    TMP: join(profileRoot, "Temp"),
    WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS: `${browserArguments} --remote-debugging-port=${port} --remote-allow-origins=*`.trim(),
  };
  child = spawn(options.executable, [], {
    cwd: dirname(options.executable),
    env: environment,
    stdio: "ignore",
    windowsHide: true,
  });
  const main = await waitForMainTarget(port, child);
  const commandResult = await evaluate(main, `(async () => {
    const startedAt = Date.now();
    await window.__TAURI_INTERNALS__.invoke('show_settings_window', { section: 'general' });
    const settingsResolvedMilliseconds = Date.now() - startedAt;
    const appearanceStartedAt = Date.now();
    await window.__TAURI_INTERNALS__.invoke('show_appearance_window');
    return JSON.stringify({
      settingsResolvedMilliseconds,
      appearanceResolvedMilliseconds: Date.now() - appearanceStartedAt
    });
  })()`, 30_000);
  result.commandTimings = JSON.parse(commandResult);
  result.commandsResolved = true;
  const windows = await waitForSecondaryWindows(port, child);
  result.settingsRendered = Boolean(windows.settings);
  result.appearanceRendered = Boolean(windows.appearance);
  result.settingsUrl = windows.settings?.url ?? null;
  result.appearanceUrl = windows.appearance?.url ?? null;
  result.aboutBlankTargetCount = windows.states.filter((state) => state.url === "about:blank" || state.targetUrl === "about:blank").length;
  result.processSurvived = child.exitCode === null;
  if (!result.settingsRendered || !result.appearanceRendered || result.aboutBlankTargetCount !== 0 || !result.processSurvived) {
    throw new Error("Secondary WebView2 windows did not render usable application content.");
  }
  await evaluate(windows.settings, `(() => {
    void window.__TAURI_INTERNALS__.invoke('plugin:window|close', { label: 'settings' });
    return true;
  })()`);
  result.settingsClosed = await waitForTargetClosed(port, windows.settings.targetId, child);
  await evaluate(windows.appearance, `(() => {
    void window.__TAURI_INTERNALS__.invoke('plugin:window|close', { label: 'appearance' });
    return true;
  })()`);
  result.appearanceClosed = await waitForTargetClosed(port, windows.appearance.targetId, child);
  if (!result.settingsClosed || !result.appearanceClosed || child.exitCode !== null) {
    throw new Error("Secondary windows did not close through their native close-request path while the application remained running.");
  }
  result.status = "passed";
  exitCode = 0;
} catch (error) {
  result.failureCategory = error instanceof Error ? error.constructor.name : "UnknownError";
  result.failureMessage = sanitizeFailureMessage(error instanceof Error ? error.message : String(error));
} finally {
  result.processRemainingAfterCleanup = await stopChild(child, result.executable).catch(() => true);
  if (result.processRemainingAfterCleanup) {
    result.status = "failed";
    result.failureCategory ??= "CleanupError";
    result.failureMessage ??= "Application process remained after smoke-test cleanup.";
    exitCode = 2;
  }
  if (profileRoot) await rm(profileRoot, { recursive: true, force: true }).catch(() => undefined);
  if (outputPath) {
    await mkdir(dirname(outputPath), { recursive: true });
    await writeFile(outputPath, `${JSON.stringify(result, null, 2)}\n`, "utf8");
  }
  process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
}

process.exit(exitCode);
