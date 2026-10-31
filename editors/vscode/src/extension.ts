// The VS Code client for the slang language server: starts
// `slang run <extension>/lsp/main.slang <extension>` in the workspace folder
// (trusted workspaces only), maps its semantic tokens, and associates the
// project's dialect suffixes with the slang language. Besides the server's
// features: the tests in the test explorer (found by the server, run with
// `slang test --json`), a view of a file's expanded code, commands to run a
// file, use a REPL, fetch packages and build, a `slang` task type, and the
// debugger (the VM speaks the Debug Adapter Protocol on a local port: see
// `slang run --debug`).
import { spawn } from "child_process";
import * as net from "net";
import * as path from "path";
import * as vscode from "vscode";
import { LanguageClient, LanguageClientOptions, ServerOptions } from "vscode-languageclient/node";

let client: LanguageClient | undefined;

export async function activate(context: vscode.ExtensionContext): Promise<void> {
  if (vscode.workspace.isTrusted) {
    await start(context);
  } else {
    context.subscriptions.push(vscode.workspace.onDidGrantWorkspaceTrust(() => start(context)));
  }
}

// the slang binary (slang.path, with ${workspaceFolder} expanded) and the folder
function slangCommand(): { command: string; folder: string } {
  const config = vscode.workspace.getConfiguration("slang");
  const folder = vscode.workspace.workspaceFolders?.[0]?.uri.fsPath ?? process.cwd();
  // ${workspaceFolder} is not expanded by VS Code in extension settings
  const command = config.get<string>("path", "slang").replace("${workspaceFolder}", folder);
  return { command, folder };
}

// ------------------------------------------------------------ terminals

function quote(arg: string): string {
  return /^[A-Za-z0-9_\/.=:-]+$/.test(arg) ? arg : `'${arg.replace(/'/g, "'\\''")}'`;
}

function terminal(name: string, cwd: string): vscode.Terminal {
  const existing = vscode.window.terminals.find((t) => t.name === name);
  return existing ?? vscode.window.createTerminal({ name, cwd });
}

// runs slang with args in the terminal "slang", in the folder of the
// project the active file belongs to (else the workspace folder)
function runInTerminal(args: string[], cwd?: string): void {
  const { command, folder } = slangCommand();
  const t = terminal("slang", cwd ?? folder);
  t.show();
  t.sendText([command, ...args].map(quote).join(" "));
}

async function projectFolder(): Promise<string | undefined> {
  const { folder } = slangCommand();
  const file = vscode.window.activeTextEditor?.document.uri.fsPath;
  let dir = file ? path.dirname(file) : folder;
  for (;;) {
    try {
      await vscode.workspace.fs.stat(vscode.Uri.file(path.join(dir, "slang.project")));
      return dir;
    } catch {
      const parent = path.dirname(dir);
      if (parent === dir) {
        return undefined;
      }
      dir = parent;
    }
  }
}

