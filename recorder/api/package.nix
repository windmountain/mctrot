{ lib
, stdenv
, buildNpmPackage
, nodejs_26
, vips
, ffmpeg-headless
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
      ./live.schema.json
      ./src
      ./test
    ];
  };

  nodejs = nodejs_26;
  # Update after changing package-lock.json:
  #   nix run nixpkgs#prefetch-npm-deps -- package-lock.json
  npmDepsHash = "sha256-d42sYY45G4g+00WRUBBkG20qb983UvyNRRisFqAo0i0=";

  nativeBuildInputs = [ python3 makeWrapper ]
    ++ lib.optional stdenv.hostPlatform.isDarwin cctools;

  # better-sqlite3 ships prebuilt binaries, but the Linux one expects
  # libstdc++ at FHS paths that NixOS doesn't have. Compile it here against
  # this Node instead; its loader prefers build/Release over prebuilds/.
  # force_build=1 is needed: without it, binding.gyp skips compiling when
  # a prebuild exists. node-gyp is the one bundled with this Node's npm.
  npmRebuildFlags = [ "--ignore-scripts" ];
  buildPhase = ''
    runHook preBuild
    (cd node_modules/better-sqlite3 \
      && node ${nodejs_26}/lib/node_modules/npm/node_modules/node-gyp/bin/node-gyp.js \
           rebuild --release --force_build=1 --nodedir=${nodejs_26})
    test -f node_modules/better-sqlite3/build/Release/better_sqlite3.node
    rm -rf node_modules/better-sqlite3/prebuilds
    runHook postBuild
  '';

  # The media tests run the real tools.
  nativeCheckInputs = [ vips ffmpeg-headless ];

  # Node runs the TypeScript directly, so "checking" is the whole build:
  # type-check, then the tests against an in-memory database.
  doCheck = true;
  checkPhase = ''
    runHook preCheck
    node_modules/.bin/tsc
    MCTROT_POST_DIR=${../post} node --test test/
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall
    npm prune --omit=dev --no-save --offline
    mkdir -p $out/lib/api $out/bin
    cp -r package.json src node_modules $out/lib/api/
    # The upload page (recorder/post/), served by the API; main.ts finds it
    # at ../../post from its own file.
    cp -r ${../post} $out/lib/post
    makeWrapper ${nodejs_26}/bin/node $out/bin/mctrot-api \
      --add-flags $out/lib/api/src/main.ts
    # The media worker (its own service, host/api.nix); needs vips and
    # ffmpeg on PATH, which its unit provides.
    makeWrapper ${nodejs_26}/bin/node $out/bin/mctrot-worker \
      --add-flags $out/lib/api/src/worker.ts
    # The weather fetch (mctrot-weather, run by a timer in host/api.nix).
    makeWrapper ${nodejs_26}/bin/node $out/bin/mctrot-weather \
      --add-flags $out/lib/api/src/weather.ts
    # The raw tool; on the box, use mctrot-dislocate (host/api.nix).
    makeWrapper ${nodejs_26}/bin/node $out/bin/mctrot-dislocate-db \
      --add-flags $out/lib/api/src/dislocate.ts
    runHook postInstall
  '';

  meta.mainProgram = "mctrot-api";
}
