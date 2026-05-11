# claude-code-bwrap-darwin-nix

Nix flake that runs [Claude Code](https://claude.ai/code) inside a
macOS `sandbox-exec` sandbox, with a nix-darwin module for declarative
installation.

## What it does

- Protects `.git` directories from writes using a macOS Seatbelt
  sandbox profile, preventing the AI agent from rewriting git history
  (override with `CLAUDE_CODE_BWRAP_UNSAFE_RW_GIT=1`).
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
  inputs.claude-code-bwrap.url = "github:hlolli/claude-code-bwrap-darwin-nix";

  outputs = { self, darwin, claude-code-bwrap, ... }: {
    darwinConfigurations."my-mac" = darwin.lib.darwinSystem {
      system = "aarch64-darwin";
      modules = [
        claude-code-bwrap.darwinModules.default
        {
          programs.claude-code-bwrap = {
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
claude-code-bwrap /path/to/project
claude-code-bwrap /path/to/project -- --model opus --print "fix the bug"
```

Arguments before `--` are project directories added via `--add-dir`.
Arguments after `--` are passed directly to `claude`.

## nix-darwin options

| Option           | Type             | Description                                                |
| ---------------- | ---------------- | ---------------------------------------------------------- |
| `enable`         | bool             | Enable the sandbox wrapper                                 |
| `preambleScript` | path or null     | Script whose stdout is used as system prompt context       |
| `extraPackages`  | list of packages | Extra packages on the wrapper PATH                         |
| `extraEnv`       | attrs of strings | Static env vars set in the wrapper                         |
| `extraFwdEnv`    | list of strings  | Host env vars forwarded into the wrapper                   |
| `serena.enable`  | bool             | Serena MCP integration for code navigation (default: true) |
| `mcpServers`     | attrs            | Additional MCP server configurations                       |

## Building from source

```
nix build -L .#claude-code-bwrap
```

Supported systems: `aarch64-darwin`, `x86_64-darwin`.

## Layout

```
flake.nix              Flake entry point
darwin-module.nix      nix-darwin module (options)
claude-code-bwrap/     Sandbox wrapper package (Nix + sandbox-exec)
preamble/              Dynamic system prompt context (git info, tree)
```

## License

[Apache 2.0](LICENSE)