function registerCommands(context: vscode.ExtensionContext): void {
  const reg = (name: string, f: (...args: any[]) => unknown) =>
    context.subscriptions.push(vscode.commands.registerCommand(name, f));
  reg("slang.runFile", async () => {
    const doc = vscode.window.activeTextEditor?.document;
    if (!doc) {
      return;
    }
    await doc.save();
    runInTerminal(["run", doc.uri.fsPath]);
  });
  reg("slang.debugFile", async () => {
    const doc = vscode.window.activeTextEditor?.document;
    if (!doc) {
      return;
    }
    await doc.save();
    await vscode.debug.startDebugging(vscode.workspace.getWorkspaceFolder(doc.uri), {
      type: "slang",
      request: "launch",
      name: `Debug ${path.basename(doc.uri.fsPath)}`,
      program: doc.uri.fsPath,
    });
  });
  reg("slang.repl", () => {
    const { command, folder } = slangCommand();
    const t = terminal("slang repl", folder);
    t.show();
    if (!replStarted.has(t)) {
      replStarted.add(t);
      t.sendText(`${quote(command)} repl`);
    }
  });
  reg("slang.sendToRepl", async () => {
    const editor = vscode.window.activeTextEditor;
    if (!editor) {
      return;
    }
    const text = editor.selection.isEmpty
      ? editor.document.lineAt(editor.selection.active.line).text
      : editor.document.getText(editor.selection);
    await vscode.commands.executeCommand("slang.repl");
    const t = terminal("slang repl", slangCommand().folder);
    // the REPL reads a line at a time
    for (const line of text.split(/\r?\n/)) {
      if (line.trim().length > 0) {
        t.sendText(line);
      }
    }
  });
  for (const [name, args] of [
    ["slang.get", ["get"]],
    ["slang.update", ["update"]],
    ["slang.build", ["build"]],
    ["slang.buildDir", ["build", "--dir"]],
  ] as [string, string[]][]) {
    reg(name, async () => {
      const dir = await projectFolder();
      if (!dir) {
        vscode.window.showErrorMessage("slang: no slang.project above this file");
        return;
      }
      runInTerminal(args, dir);
    });
  }
  reg("slang.showExpanded", async () => {
    const doc = vscode.window.activeTextEditor?.document;
    if (!doc || doc.languageId !== "slang") {
      return;
    }
    const uri = expandedUri(doc.uri);
    const shown = await vscode.workspace.openTextDocument(uri);
    await vscode.languages.setTextDocumentLanguage(shown, "slang");
    await vscode.window.showTextDocument(shown, { viewColumn: vscode.ViewColumn.Beside, preview: true });
  });
}

const replStarted = new WeakSet<vscode.Terminal>();

// ------------------------------------------------------------ expanded code

const EXPANDED = "slang-expanded";

function expandedUri(source: vscode.Uri): vscode.Uri {
  return vscode.Uri.from({
    scheme: EXPANDED,
    path: source.path.replace(/(\.[^./]*)?$/, ".expanded.slang"),
    query: source.toString(),
  });
}

class ExpandedProvider implements vscode.TextDocumentContentProvider {
  readonly changed = new vscode.EventEmitter<vscode.Uri>();
  readonly onDidChange = this.changed.event;

  async provideTextDocumentContent(uri: vscode.Uri): Promise<string> {
    if (!client) {
      return "// the slang language server is not running";
    }
    const r = await client.sendRequest<{ text?: string; error?: string }>("slang/expand", { uri: uri.query });
    return r.text ?? `// cannot expand the file: ${r.error}`;
  }
}

// ------------------------------------------------------------ tests

type TestNode = {
  kind: "group" | "test";
  name: string;
  range: { start: { line: number; character: number }; end: { line: number; character: number } };
  children: TestNode[];
};

// the test items of a file, from the server's view of its groups and tests
async function loadTests(controller: vscode.TestController, file: vscode.TestItem): Promise<void> {
  if (!client || !file.uri) {
    return;
  }
  const r = await client.sendRequest<{ tests: TestNode[] }>("slang/tests", { uri: file.uri.toString() });
  const make = (node: TestNode, parentId: string): vscode.TestItem => {
    const id = `${parentId} / ${node.name}`;
    const item = controller.createTestItem(id, node.name, file.uri);
    item.range = new vscode.Range(
      node.range.start.line,
      node.range.start.character,
      node.range.end.line,
      node.range.end.character
    );
    item.children.replace(node.children.map((c) => make(c, id)));
    return item;
  };
  file.children.replace(r.tests.map((t) => make(t, file.id)));
}

function testFile(controller: vscode.TestController, uri: vscode.Uri): vscode.TestItem {
  const existing = controller.items.get(uri.toString());
  if (existing) {
    return existing;
  }
  const item = controller.createTestItem(uri.toString(), path.basename(uri.fsPath), uri);
  item.canResolveChildren = true;
  controller.items.add(item);
  return item;
}

function isTestFile(uri: vscode.Uri): boolean {
  return uri.scheme === "file" && uri.fsPath.endsWith("test.slang");
}

