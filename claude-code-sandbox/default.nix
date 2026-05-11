{
  pkgs,
  lib,
  serena ? null,
  preambleScriptPath ? null,
  extraPackages ? [],
  extraEnv ? {},
  extraFwdEnv ? [],
  mcpServers ? {},
  sandboxExtraDeny ? [],
  sandboxExtraReadWritePaths ? [],
  sandboxExtraRules ? [],
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

  serenaConfigFile = ./serena-config.yml;

  formatDenyRule = rule: "(deny ${rule.operation} (regex #\"${rule.regex}\"))";

  # Sandbox template -- static part generated at build time.
  # Dynamic paths ($HOME, $TMPDIR, project dirs) are appended at runtime.
  sandboxTemplate = pkgs.writeText "sandbox-template.sb" (''
    (version 1)
    (deny default)

    ;; Process management
    (allow process*)
    (allow signal)

    ;; Sysctl
    (allow sysctl-read)

    ;; Mach / IPC (macOS system services)
    (allow mach*)
    (allow ipc-posix-shm*)

    ;; IOKit
    (allow iokit-open)
    (allow iokit-get-properties)

    ;; System file reads (read-only)
    (allow file-read*
      (subpath "/nix")
      (subpath "/usr")
      (subpath "/bin")
      (subpath "/sbin")
      (subpath "/System")
      (subpath "/Library")
      (subpath "/etc")
      (subpath "/private/etc")
      (subpath "/private/var")
      (literal "/")
      (literal "/private")
      (literal "/var")
      (literal "/tmp"))

    ;; Device access
    (allow file-read* file-write* (subpath "/dev"))
    (allow file-ioctl (subpath "/dev"))

    ;; Temp directories
    (allow file-read* file-write*
      (subpath "/tmp")
      (subpath "/private/tmp"))

    ;; Network
    (allow network*)
  '' + lib.optionalString (sandboxExtraDeny != []) ''

    ;; Extra deny rules
    ${lib.concatMapStringsSep "\n" formatDenyRule sandboxExtraDeny}
  '' + lib.optionalString (sandboxExtraReadWritePaths != []) ''

    ;; Extra read/write paths
    ${lib.concatMapStringsSep "\n" (p: "(allow file-read* file-write* (subpath \"${p}\"))") sandboxExtraReadWritePaths}
  '' + lib.optionalString (sandboxExtraRules != []) ''

    ;; Extra rules
    ${lib.concatStringsSep "\n" sandboxExtraRules}
  '');

  claudeExe = lib.getExe pkgs.claude-code;

  wrapper = pkgs.writeShellApplication {
    name = "claude-code-sandbox";
    runtimeInputs = with pkgs; [coreutils];
    text = ''
      claude_args=()
      user_args=()
      project_dirs=()
      parsing_dirs=1
      cleanup_files=()
      cleanup() { rm -f "''${cleanup_files[@]}"; }
      trap cleanup EXIT

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
          project_dirs+=("$d")
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
        cleanup_files+=("$preamble_tmp")
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

      # Build sandbox profile.
      # Start from the build-time template and append runtime-only paths.
      sandbox_profile=$(mktemp)
      cleanup_files+=("$sandbox_profile")
      cp ${sandboxTemplate} "$sandbox_profile"
      cwd="$(pwd -P)"

      {
        # TMPDIR (usually /private/var/folders/.../T/)
        echo "(allow file-read* file-write* (subpath \"''${TMPDIR:-/tmp}\"))"

        # Home directory -- allow Claude config, git config
        echo "(allow file-read* file-write* (subpath \"$HOME/.claude\"))"
        echo "(allow file-read* file-write* (subpath \"$HOME/.config/claude\"))"
        ${lib.optionalString (serena != null) ''
          echo "(allow file-read* file-write* (subpath \"$HOME/.serena\"))"
        ''}
        echo "(allow file-read* (literal \"$HOME\"))"
        echo "(allow file-read* (literal \"$HOME/.gitconfig\"))"
        echo "(allow file-read* (subpath \"$HOME/.config/git\"))"

        # Current working directory -- always accessible
        echo "(allow file-read* file-write* (subpath \"$cwd\"))"

        # Extra project directories from CLI args
        for d in "''${project_dirs[@]}"; do
          echo "(allow file-read* file-write* (subpath \"$d\"))"
        done

        # .git write protection (opt-out via CLAUDE_CODE_SANDBOX_UNSAFE_RW_GIT)
        if [[ -z "''${CLAUDE_CODE_SANDBOX_UNSAFE_RW_GIT-}" ]]; then
          echo '(deny file-write* (regex #"/\.git(/|$)"))'
        fi
      } >> "$sandbox_profile"

      exec /usr/bin/sandbox-exec -f "$sandbox_profile" ${claudeExe} "''${claude_args[@]}"
    '';
    derivationArgs = {
      meta = {
        description = "Runs Claude Code inside a restrictive macOS sandbox-exec sandbox; only the project directory, Nix store, and system paths are accessible.";
        platforms = lib.platforms.darwin;
      };
    };
  };

  completions = pkgs.runCommand "claude-code-sandbox-completions" {} ''
    install -Dm644 ${./completions/claude-code-sandbox.bash} \
      $out/share/bash-completion/completions/claude-code-sandbox
    install -Dm644 ${./completions/_claude-code-sandbox} \
      $out/share/zsh/site-functions/_claude-code-sandbox
    install -Dm644 ${./completions/claude-code-sandbox.fish} \
      $out/share/fish/vendor_completions.d/claude-code-sandbox.fish
  '';
in
  pkgs.symlinkJoin {
    name = "claude-code-sandbox";
    paths = [wrapper completions];
    passthru = {
      inherit mcpConfigFile;
    };
    meta = wrapper.meta;
  }
