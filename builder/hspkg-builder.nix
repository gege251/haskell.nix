{ pkgs, buildPackages, stdenv, lib, haskellLib, ghc, compiler-nix-name, fetchurl, runCommand, comp-builder, setup-builder }:

config:
{ flags
, package
, components
, cabal-generator

, name
, sha256
, src
, revision
, revisionSha256
, patches

, shellHook

, ...
}@pkg:

assert (if ghc.isHaskellNixCompiler or false then true
  else throw ("It is likely you used `haskell.compiler.X` instead of `haskell-nix.compiler.X`"
    + pkgs.lib.optionalString (name != null) (" for " + name)));

let
  # Some packages bundled with GHC are not the same as they are in hackage.
  bundledSrc = {
      # These are problematic because the hackage versions will not install and are part of LTS.
      "ghc902/stm-2.5.0.0" = "/libraries/stm";
      "ghc902/filepath-1.4.2.1" = "/libraries/filepath";
    }."${compiler-nix-name}/${name}" or null;
  src = if bundledSrc == null then pkg.src else ghc.configured-src + bundledSrc;
  cabalFile = if revision == null || revision == 0 || bundledSrc != null then null else
    fetchurl {
      name = "${name}-${toString revision}.cabal";
      url = "https://hackage.haskell.org/package/${name}/revision/${toString revision}.cabal";
      sha256 = revisionSha256;
    };

  defaultSetupSrc = if stdenv.hostPlatform.isGhcjs then ./Setup.ghcjs.hs else ./Setup.hs;

  # Get the Cabal lib used to build `cabal-install`.
  # To avoid infinite recursion we have to leave this out for packages
  # needed to build `cabal-install`.
  # We always do this for ghcjs as the patched version of Cabal is needed.
  cabalLibDepends = lib.optional (
    stdenv.hostPlatform.isGhcjs || (
        builtins.elem compiler-nix-name["ghc865" "ghc884"]
      &&
        !builtins.elem package.identifier.name
          ["nix-tools" "alex" "happy" "hscolour" "Cabal" "bytestring" "aeson" "time"
           "filepath" "base-compat-batteries" "base-compat" "unix" "directory" "transformers"
           "containers" "binary" "mtl" "text" "process" "parsec"]
      )
    )
    buildPackages.haskell-nix.cabal-install-unchecked.${compiler-nix-name}.project.hsPkgs.Cabal.components.library;

  # This logic is needed so that we don't get duplicate packages if we
  # add a custom Cabal package to the dependencies.  That way custom
  # setups won't complain about e.g. binary from the Cabal dependencies
  # and binary from the global package-db.
  nonReinstallablePkgs = if (
    stdenv.hostPlatform.isGhcjs || (
        builtins.elem compiler-nix-name["ghc865" "ghc884"]
      &&
        !builtins.elem package.identifier.name
          ["nix-tools" "alex" "happy" "hscolour" "Cabal" "bytestring" "aeson" "time"
           "filepath" "base-compat-batteries" "base-compat" "unix" "directory" "transformers"
           "containers" "binary" "mtl" "text" "process" "parsec"]
      )
    ) then [] else null;

  defaultSetup = setup-builder ({
    name = "${ghc.targetPrefix}default-Setup";
    component = {
      depends = config.setup-depends ++ cabalLibDepends;
      libs = [];
      frameworks = [];
      doExactConfig = false;
      includeDirs = [];
      asmSources = [];
      cSources = [];
      cmmSources = [];
      cxxSources = [];
      jsSources = [];
      extraSrcFiles = [ "Setup.hs" "Setup.lhs" ];
      pkgconfig = [];
      build-tools = [];

      platforms = null;
      preBuild = null;   postBuild = null;
      preInstall = null; postInstall = null;
      preUnpack = null;  postUnpack = null;
    };
    package = {
      identifier = {
        name = "default-Setup";
        version = "1.0";
      };
      homepage = null;
      synopsis = null;
      license = "MIT";
    };
    src = null;
    cleanSrc = buildPackages.runCommand "default-Setup-src" {} ''
      mkdir $out
      cat ${defaultSetupSrc} > $out/Setup.hs
    '';
    inherit defaultSetupSrc;
  } // (if nonReinstallablePkgs == null then {} else { inherit nonReinstallablePkgs; }));

  # buildPackages.runCommand "default-Setup" { nativeBuildInputs = [(ghc.passthru.buildGHC or ghc)]; } ''
  #   cat ${defaultSetupSrc} > Setup.hs
  #   mkdir -p $out/bin
  #   ${(ghc.passthru.buildGHC or ghc).targetPrefix}ghc Setup.hs --make -o $out/bin/Setup
  # '';

  setup = if package.buildType == "Simple"
    then defaultSetup
    else setup-builder {
      component = components.setup // {
        depends = config.setup-depends ++ components.setup.depends ++ package.setup-depends;
        extraSrcFiles = components.setup.extraSrcFiles ++ [ "Setup.hs" "Setup.lhs" ];
        pkgconfig = if components ? library then components.library.pkgconfig or [] else [];
      };
      inherit package name src flags revision patches defaultSetupSrc;
      inherit (pkg) preUnpack postUnpack;
    };

  buildComp = allComponent: componentId: component: comp-builder {
    inherit allComponent componentId component package name src flags setup cabalFile cabal-generator patches revision
            shellHook
            ;
  };

in rec {
  components = haskellLib.applyComponents (buildComp pkg.allComponent) pkg;
  checks = pkgs.recurseIntoAttrs (builtins.mapAttrs
    (_: d: haskellLib.check d)
      (lib.filterAttrs (_: d: d.config.doCheck) components.tests));
  inherit (package) identifier detailLevel isLocal isProject;
  inherit setup cabalFile;
  isHaskell = true;
  inherit src;
}
