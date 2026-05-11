{
  pkgs,
  lib,
  serena ? null,
  preambleScriptPath ? null,
  extraPackages ? [],
  extraEnv ? {},
  extraFwdEnv ? [],
  mcpServers ? {},
}: let
  configFormat = pkgs.formats.json {};

  allMcpServers =
    mcpServers
    // lib.optionalAttrs (serena != null) {
      serena = {
        command = lib.getExe serena;
        args = ["start-mcp-server"];
      };
    };

  mcpConfigFile = configFormat.generate "claude-mcp-config.json" {
    mcpServers = allMcpServers;
  };

  hasMcpServers = allMcpServers != {};

  sandboxProfile = ./sandbox.sb;

  serenaConfigFile = ./serena-config.yml;

  safe = pkgs.writeShellApplication {
    name = "claude-code-bwrap";
    runtimeInputs = with pkgs; [coreutils];
    text = ''
      claude_args=()
      user_args=()
      parsing_dirs=1

      for arg in "$@"; do
        if [[ "$parsing_dirs" == 1 && "$arg" == "--" ]]; then
          parsing_dirs=0
          continue
        fi
        if [[ "$parsing_dirs" == 1 ]]; then
          # Validate directory exists
          if [[ ! -d "$arg" ]]; then
            echo >&2 "$0: cannot access '$arg': No such directory"
            exit 1
          fi
          d="$(cd "$arg" && pwd -P)"
          claude_args+=(--add-dir "$d")
        else
          user_args+=("$arg")
        fi
      done

      ${lib.optionalString hasMcpServers ''
        claude_args+=(--mcp-config ${mcpConfigFile})
      ''}

      ${lib.optionalString (serena != null) ''
        # Serena needs a writable config directory
        mkdir -p "$HOME/.serena"
        install -m 644 ${serenaConfigFile} "$HOME/.serena/serena_config.yml"
      ''}

      ${lib.optionalString (preambleScriptPath != null) ''
        preamble_tmp=$(mktemp)
        trap 'rm -f "$preamble_tmp"' EXIT
        ${preambleScriptPath} > "$preamble_tmp" 2>/dev/null || true
        if [[ -s "$preamble_tmp" ]]; then
          claude_args+=(--system-prompt "$(cat "$preamble_tmp")")
        fi
      ''}

      # Set extra PATH
      ${lib.optionalString (extraPackages != []) ''
        export PATH=${lib.makeBinPath extraPackages}:"$PATH"
      ''}

      # Set static environment variables
      ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: value: ''
          export ${name}=${lib.escapeShellArg value}
        '')
        extraEnv)}

      # Forward host environment variables
      ${lib.optionalString (extraFwdEnv != []) ''
        for _var in ${lib.concatMapStringsSep " " lib.escapeShellArg extraFwdEnv}; do
          if [[ -n "''${!_var+x}" ]]; then
            export "$_var"="''${!_var}"
          fi
        done
      ''}

      if [[ ''${#user_args[@]} -gt 0 ]]; then
        claude_args+=("''${user_args[@]}")
      fi

      if [[ -n "''${CLAUDE_CODE_BWRAP_UNSAFE_RW_GIT-}" ]]; then
        exec ${lib.getExe pkgs.claude-code} "''${claude_args[@]}"
      else
        exec /usr/bin/sandbox-exec -f ${sandboxProfile} ${lib.getExe pkgs.claude-code} "''${claude_args[@]}"
      fi
    '';
    derivationArgs = {
      meta = {
        description = "Runs Claude Code inside a macOS sandbox-exec sandbox; .git directories are protected from writes unless CLAUDE_CODE_BWRAP_UNSAFE_RW_GIT is set.";
        platforms = lib.platforms.darwin;
      };
      passthru = {
        inherit mcpConfigFile;
      };
    };
  };
in
  safe
