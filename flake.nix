{
  description = "graphql-ruby-derivation development environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in {
      devShells = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in {
          default = pkgs.mkShell {
            buildInputs = with pkgs; [
              ruby_3_4
              bundler
              libyaml
              openssl
              libxml2
              libxslt
              zlib
              pkg-config
              lefthook
              git
            ];

            shellHook = ''
              bundle config set --local path 'vendor/bundle'

              if [ -d .git ]; then
                lefthook install >/dev/null 2>&1 || true
              fi
            '';
          };
        });
    };
}