// the path of an item below its file, as slang test --only takes it
function testPath(item: vscode.TestItem): string[] {
  const names: string[] = [];
  let it: vscode.TestItem | undefined = item;
  while (it?.parent) {
    names.unshift(it.label);
    it = it.parent;
  }
  return names;
}

function fileOf(item: vscode.TestItem): vscode.TestItem {
  let it = item;
  while (it.parent) {
    it = it.parent;
  }
  return it;
}

type TestEvent = {
  event: "test" | "done";
  path?: string[];
  status?: "passed" | "failed";
  message?: string;
  location?: { origin: string; line: number; column: number };
};

async function runTests(
  controller: vscode.TestController,
  request: vscode.TestRunRequest,
  token: vscode.CancellationToken
): Promise<void> {
  const run = controller.createTestRun(request);
  const queue: vscode.TestItem[] = [];
  if (request.include) {
    queue.push(...request.include);
  } else {
    controller.items.forEach((item) => queue.push(item));
  }
  const { command, folder } = slangCommand();
  for (const item of queue) {
    if (token.isCancellationRequested) {
      break;
    }
    const file = fileOf(item);
    if (file.children.size === 0) {
      await loadTests(controller, file);
    }
    // every item under the one run, by its path
    const byPath = new Map<string, vscode.TestItem>();
    const collect = (it: vscode.TestItem) => {
      byPath.set(testPath(it).join(" / "), it);
      run.enqueued(it);
      it.children.forEach(collect);
    };
    collect(item);
    const args = ["test", "--json"];
    const only = testPath(item).join(" / ");
    if (only) {
      args.push("--only", only);
    }
    args.push(file.uri!.fsPath);
    await new Promise<void>((resolve) => {
      const child = spawn(command, args, { cwd: folder });
      token.onCancellationRequested(() => child.kill());
      let buffer = "";
      const onLine = (line: string) => {
        if (!line.startsWith("{")) {
          run.appendOutput(line + "\r\n");
          return;
        }
        let e: TestEvent;
        try {
          e = JSON.parse(line);
        } catch {
          run.appendOutput(line + "\r\n");
          return;
        }
        if (e.event !== "test" || !e.path) {
          return;
        }
        const it = byPath.get(e.path.join(" / "));
        if (!it) {
          return;
        }
        if (e.status === "passed") {
          run.passed(it);
        } else {
          const message = new vscode.TestMessage(e.message ?? "failed");
          if (e.location && it.uri) {
            const where = path.isAbsolute(e.location.origin)
              ? vscode.Uri.file(e.location.origin)
              : vscode.Uri.file(path.join(folder, e.location.origin));
            const pos = new vscode.Position(Math.max(0, e.location.line - 1), Math.max(0, e.location.column - 1));
            message.location = new vscode.Location(where, pos);
          }
          run.failed(it, message);
        }
      };
      child.stdout.on("data", (chunk: Buffer) => {
        buffer += chunk.toString();
        let nl: number;
        while ((nl = buffer.indexOf("\n")) >= 0) {
          onLine(buffer.slice(0, nl));
          buffer = buffer.slice(nl + 1);
        }
      });
      child.stderr.on("data", (chunk: Buffer) => run.appendOutput(chunk.toString().replace(/\n/g, "\r\n")));
      child.on("error", (err) => {
        run.appendOutput(`cannot run ${command}: ${err.message}\r\n`);
        resolve();
      });
      child.on("close", () => {
        if (buffer) {
          onLine(buffer);
        }
        resolve();
      });
    });
  }
  run.end();
}

