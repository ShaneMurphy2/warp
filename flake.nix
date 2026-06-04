{
  description = "Warp is an agentic development environment, born out of the terminal (Experimental Nix Support).";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    crane.url = "github:ipetkov/crane";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      crane,
      rust-overlay,
      ...
    }:
    let
      linuxSystems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      darwinSystems = [
        "aarch64-darwin"
        "x86_64-darwin"
      ];
      systems = linuxSystems ++ darwinSystems;
      forAllSystems = nixpkgs.lib.genAttrs systems;

      mkPkgs =
        system:
        import nixpkgs {
          inherit system;
          overlays = [ rust-overlay.overlays.default ];
        };

      mkCommon =
        system:
        let
          pkgs = mkPkgs system;
          lib = pkgs.lib;
          rustToolchain = pkgs.rust-bin.fromRustupToolchainFile ./rust-toolchain.toml;
          rustPlatform = pkgs.makeRustPlatform {
            cargo = rustToolchain;
            rustc = rustToolchain;
          };
          craneLib = (crane.mkLib pkgs).overrideToolchain rustToolchain;
          appCargoToml = builtins.fromTOML (builtins.readFile ./app/Cargo.toml);
          version = "${appCargoToml.package.version}+${self.shortRev or "dirty"}";
          src = self;
          cargoLock = ./Cargo.lock;
          # Match Zed's approach: derive the main app vendor directory from
          # Cargo.lock instead of maintaining a top-level cargoVendorHash.
          cargoVendorDir =
            let
              craneVendorDir = craneLib.vendorCargoDeps {
                inherit src cargoLock;
                overrideVendorGitCheckout =
                  crates: drv:
                  let
                    hasCrate = crateName: builtins.any (crate: crate.name == crateName) crates;
                  in
                  drv.overrideAttrs (old: {
                    postPatch = (old.postPatch or "") + ''
                      find . -name 'Cargo.toml.orig' -delete

                      ${lib.optionalString (hasCrate "warp_multi_agent_api") ''
                        mkdir -p apis/multi_agent/v1/gen/rust/nix-vendored-protos
                        cp apis/multi_agent/v1/*.proto \
                          apis/multi_agent/v1/gen/rust/nix-vendored-protos/
                        substituteInPlace apis/multi_agent/v1/gen/rust/build.rs \
                          --replace-fail \
                            'let proto_path = manifest_dir.parent().unwrap().parent().unwrap();' \
                            'let proto_path = manifest_dir.join("nix-vendored-protos");'
                      ''}

                      ${lib.optionalString (hasCrate "warp-workflows") ''
                        mkdir -p workflows/nix-vendored-specs
                        cp -R specs/. workflows/nix-vendored-specs/
                        substituteInPlace workflows/build.rs \
                          --replace-fail \
                            'println!("cargo:rerun-if-changed=../specs");' \
                            'println!("cargo:rerun-if-changed=nix-vendored-specs");' \
                          --replace-fail \
                            'for entry in WalkDir::new("../specs") {' \
                            'for entry in WalkDir::new("nix-vendored-specs") {'
                      ''}
                    '';
                  });
              };
            in
            # crane writes a root config.toml; buildRustPackage expects the
            # cargoDeps layout to include .cargo/config.toml and Cargo.lock.
            pkgs.runCommand "warp-terminal-experimental-${version}-cargo-vendor" { } ''
              cp -R ${craneVendorDir}/. "$out"
              chmod u+w "$out"
              mkdir -p "$out/.cargo"
              sed 's|${craneVendorDir}|@vendor@|g' \
                "$out/config.toml" > "$out/.cargo/config.toml"
              rm "$out/config.toml"
              cp ${cargoLock} "$out/Cargo.lock"
            '';
        in
        {
          inherit
            pkgs
            lib
            rustToolchain
            rustPlatform
            version
            src
            cargoVendorDir
            ;
        };

      commonNativeBuildInputs =
        pkgs: with pkgs; [
          brotli
          cargo-about
          clang
          cmake
          jq
          pkg-config
          protobuf
          python3
        ];

      linuxRuntimeLibraries =
        pkgs: with pkgs; [
          alsa-lib
          curl
          dbus
          expat
          fontconfig
          freetype
          libGL
          libgit2
          libxkbcommon
          openssl
          stdenv.cc.cc.lib
          udev
          vulkan-loader
          wayland
          libx11
          libxscrnsaver
          libxcursor
          libxext
          libxfixes
          libxi
          libxrandr
          libxrender
          libxcb
          zlib
        ];

      darwinBuildInputs =
        pkgs: with pkgs; [
          libgit2
          libiconv
          openssl
          zlib
        ];

      buildFeatures = [
        "release_bundle"
        "ssh_tmux_wrapper"
        "gui"
      ];

      mkLinuxPackage =
        common:
        let
          inherit (common)
            pkgs
            lib
            rustPlatform
            version
            src
            cargoVendorDir
            ;
          runtimeLibraries = linuxRuntimeLibraries pkgs;
        in
        rustPlatform.buildRustPackage {
          pname = "warp-terminal-experimental";
          inherit version src;
          cargoDeps = cargoVendorDir;

          nativeBuildInputs =
            commonNativeBuildInputs pkgs
            ++ (with pkgs; [
              makeWrapper
              patchelf
            ]);

          buildInputs = runtimeLibraries;

          cargoBuildFlags = [
            "-p"
            "warp"
            "--bin"
            "warp-oss"
            "--bin"
            "generate_settings_schema"
          ];
          inherit buildFeatures;

          # The application test suite is large and GUI/integration-heavy; this
          # flake's package check is the Nix build plus a launch smoke test.
          doCheck = false;

          env = {
            APPIMAGE_NAME = "WarpOss-${pkgs.stdenv.hostPlatform.parsed.cpu.name}.AppImage";
            LIBCLANG_PATH = "${pkgs.llvmPackages.libclang.lib}/lib";
            PROTOC = "${pkgs.protobuf}/bin/protoc";
            PROTOC_INCLUDE = "${pkgs.protobuf}/include";
            CARGO_PROFILE_RELEASE_DEBUG = "false";
          };

          postInstall =
            let
              installDir = "$out/opt/warpdotdev/warp-terminal-experimental";
              resourcesDir = "${installDir}/resources";
              releaseChannel = "stable";
              libraryPath = lib.makeLibraryPath runtimeLibraries;
              executablePath = lib.makeBinPath (with pkgs; [ xdg-utils ]);
            in
            ''
              install -Dm755 "$out/bin/warp-oss" "${installDir}/warp-oss"
              rm -f "$out/bin/warp-oss"

              patchShebangs \
                ./script/prepare_bundled_resources \
                ./script/copy_conditional_skills

              SKIP_SETTINGS_SCHEMA=1 ./script/prepare_bundled_resources \
                "${resourcesDir}" \
                "${releaseChannel}" \
                release

              "$out/bin/generate_settings_schema" \
                --channel "${releaseChannel}" \
                "${resourcesDir}/settings_schema.json"
              rm -f "$out/bin/generate_settings_schema"

              install -Dm644 \
                "${resourcesDir}/THIRD_PARTY_LICENSES.txt" \
                "$out/share/licenses/warp-terminal-experimental/THIRD_PARTY_LICENSES.txt"

              install -Dm644 LICENSE-AGPL "$out/share/licenses/warp-terminal-experimental/LICENSE-AGPL"
              install -Dm644 LICENSE-MIT "$out/share/licenses/warp-terminal-experimental/LICENSE-MIT"

              install -Dm644 app/channels/oss/dev.warp.WarpOss.desktop \
                "$out/share/applications/dev.warp.WarpOss.desktop"
              substituteInPlace "$out/share/applications/dev.warp.WarpOss.desktop" \
                --replace-fail "Exec=warp-terminal-oss %U" "Exec=warp-terminal-experimental %U"

              for size in 16x16 32x32 64x64 128x128 256x256 512x512; do
                icon="app/channels/oss/icon/no-padding/$size.png"
                if [ -f "$icon" ]; then
                  install -Dm644 "$icon" \
                    "$out/share/icons/hicolor/$size/apps/dev.warp.WarpOss.png"
                fi
              done

              wrapProgram "${installDir}/warp-oss" \
                --prefix LD_LIBRARY_PATH : "${libraryPath}" \
                --prefix PATH : "${executablePath}"

              mkdir -p "$out/bin"
              ln -s "${installDir}/warp-oss" "$out/bin/warp-oss"
              ln -s "${installDir}/warp-oss" "$out/bin/warp-terminal-experimental"
            '';

          postFixup = ''
            wrapped="/opt/warpdotdev/warp-terminal-experimental/.warp-oss-wrapped"
            if [ -e "$out$wrapped" ] && ! patchelf --print-needed "$out$wrapped" | grep -q '^libfontconfig\.so\.1$'; then
              patchelf --add-needed libfontconfig.so.1 "$out$wrapped"
            fi
          '';

          meta = {
            description = "Warp is an agentic development environment, born out of the terminal.";
            homepage = "https://www.warp.dev";
            license = lib.licenses.agpl3Only;
            mainProgram = "warp-terminal-experimental";
            platforms = linuxSystems;
            sourceProvenance = with lib.sourceTypes; [ fromSource ];
          };
        };

      mkDarwinPackage =
        system: common:
        let
          inherit (common)
            pkgs
            lib
            rustPlatform
            version
            src
            cargoVendorDir
            ;
          bundleArch = if system == "aarch64-darwin" then "aarch64" else "x86_64";
          dockTileArch = if system == "aarch64-darwin" then "arm64" else "x86_64";
          rustTarget = "${bundleArch}-apple-darwin";
          appBundle = "target/${rustTarget}/release-lto/bundle/osx/WarpOss.app";
        in
        rustPlatform.buildRustPackage {
          pname = "warp-terminal-experimental";
          inherit version src;
          cargoDeps = cargoVendorDir;

          nativeBuildInputs =
            commonNativeBuildInputs pkgs
            ++ (with pkgs; [
              cargo-bundle
              makeWrapper
            ]);

          buildInputs = darwinBuildInputs pkgs;

          buildPhase = ''
            runHook preBuild

            export CARGO_TARGET_DIR="$PWD/target"
            export LIBCLANG_PATH="${pkgs.llvmPackages.libclang.lib}/lib"
            export PROTOC="${pkgs.protobuf}/bin/protoc"
            export PROTOC_INCLUDE="${pkgs.protobuf}/include"
            export CARGO_PROFILE_RELEASE_DEBUG=false
            export DOCK_TILE_PLUGIN_ARCH_FLAGS="-arch ${dockTileArch}"

            # Apple ships the Metal compiler outside the CLT/Xcode SDK in a
            # cryptex toolchain. Nix's Darwin stdenv exposes xcrun, but its
            # sandbox lookup cannot find these tools, so route just the Metal
            # shader calls to the absolute host toolchain path.
            hostToolDir="$PWD/nix-host-tools"
            mkdir -p "$hostToolDir"
            cat > "$hostToolDir/xcrun" <<'EOF'
            #!${pkgs.runtimeShell}
            if [ "$1" = "-sdk" ] && [ "$2" = "macosx" ] && { [ "$3" = "metal" ] || [ "$3" = "metallib" ]; }; then
              tool="$3"
              shift 3
              for candidate in \
                /private/var/run/com.apple.security.cryptexd/mnt/com.apple.MobileAsset.MetalToolchain-*/Metal.xctoolchain/usr/bin/"$tool" \
                /var/run/com.apple.security.cryptexd/mnt/com.apple.MobileAsset.MetalToolchain-*/Metal.xctoolchain/usr/bin/"$tool"
              do
                if [ -x "$candidate" ]; then
                  exec "$candidate" "$@"
                fi
              done
              echo "Unable to find Apple Metal tool '$tool'. Install or refresh Xcode Command Line Tools." >&2
              exit 127
            fi

            exec /usr/bin/xcrun "$@"
            EOF
            cat > "$hostToolDir/plutil" <<'EOF'
            #!${pkgs.runtimeShell}
            exec /usr/bin/plutil "$@"
            EOF
            chmod +x "$hostToolDir/xcrun"
            chmod +x "$hostToolDir/plutil"
            export PATH="$hostToolDir:$PATH"

            ./script/macos/bundle \
              --channel oss \
              --arch ${bundleArch} \
              --skip-dmg \
              --nosign \
              --no-nld

            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall

            test -d "${appBundle}"
            mkdir -p "$out/Applications" "$out/bin"
            cp -R "${appBundle}" "$out/Applications/"

            makeWrapper \
              "$out/Applications/WarpOss.app/Contents/MacOS/warp-oss" \
              "$out/bin/warp-oss"
            makeWrapper \
              "$out/Applications/WarpOss.app/Contents/MacOS/warp-oss" \
              "$out/bin/warp-terminal-experimental"

            runHook postInstall
          '';

          doCheck = false;

          meta = {
            description = "Warp is an agentic development environment, born out of the terminal.";
            homepage = "https://www.warp.dev";
            license = lib.licenses.agpl3Only;
            mainProgram = "warp-terminal-experimental";
            platforms = darwinSystems;
            sourceProvenance = with lib.sourceTypes; [ fromSource ];
          };
        };

      mkDevShell =
        system:
        let
          common = mkCommon system;
          inherit (common)
            pkgs
            lib
            rustToolchain
            ;
          nativeBuildInputs =
            commonNativeBuildInputs pkgs
            ++ (with pkgs; [
              cargo-nextest
              lld
              makeWrapper
              rustToolchain
              rust-analyzer
            ])
            ++ lib.optionals pkgs.stdenv.isLinux (with pkgs; [ patchelf ])
            ++ lib.optionals pkgs.stdenv.isDarwin (with pkgs; [ cargo-bundle ]);
          buildInputs = if pkgs.stdenv.isLinux then linuxRuntimeLibraries pkgs else darwinBuildInputs pkgs;
        in
        {
          default = pkgs.mkShell (
            {
              inherit nativeBuildInputs buildInputs;
              LIBCLANG_PATH = "${pkgs.llvmPackages.libclang.lib}/lib";
              PROTOC = "${pkgs.protobuf}/bin/protoc";
              PROTOC_INCLUDE = "${pkgs.protobuf}/include";
            }
            // lib.optionalAttrs pkgs.stdenv.isLinux {
              APPIMAGE_NAME = "WarpOss-${pkgs.stdenv.hostPlatform.parsed.cpu.name}.AppImage";
              LD_LIBRARY_PATH = lib.makeLibraryPath buildInputs;
            }
          );
        };
    in
    {
      packages = forAllSystems (
        system:
        let
          common = mkCommon system;
          warp-terminal-experimental =
            if common.pkgs.stdenv.isDarwin then mkDarwinPackage system common else mkLinuxPackage common;
        in
        {
          inherit warp-terminal-experimental;
          default = warp-terminal-experimental;
        }
      );

      devShells = forAllSystems mkDevShell;

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixfmt);
    };
}
