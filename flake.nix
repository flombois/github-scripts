{
  description = "ghs — terminal reports for GitHub repositories, built on the gh CLI";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      packages = forAllSystems (pkgs: rec {
        github-scripts = pkgs.callPackage ./nix/package.nix { };
        ghs = github-scripts;
        default = github-scripts;
      });

      # For `nixpkgs.overlays = [ inputs.github-scripts.overlays.default ];`
      overlays.default = final: _prev: {
        github-scripts = final.callPackage ./nix/package.nix { };
      };

      # `nix develop`: the tools to hack on the scripts, including the ones only the checks need.
      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShellNoCC {
          packages = with pkgs; [
            gh
            jq
            glow
            gum
            fzf
            less
            util-linux # column, script
            ncurses # tput
            (python3.withPackages (ps: [ ps.pyte ])) # renders fzf's screen in a pty
          ];
          shellHook = ''
            PATH="$PWD/bin:$PATH"
            echo "github-scripts dev shell: run ./cli.sh <command>, or bin/<command>.sh directly."
          '';
        };
      });

      formatter = forAllSystems (pkgs: pkgs.nixfmt-tree);
    };
}
