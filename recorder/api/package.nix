{ lib
, stdenv
, buildNpmPackage
, nodejs_26
, node-gyp
, python3
, cctools
, makeWrapper
}:

buildNpmPackage {
  pname = "mctrot-recorder-api";
  version = "0.1.0";

  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./package.json
      ./package-lock.json
      ./tsconfig.json
      ./src
      ./test
    ];
  };

  nodejs = nodejs_26;
  # Update after changing package-lock.json:
  #   nix run nixpkgs#prefetch-npm-deps -- package-lock.json
  npmDepsHash = "sha256-WIrUQyBpqnwJTRZvKRPce0qNhtIHfxRtvhnDX2BFDDk=";

  nativeBuildInputs = [ node-gyp python3 makeWrapper ]
    ++ lib.optional stdenv.hostPlatform.isDarwin cctools;

  # better-sqlite3 ships prebuilt binaries, but the Linux one expects
  # libstdc++ at FHS paths that NixOS doesn't have. Compile it here against
  # this Node instead; its loader prefers build/Release over prebuilds/.
  npmRebuildFlags = [ "--ignore-scripts" ];
  buildPhase = ''
    runHook preBuild
    (cd node_modules/better-sqlite3 \
      && node-gyp rebuild --release --nodedir=${nodejs_26})
    rm -rf node_modules/better-sqlite3/prebuilds
    runHook postBuild
  '';

  # Node runs the TypeScript directly, so "checking" is the whole build:
  # type-check, then the tests against an in-memory database.
  doCheck = true;
  checkPhase = ''
    runHook preCheck
    node_modules/.bin/tsc
    node --test test/
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall
    npm prune --omit=dev --no-save --offline
    mkdir -p $out/lib/api $out/bin
    cp -r package.json src node_modules $out/lib/api/
    makeWrapper ${nodejs_26}/bin/node $out/bin/mctrot-api \
      --add-flags $out/lib/api/src/main.ts
    runHook postInstall
  '';

  meta.mainProgram = "mctrot-api";
}
