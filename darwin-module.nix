{inputs}: {
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (lib) mkEnableOption mkOption mkIf types literalExpression;

  cfg = config.programs.claude-code-bwrap;
  inherit (pkgs.stdenv.hostPlatform) system;

  serena = inputs.serena.packages.${system}.default;

  package = pkgs.callPackage ./claude-code-bwrap {
    serena =
      if cfg.serena.enable
      then serena
      else null;
    preambleScriptPath =
      if cfg.preambleScript != null
      then cfg.preambleScript
      else null;
    inherit (cfg) extraPackages extraEnv extraFwdEnv mcpServers;
  };
in {
  options.programs.claude-code-bwrap = {
    enable = mkEnableOption "claude-code-bwrap macOS sandbox wrapper for Claude Code";

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
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = lib.all (name: builtins.match "[a-zA-Z_][a-zA-Z_0-9]*" name != null) (builtins.attrNames cfg.extraEnv);
        message = "programs.claude-code-bwrap.extraEnv: every key must be a valid POSIX variable name ([a-zA-Z_][a-zA-Z_0-9]*)";
      }
      {
        assertion = lib.all (name: builtins.match "[a-zA-Z_][a-zA-Z_0-9]*" name != null) cfg.extraFwdEnv;
        message = "programs.claude-code-bwrap.extraFwdEnv: every entry must be a valid POSIX variable name ([a-zA-Z_][a-zA-Z_0-9]*)";
      }
    ];

    environment.systemPackages = [package];
  };
}
