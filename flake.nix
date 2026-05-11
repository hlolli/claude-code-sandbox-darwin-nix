{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    serena = {
      url = "github:oraios/serena/main";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = inputs: let
    inherit (inputs.nixpkgs) lib;

    darwinOptionStubs = {
      options = {
        environment.systemPackages = lib.mkOption {
          type = lib.types.listOf lib.types.package;
          default = [];
        };
        assertions = lib.mkOption {
          type = lib.types.listOf lib.types.anything;
          default = [];
        };
      };
    };
  in {
    darwinModules.default = import ./darwin-module.nix {inherit inputs;};

    packages =
      lib.genAttrs [
        "aarch64-darwin"
        "x86_64-darwin"
      ] (system: let
        pkgs = inputs.nixpkgs.legacyPackages.${system};

        darwinEval = lib.evalModules {
          specialArgs = {inherit pkgs;};
          modules = [
            (import ./darwin-module.nix {inherit inputs;})
            darwinOptionStubs
            {
              programs.claude-code-bwrap = {
                enable = true;
              };
            }
          ];
        };
      in rec {
        default = claude-code-bwrap;
        claude-code-bwrap = builtins.head darwinEval.config.environment.systemPackages;
      });
  };
}
