# claude-code-sandbox-darwin-nix

Nix flake that runs [Claude Code](https://claude.ai/code) inside a
macOS `sandbox-exec` sandbox, with a nix-darwin module for declarative
installation.

## What it does

- Restricts filesystem access to the project directory, Nix store,
  and system paths using a macOS Seatbelt sandbox profile.
- Protects `.git` directories from writes, preventing the AI agent
  from rewriting git history (override with
  `CLAUDE_CODE_SANDBOX_UNSAFE_RW_GIT=1`).
- Optionally integrates [Serena](https://github.com/oraios/serena) as
  an MCP server for LSP-powered code navigation (enabled by default).
- Generates a dynamic preamble (system info, directory tree, recent
  commits) injected as supplemental system prompt context.
- Declaratively manages MCP servers, extra packages, and environment
  variables via nix-darwin options.

## Quick start

Add the flake to your nix-darwin configuration:

```nix
# flake.nix
{
  inputs.claude-code-sandbox.url = "github:hlolli/claude-code-sandbox-darwin-nix";

  outputs = { self, darwin, claude-code-sandbox, ... }: {
    darwinConfigurations."my-mac" = darwin.lib.darwinSystem {
      system = "aarch64-darwin";
      modules = [
        claude-code-sandbox.darwinModules.default
        {
          programs.claude-code-sandbox = {
            enable = true;
            extraFwdEnv = [ "ANTHROPIC_API_KEY" ];
          };
        }
      ];
    };
  };
}
```

Then run:

```
claude-code-sandbox /path/to/project
claude-code-sandbox /path/to/project -- --model opus --print "fix the bug"
```

Arguments before `--` are project directories added via `--add-dir`.
Arguments after `--` are passed directly to `claude`.

## nix-darwin options

| Option                      | Type             | Description                                                |
| --------------------------- | ---------------- | ---------------------------------------------------------- |
| `enable`                    | bool             | Enable the sandbox wrapper                                 |
| `preambleScript`            | path or null     | Script whose stdout is used as system prompt context       |
| `extraPackages`             | list of packages | Extra packages on the wrapper PATH                         |
| `extraEnv`                  | attrs of strings | Static env vars set in the wrapper                         |
| `extraFwdEnv`               | list of strings  | Host env vars forwarded into the wrapper                   |
| `serena.enable`             | bool             | Serena MCP integration for code navigation (default: true) |
| `mcpServers`                | attrs            | Additional MCP server configurations                       |
| `sandbox.extraDeny`         | list of attrs    | Additional sandbox-exec deny rules                         |
| `sandbox.extraReadWritePaths` | list of strings | Extra filesystem paths to allow read/write access          |
| `sandbox.extraRules`        | list of strings  | Raw SBPL rules for advanced customisation                  |

## Building from source

```
nix build -L .#claude-code-sandbox
```

Supported systems: `aarch64-darwin`, `x86_64-darwin`.

## Layout

```
flake.nix              Flake entry point
darwin-module.nix      nix-darwin module (options)
claude-code-sandbox/   Sandbox wrapper package (Nix + sandbox-exec)
preamble/              Dynamic system prompt context (git info, tree)
```

## License

[Apache 2.0](LICENSE)