function startTests(context: vscode.ExtensionContext): void {
  const controller = vscode.tests.createTestController("slang", "slang");
  context.subscriptions.push(controller);
  controller.resolveHandler = async (item) => {
    if (!item) {
      for (const uri of await vscode.workspace.findFiles("**/*test.slang", "**/{node_modules,zig-out,.zig-cache}/**")) {
        testFile(controller, uri);
      }
      return;
    }
    await loadTests(controller, item);
  };
  controller.createRunProfile("Run", vscode.TestRunProfileKind.Run, (request, token) =>
    runTests(controller, request, token), true);
  // debugging a test runs its file's tests under the debugger, --only it
  controller.createRunProfile("Debug", vscode.TestRunProfileKind.Debug, async (request) => {
    const item = request.include?.[0];
    if (!item) {
      return;
    }
    const file = fileOf(item);
    const only = testPath(item).join(" / ");
    await vscode.debug.startDebugging(undefined, {
      type: "slang",
      request: "launch",
      name: `Debug ${only || file.label}`,
      command: "test",
      program: file.uri!.fsPath,
      args: only ? ["--only", only] : [],
    });
  });
  const refresh = (doc: vscode.TextDocument) => {
    if (isTestFile(doc.uri)) {
      loadTests(controller, testFile(controller, doc.uri));
    }
  };
  context.subscriptions.push(
    vscode.workspace.onDidOpenTextDocument(refresh),
    vscode.workspace.onDidSaveTextDocument(refresh)
  );
  vscode.workspace.textDocuments.forEach(refresh);
}

// ------------------------------------------------------------ debugging

// a port no one listens on
function freePort(): Promise<number> {
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    server.on("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const port = (server.address() as net.AddressInfo).port;
      server.close(() => resolve(port));
    });
  });
}

// starts the program with --debug (SLANG_DEBUG for `slang test`), its output
// in the debug console, and connects once it listens
class DebugAdapterFactory implements vscode.DebugAdapterDescriptorFactory {
  async createDebugAdapterDescriptor(session: vscode.DebugSession): Promise<vscode.DebugAdapterDescriptor> {
    const config = session.configuration;
    const { command, folder } = slangCommand();
    const port = await freePort();
    const verb: string = config.command ?? "run";
    const args = verb === "run"
      ? ["run", "--debug", String(port), config.program, ...(config.args ?? [])]
      : [verb, ...(config.args ?? []), config.program];
    const child = spawn(command, args, {
      cwd: config.cwd ?? folder,
      env: verb === "run" ? process.env : { ...process.env, SLANG_DEBUG: String(port) },
    });
    const console = vscode.debug.activeDebugConsole;
    await new Promise<void>((resolve, reject) => {
      let listening = false;
      child.stdout.on("data", (chunk: Buffer) => vscode.debug.activeDebugConsole.append(chunk.toString()));
      child.stderr.on("data", (chunk: Buffer) => {
        const text = chunk.toString();
        if (!listening && text.includes("waiting for a debugger")) {
          listening = true;
          resolve();
          return;
        }
        vscode.debug.activeDebugConsole.append(text);
      });
      child.on("error", (err) => reject(new Error(`cannot start ${command}: ${err.message}`)));
      child.on("exit", (code) => {
        if (!listening) {
          reject(new Error(`slang ended (code ${code}) before the debugger could connect`));
        }
      });
    });
    console.appendLine("");
    return new vscode.DebugAdapterServer(port, "127.0.0.1");
  }
}

function startDebugging(context: vscode.ExtensionContext): void {
  context.subscriptions.push(
    vscode.debug.registerDebugAdapterDescriptorFactory("slang", new DebugAdapterFactory()),
    vscode.debug.registerDebugConfigurationProvider("slang", {
      // F5 without a launch.json: the current file
      resolveDebugConfiguration(_folder, config) {
        if (!config.type && !config.request) {
          const doc = vscode.window.activeTextEditor?.document;
          if (doc?.languageId !== "slang") {
            return undefined;
          }
          return { type: "slang", request: "launch", name: "Debug the current file", program: doc.uri.fsPath };
        }
        return config;
      },
    })
  );
}

// ------------------------------------------------------------ tasks

type SlangTask = vscode.TaskDefinition & { command: string; args?: string[] };

