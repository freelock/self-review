{
  description = "Self Review - GitHub-style PR review UI for local git diffs (Electron app)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      lib = nixpkgs.lib;

      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = lib.genAttrs supportedSystems;

      # npm/Electron's "arch" naming differs from Nix's system strings.
      npmArchForSystem = {
        "x86_64-linux" = "x64";
        "aarch64-linux" = "arm64";
      };

      packageJson = builtins.fromJSON (builtins.readFile ./package.json);
      packageLockJson = builtins.fromJSON (builtins.readFile ./package-lock.json);

      # Read the exact resolved Electron version straight from the lockfile so
      # this flake automatically tracks whatever version package.json/npm
      # actually pin, instead of a value hand-copied into this file.
      electronVersion = packageLockJson.packages."node_modules/electron".version;
      electronMajor = lib.versions.major electronVersion;

      # A tiny static file server used only during the build, to hand
      # @electron/packager's download step a same-version, offline stand-in
      # for the official GitHub release artifacts (see electronFakeRelease
      # below). This is the officially documented "custom mirror" mechanism
      # (ELECTRON_MIRROR) described at
      # https://www.electronjs.org/docs/latest/tutorial/installation#custom-mirrors-and-caches
      mirrorServerScript = pkgs: pkgs.writeText "serve-electron-mirror.js" ''
        const http = require('http');
        const fs = require('fs');
        const path = require('path');

        const root = process.argv[2];
        const port = parseInt(process.argv[3], 10);

        const server = http.createServer((req, res) => {
          const filePath = path.join(root, decodeURIComponent(req.url));
          fs.stat(filePath, (err, stat) => {
            if (err || !stat.isFile()) {
              res.writeHead(404);
              res.end('not found');
              return;
            }
            res.writeHead(200, { 'Content-Length': stat.size });
            fs.createReadStream(filePath).pipe(res);
          });
        });

        server.listen(port, '127.0.0.1', () => {
          console.error('serving ' + root + ' on 127.0.0.1:' + port);
        });
      '';

      mkSelfReview =
        system:
        let
          pkgs = import nixpkgs { inherit system; };
          npmArch = npmArchForSystem.${system};

          # Match the Electron major version this project actually declares
          # (package.json's `electron` devDependency) so packaged app behavior
          # matches what upstream's own CI produces. Falls back loudly (an
          # eval error naming the missing attribute) if nixpkgs ever drops
          # this specific major before the project updates.
          electronPkg = pkgs."electron_${electronMajor}";

          zipName = "electron-v${electronVersion}-linux-${npmArch}.zip";

          # Re-packages nixpkgs' own (already NixOS-patched) Electron build
          # into the exact file layout @electron/packager expects to fetch
          # for the app it's bundling, served later via a loopback-only HTTP
          # mirror so the packaging step never touches the network.
          electronFakeRelease =
            pkgs.runCommand "electron-fake-release-${electronVersion}-${npmArch}"
              {
                nativeBuildInputs = [ pkgs.zip ];
              }
              ''
                mkdir -p payload "$out/v${electronVersion}"
                # -L dereferences symlinks (e.g. libvulkan.so.1, which nixpkgs'
                # Electron build symlinks to a separate vulkan-loader store
                # path). Embedding the real file content keeps this zip fully
                # self-contained: the consuming derivation below has its own,
                # separate build sandbox that only has this zip as an input,
                # not vulkan-loader, so a preserved symlink would dangle there
                # even though it resolves fine in this derivation's sandbox.
                cp -rL ${electronPkg.dist}/. payload/
                (cd payload && zip -r -1 -q "$out/v${electronVersion}/${zipName}" .)
                hash=$(sha256sum "$out/v${electronVersion}/${zipName}" | cut -d' ' -f1)
                echo "$hash *${zipName}" > "$out/v${electronVersion}/SHASUMS256.txt"
              '';

          mirrorPort = "47291";
        in
        pkgs.buildNpmPackage {
          pname = "self-review";
          version = packageJson.version;
          src = self;

          npmDepsHash = "sha256-Opn5W8SbjWjdIyPhyscvgYlEJDiMex/BcF90gj0wiNM=";
          # This is a workspaces monorepo; npm needs to write into the deps
          # cache during `npm ci` rather than only read from it.
          makeCacheWritable = true;

          env = {
            HUSKY = "0";
            # Skip the `electron` package's own postinstall download entirely.
            # It's never used for packaging (@electron/packager fetches its
            # own copy, faked in below); it only matters for `npm start`/dev
            # mode, which is covered separately by devShells.default.
            ELECTRON_SKIP_BINARY_DOWNLOAD = "1";
          };

          dontNpmBuild = true;
          dontNpmInstall = true;

          nativeBuildInputs = [
            pkgs.makeWrapper
            pkgs.copyDesktopItems
            pkgs.unzip
          ];

          buildPhase = ''
            runHook preBuild

            echo "self-review: building workspace packages ($(date -u +%T))"
            # Patch extract-zip to use the `unzip` CLI instead of yauzl.
            # yauzl opens the zip with fs.open() and keeps the fd for random
            # access reads. In the nix sandbox, the fd is somehow closed
            # mid-extraction (event loop empties, process exits with code 0
            # before packaging completes). The `unzip` command avoids this
            # entirely by doing a simple fork+exec extraction.
            cat > node_modules/extract-zip/index.js << 'EXTRACT'
const { execFileSync } = require('child_process');
async function extract(zipPath, opts) {
  const targetDir = opts.dir;
  execFileSync('unzip', ['-o', zipPath, '-d', targetDir], { stdio: 'pipe' });
  execFileSync('chmod', ['-R', 'u+w', targetDir], { stdio: 'pipe' });
}
module.exports = extract;
EXTRACT
            # Disable fork-ts-checker-webpack-plugin during nix build: not
            # needed for packaging (ts-loader uses transpileOnly).
            cat > webpack.plugins.ts << 'PLUGINS'
export const plugins = [];
PLUGINS
            for p in types core react; do
              npm run build --workspace=packages/$p
            done
            echo "self-review: workspace packages built ($(date -u +%T))"

            # Electron Forge shells out to check npm/git versions on every
            # run; this project-documented flag file skips that (see
            # node_modules/@electron-forge/cli/src/util/check-system.ts),
            # which avoids an unrelated npm-version-detection failure when
            # invoked outside of a `npm run` child-process environment.
            touch "$HOME/.skip-forge-system-check"

            node ${mirrorServerScript pkgs} ${electronFakeRelease} ${mirrorPort} &
            mirrorPid=$!
            for i in $(seq 1 50); do
              if (exec 3<>"/dev/tcp/127.0.0.1/${mirrorPort}") 2>/dev/null; then
                exec 3<&- 3>&-
                break
              fi
              sleep 0.1
            done
            echo "self-review: fake electron mirror ready ($(date -u +%T))"

            export ELECTRON_MIRROR="http://127.0.0.1:${mirrorPort}/"
            echo "self-review: starting electron-forge package ($(date -u +%T))"
            set +e
            CI=true npm run package
            packageExit=$?
            set -e
            echo "self-review: electron-forge package finished with exit $packageExit ($(date -u +%T))"
            kill "$mirrorPid" 2>/dev/null || true
            if [ "$packageExit" -ne 0 ]; then
              echo "electron-forge package failed with exit $packageExit"
              exit "$packageExit"
            fi

            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall

            mkdir -p "$out/share/self-review"
            cp -r out/*/. "$out/share/self-review/"

            makeWrapper "$out/share/self-review/self-review" "$out/bin/self-review" \
              --set ELECTRON_DISABLE_SANDBOX 1 \
              --set CHROME_DEVEL_SANDBOX "$out/share/self-review/chrome-sandbox" \
              --prefix LD_LIBRARY_PATH : ${lib.makeLibraryPath (with pkgs; [
                alsa-lib
                expat
                flac
                glib
                gtk3
                libpulseaudio
                libxkbcommon
                libxslt
                mesa
                nspr
                nss
                pango
                libx11
                libxcb
                libxcomposite
                libxdamage
                libxext
                libxfixes
                libxi
                libxrandr
                libxrender
              ])}

            mkdir -p "$out/share/icons/hicolor/scalable/apps"
            cp assets/icon.svg "$out/share/icons/hicolor/scalable/apps/self-review.svg"

            runHook postInstall
          '';

          desktopItems = [
            (pkgs.makeDesktopItem {
              name = "self-review";
              desktopName = "Self Review";
              genericName = "Code Review Tool";
              comment = "GitHub-style PR review UI for local git diffs";
              exec = "self-review";
              icon = "self-review";
              categories = [ "Development" ];
            })
          ];

          meta = {
            description = "GitHub-style PR review UI for local git diffs";
            homepage = "https://github.com/e0ipso/self-review";
            license = lib.licenses.unfree; # package.json says MIT but LICENSE file is proprietary — pending upstream clarification
            platforms = [
              "x86_64-linux"
              "aarch64-linux"
            ];
            mainProgram = "self-review";
          };
        };
    in
    {
      packages = forAllSystems (system: {
        default = mkSelfReview system;
        self-review = mkSelfReview system;
      });

      apps = forAllSystems (system: {
        default = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/self-review";
        };
      });

      devShells = forAllSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
          electronPkg = pkgs."electron_${electronMajor}";
        in
        {
          default = pkgs.mkShell {
            packages = [ pkgs.nodejs_22 ];

            # Makes `npm start` (electron-forge start, dev mode) work under
            # NixOS: redirects the local npm `electron` package's own
            # `require('electron')` resolution at nixpkgs' prebuilt (already
            # NixOS-patched) binary, instead of the generic-Linux binary a
            # plain `npm install` would download and that wouldn't run
            # directly under NixOS. See the CHROME_DEVEL_SANDBOX note below.
            ELECTRON_OVERRIDE_DIST_PATH = "${electronPkg.dist}";
            ELECTRON_DISABLE_SANDBOX = "1";
            # Required or the bundled Chromium binary crashes on startup
            # (SIGILL) before Electron's own sandbox-disable logic runs.
            CHROME_DEVEL_SANDBOX = "${electronPkg.dist}/chrome-sandbox";
          };
        }
      );

      overlays.default = final: _prev: lib.optionalAttrs (builtins.elem final.system supportedSystems) {
        self-review = self.packages.${final.system}.default;
      };
    };
}
