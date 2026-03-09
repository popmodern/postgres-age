{
  pkgs,
  lib,
  stdenv,
  fetchFromGitHub,
  perl,
  postgresql,
  latestOnly ? false,
}:
let
  pname = "age";

  # Load version configuration from external file
  allVersions = (builtins.fromJSON (builtins.readFile ./versions.json)).${pname};

  # Filter versions compatible with current PostgreSQL version
  supportedVersions = lib.filterAttrs (
    _: value: builtins.elem (lib.versions.major postgresql.version) value.postgresql
  ) allVersions;

  # Derived version information
  versions = lib.naturalSort (lib.attrNames supportedVersions);
  latestVersion = lib.last versions;
  versionsToUse =
    if latestOnly then
      { "${latestVersion}" = supportedVersions.${latestVersion}; }
    else
      supportedVersions;
  packages = builtins.attrValues (
    lib.mapAttrs (name: value: build name value.hash value.rev) versionsToUse
  );
  versionsBuilt = if latestOnly then [ latestVersion ] else versions;
  numberOfVersionsBuilt = builtins.length versionsBuilt;

  # Build function for individual versions
  build =
    version: hash: rev:
    stdenv.mkDerivation rec {
      inherit pname version;

      buildInputs = [ postgresql ];
      nativeBuildInputs = [
        pkgs.bison
        pkgs.flex
        perl
      ];

      src = fetchFromGitHub {
        owner = "apache";
        repo = "age";
        inherit rev hash;
      };

      makeFlags = [
        "USE_PGXS=1"
        "BISON=${pkgs.bison}/bin/bison"
        "FLEX=${pkgs.flex}/bin/flex"
        "PERL=${perl}/bin/perl"
      ];

      installPhase = ''
        mkdir -p $out/{lib,share/postgresql/extension}

        # Install shared library with version suffix
        mv ${pname}${postgresql.dlSuffix} $out/lib/${pname}-${version}${postgresql.dlSuffix}

        # Create version-specific control file
        sed -e "/^default_version =/d" \
            -e "s|^module_pathname = .*|module_pathname = '\$libdir/${pname}'|" \
          ${pname}.control > $out/share/postgresql/extension/${pname}--${version}.control

        # Copy SQL files
        cp ${pname}--${version}.sql $out/share/postgresql/extension/

        # For the latest version, copy default control file and symlink
        if [[ "${version}" == "${latestVersion}" ]]; then
          cp *.sql $out/share/postgresql/extension/
          {
            echo "default_version = '${latestVersion}'"
            cat $out/share/postgresql/extension/${pname}--${latestVersion}.control
          } > $out/share/postgresql/extension/${pname}.control
          ln -sfn ${pname}-${latestVersion}${postgresql.dlSuffix} $out/lib/${pname}${postgresql.dlSuffix}
        fi

        runHook postInstall
      '';

      meta = with lib; {
        description = "Apache AGE - A Graph Extension for PostgreSQL";
        homepage = "https://github.com/${src.owner}/${src.repo}";
        platforms = postgresql.meta.platforms;
        license = licenses.asl20;
      };
    };
in
pkgs.buildEnv {
  name = pname;
  paths = packages;
  pathsToLink = [
    "/lib"
    "/share/postgresql/extension"
  ];

  passthru = {
    versions = versionsBuilt;
    numberOfVersions = numberOfVersionsBuilt;
    inherit pname latestOnly;
    version =
      if latestOnly then
        latestVersion
      else
        "multi-" + lib.concatStringsSep "-" (map (v: lib.replaceStrings [ "." ] [ "-" ] v) versions);
  };
}