function taskOf(def: SlangTask, scope: vscode.WorkspaceFolder | vscode.TaskScope): vscode.Task {
  const { command } = slangCommand();
  const task = new vscode.Task(
    def,
    scope,
    [def.command, ...(def.args ?? [])].join(" "),
    "slang",
    new vscode.ProcessExecution(command, [def.command, ...(def.args ?? [])]),
    ["$slang", "$slang-test"]
  );
  if (def.command === "build") {
    task.group = vscode.TaskGroup.Build;
  } else if (def.command === "test") {
    task.group = vscode.TaskGroup.Test;
  }
  return task;
}

function startTasks(context: vscode.ExtensionContext): void {
  context.subscriptions.push(
    vscode.tasks.registerTaskProvider("slang", {
      provideTasks: () => {
        const folder = vscode.workspace.workspaceFolders?.[0];
        if (!folder) {
          return [];
        }
        return [
          taskOf({ type: "slang", command: "test" }, folder),
          taskOf({ type: "slang", command: "build" }, folder),
          taskOf({ type: "slang", command: "build", args: ["--dir"] }, folder),
        ];
      },
      resolveTask: (task) => {
        const def = task.definition as SlangTask;
        return def.command ? taskOf(def, task.scope ?? vscode.TaskScope.Workspace) : undefined;
      },
    })
  );
}

async function start(context: vscode.ExtensionContext): Promise<void> {
  if (client) {
    return;
  }
  const config = vscode.workspace.getConfiguration("slang");
  const folder = vscode.workspace.workspaceFolders?.[0]?.uri.fsPath ?? process.cwd();
  // ${workspaceFolder} is not expanded by VS Code in extension settings
  const command = config.get<string>("path", "slang").replace("${workspaceFolder}", folder);
  const serverOptions: ServerOptions = {
    command,
    args: ["run", path.join(context.extensionPath, "lsp", "main.slang"), context.extensionPath],
    options: { cwd: folder },
  };
  const clientOptions: LanguageClientOptions = {
    documentSelector: [{ language: "slang" }],
    synchronize: {
      fileEvents: vscode.workspace.createFileSystemWatcher("**/slang.project"),
    },
    outputChannelName: "slang",
    initializationOptions: {
      parameterHints: config.get<string>("parameterHints", "literals"),
      lint: config.get<boolean>("lint", true),
    },
  };
  client = new LanguageClient("slang", "slang language server", serverOptions, clientOptions);
  registerCommands(context);
  startTasks(context);
  startDebugging(context);
  // the expanded view follows the file it shows
  const expanded = new ExpandedProvider();
  context.subscriptions.push(
    vscode.workspace.registerTextDocumentContentProvider(EXPANDED, expanded),
    vscode.workspace.onDidChangeTextDocument((e) => {
      const uri = expandedUri(e.document.uri);
      if (vscode.workspace.textDocuments.some((d) => d.uri.toString() === uri.toString())) {
        expanded.changed.fire(uri);
      }
    })
  );
  client.onNotification("slang/project", (params: { path: string; dialects: string[] }) => {
    associateDialects(params.dialects);
  });
  context.subscriptions.push({ dispose: () => client?.stop() });
  try {
    await client.start();
    startTests(context);
  } catch (e) {
    vscode.window.showErrorMessage(
      `slang: could not start the language server with "${command}" (set slang.path to the slang binary): ${e}`
    );
  }
}

// files.associations gets "*.<suffix>": "slang" for every dialect suffix
async function associateDialects(dialects: string[]): Promise<void> {
  const config = vscode.workspace.getConfiguration("slang");
  if (!config.get<boolean>("associateDialects", true) || dialects.length === 0) {
    return;
  }
  const files = vscode.workspace.getConfiguration("files");
  const current = { ...(files.get<Record<string, string>>("associations") ?? {}) };
  let changed = false;
  for (const suffix of dialects) {
    const pattern = `*${suffix}`;
    if (suffix !== ".slang" && current[pattern] !== "slang") {
      current[pattern] = "slang";
      changed = true;
    }
  }
  if (changed) {
    await files.update("associations", current, vscode.ConfigurationTarget.Workspace);
  }
}

export function deactivate(): Thenable<void> | undefined {
  const c = client;
  client = undefined;
  return c?.stop();
}
