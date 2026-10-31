// The VS Code client for the slang language server: starts
// `slang run <extension>/lsp/main.slang <extension>` in the workspace folder
// (trusted workspaces only), maps its semantic tokens, and associates the
// project's dialect suffixes with the slang language.
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
  client.onNotification("slang/project", (params: { path: string; dialects: string[] }) => {
    associateDialects(params.dialects);
  });
  context.subscriptions.push({ dispose: () => client?.stop() });
  try {
    await client.start();
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
