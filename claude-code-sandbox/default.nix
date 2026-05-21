{
  pkgs,
  lib,
  claudeCodePackage ? pkgs.claude-code,
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

    ;; -- Process --
    ;; process-exec* : execute binaries (glob covers process-exec)
    ;; process-fork  : spawn child processes (git, shell commands)
    ;; signal        : send signals to children (SIGTERM on exit, interactive TUI)
    (allow process-exec*)
    (allow process-fork)
    (allow signal)

    ;; -- Mach IPC --
    ;; mach-lookup : connect to system services (DNS, keychain, Security.framework).
    ;;              macOS routes nearly all system APIs through Mach IPC.
    (allow mach-lookup)

    ;; -- POSIX shared memory --
    ;; Node.js/V8 uses shm for worker threads and garbage collector coordination.
    (allow ipc-posix-shm-read-data)
    (allow ipc-posix-shm-write-create)
    (allow ipc-posix-shm-write-data)

    ;; -- System --
    ;; sysctl-read   : Node.js os module reads kernel info (os.type, os.release)
    ;; system-socket : Unix domain sockets (MCP server stdio, internal IPC)
    ;; pseudo-tty    : allocate PTYs for the interactive TUI and subprocesses
    ;; lsopen        : open URLs in browser (OAuth login flow)
    (allow sysctl-read)
    (allow system-socket)
    (allow pseudo-tty)
    (allow lsopen)

    ;; -- Filesystem metadata --
    ;; stat/readdir on system paths only. Required for PATH resolution
    ;; (posix_spawnp) and shared library loading. Does NOT allow reading
    ;; file contents. $HOME metadata is added at runtime for only the
    ;; specific paths and PATH entries that need it.
    (allow file-read-metadata
      (subpath "/nix")
      (subpath "/usr")
      (subpath "/bin")
      (subpath "/sbin")
      (subpath "/System")
      (subpath "/Library")
      (subpath "/etc")
      (subpath "/private")
      (subpath "/var")
      (subpath "/tmp")
      (subpath "/dev")
      (literal "/Users")
      (literal "/"))

    ;; -- System file reads (read-only) --
    ;; Nix store (all tools and Claude Code itself), system frameworks,
    ;; dynamic linker, shared libraries, system configuration.
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

    ;; -- Device access --
    ;; /dev/null, /dev/urandom (crypto), /dev/tty* (terminal).
    ;; file-ioctl for terminal raw mode (interactive TUI uses TIOCGWINSZ, tcsetattr).
    (allow file-read* file-write* (subpath "/dev"))
    (allow file-ioctl (subpath "/dev"))

    ;; -- Temp directories --
    (allow file-read* file-write*
      (subpath "/tmp")
      (subpath "/private/tmp"))

    ;; -- Network --
    ;; network-outbound : API calls to Anthropic, git fetches
    ;; network-bind     : Node.js binds local ports for MCP server IPC
    (allow network-outbound)
    (allow network-bind)
  '' + lib.optionalString (sandboxExtraReadWritePaths != []) ''

    ;; Extra read/write paths
    ${lib.concatMapStringsSep "\n" (p: "(allow file-read* file-write* (subpath \"${p}\"))") sandboxExtraReadWritePaths}
  '' + lib.optionalString (sandboxExtraRules != []) ''

    ;; Extra rules
    ${lib.concatStringsSep "\n" sandboxExtraRules}
  '');

  claudeExe = lib.getExe claudeCodePackage;

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
        # TMPDIR (usually /var/folders/.../T/ -> /private/var/folders/.../T/)
        # Add both the symlink and resolved path since sandbox-exec may
        # match on the real path after symlink resolution.
        echo "(allow file-read* file-write* (subpath \"''${TMPDIR:-/tmp}\"))"
        _real_tmpdir="$(cd "''${TMPDIR:-/tmp}" 2>/dev/null && pwd -P)"
        if [[ "$_real_tmpdir" != "''${TMPDIR:-/tmp}" ]]; then
          echo "(allow file-read* file-write* (subpath \"$_real_tmpdir\"))"
        fi

        # Allowed $HOME paths (read-only unless noted)
        home_allowed_paths=(
          "$HOME/.claude"            # r/w: Claude config
          "$HOME/.config/claude"     # r/w: Claude config
          "$HOME/Library/Keychains"  # r: OAuth credentials
          "$HOME/Library/Preferences" # r/w: macOS notifications
          "$HOME/.config/git"        # r: git config
          "$HOME/.config/nix"        # r: user nix.conf
          "$HOME/.nix-profile"       # r: nix tools, terminfo
          "$HOME/.nix-defexpr"       # r: nix expressions
          "$HOME/.local/state/nix"   # r: nix channels symlink target (via .nix-defexpr/channels)
          "$HOME/.local/share/nix"   # r: nix trusted-settings.json
          "$HOME/.cache/nix"         # r/w: nix eval cache, flake registry, tarball cache; nix commands fail without it
          ${lib.optionalString (serena != null) ''"$HOME/.serena"  # r/w: Serena''}
        )

        home_rw_paths=(
          "$HOME/.claude"
          "$HOME/.config/claude"
          "$HOME/Library/Preferences"
          "$HOME/.cache/nix"
          ${lib.optionalString (serena != null) ''"$HOME/.serena"''}
        )

        # Emit file-read-metadata for every allowed path, its parents
        # back to $HOME, and every PATH entry under $HOME + its parents.
        # This is the minimum needed for path traversal and posix_spawnp.
        declare -A _seen_meta
        _allow_meta() {
          if [[ -z "''${_seen_meta[$1]:-}" ]]; then
            _seen_meta["$1"]=1
            echo "(allow file-read-metadata (literal \"$1\"))"
          fi
        }
        _allow_meta_tree() {
          local p="$1"
          while [[ "$p" != "$HOME" && "$p" != "/" ]]; do
            _allow_meta "$p"
            p="$(dirname "$p")"
          done
        }

        _allow_meta "$HOME"

        # Metadata for allowed $HOME paths + parent chain
        for _p in "''${home_allowed_paths[@]}"; do
          echo "(allow file-read-metadata (subpath \"$_p\"))"
          _allow_meta_tree "$_p"
        done

        # Metadata for PATH entries under $HOME + parent chain
        # Also discover non-system prefixes (e.g. Homebrew) from PATH and
        # allow reading their entire prefix so dyld can load shared libraries.
        declare -A _seen_prefix
        IFS=':' read -ra _path_entries <<< "$PATH"
        for _entry in "''${_path_entries[@]}"; do
          case "$_entry" in
            "$HOME"/*)
              echo "(allow file-read-metadata (subpath \"$_entry\"))"
              _allow_meta_tree "$_entry"
              ;;
            /opt/*)
              # Discover Homebrew or other /opt prefixes from PATH.
              # e.g. /opt/homebrew/bin -> allow read on /opt/homebrew
              # (dyld needs Cellar/Frameworks/lib which are siblings of bin)
              _prefix="$(dirname "$_entry")"
              if [[ -z "''${_seen_prefix[$_prefix]:-}" ]]; then
                _seen_prefix["$_prefix"]=1
                echo "(allow file-read* (subpath \"$_prefix\"))"
              fi
              ;;
          esac
        done

        # Metadata for cwd + project dirs parent chain
        # (kernel needs to stat each component to resolve the path)
        _allow_meta_tree "$cwd"
        for d in "''${project_dirs[@]}"; do
          _allow_meta_tree "$d"
        done

        # File reads for specific paths (no readdir on $HOME itself)
        echo "(allow file-read* (literal \"$HOME/CLAUDE.md\"))"
        for _p in "''${home_allowed_paths[@]}"; do
          echo "(allow file-read* (subpath \"$_p\"))"
        done
        echo "(allow file-read* file-write* (literal \"$HOME/.claude.json\"))"
        # Regex to match .gitconfig and conditional includes like .gitconfig-work
        # (git includeIf loads extra configs based on repo path)
        printf '%s\n' "(allow file-read* (regex #\"^$HOME/\\.gitconfig\"))"
        echo "(allow file-read* (literal \"$HOME/.ssh/known_hosts\"))"
        echo "(allow file-read* (literal \"$HOME/.ssh/config\"))"
        echo "(allow file-read* (literal \"$HOME/.profile\"))"
        echo "(allow file-read* (literal \"$HOME/.zprofile\"))"
        echo "(allow file-read* (literal \"$HOME/.zshenv\"))"

        # Write access for specific paths
        for _p in "''${home_rw_paths[@]}"; do
          echo "(allow file-write* (subpath \"$_p\"))"
        done

        # Tool caches discovered from environment (Go, Cargo, etc.)
        # Allow r/w so build tools work; only added if the env var is set.
        for _var in GOCACHE GOMODCACHE GOPATH CARGO_HOME; do
          if [[ -n "''${!_var+x}" && "''${!_var}" == "$HOME"/* ]]; then
            echo "(allow file-read* file-write* (subpath \"''${!_var}\"))"
            _allow_meta_tree "''${!_var}"
          fi
        done

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

        ${lib.optionalString (sandboxExtraDeny != []) ''
          # Extra deny rules (appended last to override project dir allows)
          ${lib.concatMapStringsSep "\n" (rule:
            "echo '${formatDenyRule rule}'"
          ) sandboxExtraDeny}
        ''}
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
