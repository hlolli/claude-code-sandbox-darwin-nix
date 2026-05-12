{inputs}: {
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkEnableOption mkOption mkIf types literalExpression;

  cfg = config.programs.claude-code-sandbox;
  inherit (pkgs.stdenv.hostPlatform) system;

  serena = inputs.serena.packages.${system}.default;

  package = pkgs.callPackage ./claude-code-sandbox {
    serena =
      if cfg.serena.enable
      then serena
      else null;
    preambleScriptPath =
      if cfg.preambleScript != null
      then cfg.preambleScript
      else null;
    inherit (cfg) claudeCodePackage extraPackages extraEnv extraFwdEnv mcpServers;
    sandboxExtraDeny = cfg.sandbox.extraDeny;
    sandboxExtraReadWritePaths = cfg.sandbox.extraReadWritePaths;
    sandboxExtraRules = cfg.sandbox.extraRules;
  };
in {
  options.programs.claude-code-sandbox = {
    enable = mkEnableOption "claude-code-sandbox macOS sandbox wrapper for Claude Code";

    claudeCodePackage = mkOption {
      type = types.package;
      default = pkgs.claude-code;
      example = literalExpression "pkgs-unstable.claude-code";
      description = "The claude-code package to wrap. Override to use a different nixpkgs pin or version.";
    };

    package = mkOption {
      type = types.package;
      readOnly = true;
      default = package;
      description = "The final configured wrapper package added to `environment.systemPackages`.";
    };

    preambleScript = mkOption {
      type = types.nullOr types.path;
      default = lib.getExe (import ./preamble pkgs);
      example = literalExpression "null";
      description = "Store path to a script whose stdout is prepended as system prompt context at runtime. `null` disables the feature.";
    };

    extraPackages = mkOption {
      type = types.listOf types.package;
      default = [];
      example = literalExpression "[ pkgs.ripgrep pkgs.fd ]";
      description = "Extra packages whose bin/ directories are prepended to PATH inside the wrapper.";
    };

    extraEnv = mkOption {
      type = types.attrsOf types.str;
      default = {};
      example = literalExpression ''{ MY_SETTING = "value"; }'';
      description = "Static environment variables set inside the wrapper.";
    };

    extraFwdEnv = mkOption {
      type = types.listOf types.str;
      default = [];
      example = ["ANTHROPIC_API_KEY" "GITHUB_TOKEN"];
      description = "Host environment variable names to forward into the wrapper.";
    };

    serena = {
      enable =
        mkEnableOption "Serena LSP/MCP integration (provides semantic code-navigation tools)"
        // {default = true;};
    };

    mcpServers = mkOption {
      type = types.attrsOf types.anything;
      default = {};
      example = literalExpression ''
        {
          my-server = {
            command = "my-mcp-server";
            args = [ "--port" "3000" ];
          };
        }
      '';
      description = "Additional MCP server configurations passed to Claude Code via --mcp-config.";
    };

    sandbox = {
      extraDeny = mkOption {
        type = types.listOf (types.submodule {
          options = {
            operation = mkOption {
              type = types.str;
              example = "file-write*";
              description = "sandbox-exec operation to deny (e.g. `file-read*`, `file-write*`).";
            };
            regex = mkOption {
              type = types.str;
              example = "/secrets(/|$)";
              description = "POSIX extended regex matching absolute file paths.";
            };
          };
        });
        default = [];
        example = literalExpression ''
          [
            { operation = "file-read*"; regex = "/secrets(/|$)"; }
            { operation = "file-write*"; regex = "/secrets(/|$)"; }
          ]
        '';
        description = "Additional sandbox-exec deny rules. Deny rules take precedence over allow rules at the same specificity in SBPL.";
      };

      extraReadWritePaths = mkOption {
        type = types.listOf types.str;
        default = [];
        example = ["/opt/data" "/srv/shared"];
        description = "Additional filesystem paths to allow read and write access inside the sandbox. The project directory, `$HOME/.claude`, and temp directories are always allowed.";
      };

      extraRules = mkOption {
        type = types.listOf types.str;
        default = [];
        example = literalExpression ''
          [
            "(deny network-outbound (remote tcp \"localhost:*\"))"
          ]
        '';
        description = "Raw SBPL rules appended to the sandbox profile. Use this for advanced sandbox customisation not covered by the structured options.";
      };
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = lib.all (name: builtins.match "[a-zA-Z_][a-zA-Z_0-9]*" name != null) (builtins.attrNames cfg.extraEnv);
        message = "programs.claude-code-sandbox.extraEnv: every key must be a valid POSIX variable name ([a-zA-Z_][a-zA-Z_0-9]*)";
      }
      {
        assertion = lib.all (name: builtins.match "[a-zA-Z_][a-zA-Z_0-9]*" name != null) cfg.extraFwdEnv;
        message = "programs.claude-code-sandbox.extraFwdEnv: every entry must be a valid POSIX variable name ([a-zA-Z_][a-zA-Z_0-9]*)";
      }
      {
        assertion = lib.all (rule: builtins.match "[a-z-]+\\*?" rule.operation != null) cfg.sandbox.extraDeny;
        message = "programs.claude-code-sandbox.sandbox.extraDeny: 'operation' must be a valid sandbox-exec operation (e.g. file-read*, file-write*)";
      }
      {
        assertion = lib.all (rule: !lib.hasInfix "\"" rule.regex) cfg.sandbox.extraDeny;
        message = "programs.claude-code-sandbox.sandbox.extraDeny: 'regex' must not contain double-quote characters";
      }
    ];

    environment.systemPackages = [package];
  };
}
