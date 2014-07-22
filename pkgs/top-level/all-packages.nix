/* This file composes the Nix Packages collection.  That is, it
   imports the functions that build the various packages, and calls
   them with appropriate arguments.  The result is a set of all the
   packages in the Nix Packages collection for some particular
   platform. */


{ # The system (e.g., `i686-linux') for which to build the packages.
  system ? builtins.currentSystem

  # Usually, the system type uniquely determines the stdenv and thus
  # how to build the packages.  But on some platforms we have
  # different stdenvs, leading to different ways to build the
  # packages.  For instance, on Windows we support both Cygwin and
  # Mingw builds.  In both cases, `system' is `i686-cygwin'.  The
  # attribute `stdenvType' is used to select the specific kind of
  # stdenv to use, e.g., `i686-mingw'.
, stdenvType ? system

, # The standard environment to use.  Only used for bootstrapping.  If
  # null, the default standard environment is used.
  bootStdenv ? null

, # Non-GNU/Linux OSes are currently "impure" platforms, with their libc
  # outside of the store.  Thus, GCC, GFortran, & co. must always look for
  # files in standard system directories (/usr/include, etc.)
  noSysDirs ? (system != "x86_64-darwin"
               && system != "x86_64-freebsd" && system != "i686-freebsd"
               && system != "x86_64-kfreebsd-gnu")

  # More flags for the bootstrapping of stdenv.
, gccWithCC ? true
, gccWithProfiling ? true

, # Allow a configuration attribute set to be passed in as an
  # argument.  Otherwise, it's read from $NIXPKGS_CONFIG or
  # ~/.nixpkgs/config.nix.
  config ? null

, crossSystem ? null
, platform ? null
}:


let config_ = config; platform_ = platform; in # rename the function arguments

let

  lib = import ../../lib;

  # The contents of the configuration file found at $NIXPKGS_CONFIG or
  # $HOME/.nixpkgs/config.nix.
  # for NIXOS (nixos-rebuild): use nixpkgs.config option
  config =
    let
      toPath = builtins.toPath;
      getEnv = x: if builtins ? getEnv then builtins.getEnv x else "";
      pathExists = name:
        builtins ? pathExists && builtins.pathExists (toPath name);

      configFile = getEnv "NIXPKGS_CONFIG";
      homeDir = getEnv "HOME";
      configFile2 = homeDir + "/.nixpkgs/config.nix";

      configExpr =
        if config_ != null then config_
        else if configFile != "" && pathExists configFile then import (toPath configFile)
        else if homeDir != "" && pathExists configFile2 then import (toPath configFile2)
        else {};

    in
      # allow both:
      # { /* the config */ } and
      # { pkgs, ... } : { /* the config */ }
      if builtins.isFunction configExpr
        then configExpr { inherit pkgs; }
        else configExpr;

  # Allow setting the platform in the config file. Otherwise, let's use a reasonable default (pc)

  platformAuto = let
      platforms = (import ./platforms.nix);
    in
      if system == "armv6l-linux" then platforms.raspberrypi
      else if system == "armv5tel-linux" then platforms.sheevaplug
      else if system == "mips64el-linux" then platforms.fuloong2f_n32
      else if system == "x86_64-linux" then platforms.pc64
      else if system == "i686-linux" then platforms.pc32
      else platforms.pcBase;

  platform = if platform_ != null then platform_
    else config.platform or platformAuto;

  # Helper functions that are exported through `pkgs'.
  helperFunctions =
    stdenvAdapters //
    (import ../build-support/trivial-builders.nix { inherit (pkgs) stdenv; inherit (pkgs.xorg) lndir; });

  stdenvAdapters =
    import ../stdenv/adapters.nix pkgs;


  # Allow packages to be overriden globally via the `packageOverrides'
  # configuration option, which must be a function that takes `pkgs'
  # as an argument and returns a set of new or overriden packages.
  # The `packageOverrides' function is called with the *original*
  # (un-overriden) set of packages, allowing packageOverrides
  # attributes to refer to the original attributes (e.g. "foo =
  # ... pkgs.foo ...").
  pkgs = applyGlobalOverrides (config.packageOverrides or (pkgs: {}));


  # Return the complete set of packages, after applying the overrides
  # returned by the `overrider' function (see above).  Warning: this
  # function is very expensive!
  applyGlobalOverrides = overrider:
    let
      # Call the overrider function.  We don't want stdenv overrides
      # in the case of cross-building, or otherwise the basic
      # overrided packages will not be built with the crossStdenv
      # adapter.
      overrides = overrider pkgsOrig //
        (lib.optionalAttrs (pkgsOrig.stdenv ? overrides && crossSystem == null) (pkgsOrig.stdenv.overrides pkgsOrig));

      # The un-overriden packages, passed to `overrider'.
      pkgsOrig = pkgsFun pkgs {};

      # The overriden, final packages.
      pkgs = pkgsFun pkgs overrides;
    in pkgs;


  # The package compositions.
  pkgsFun = pkgs: overrides:
    let
      defaultScope = pkgs // pkgs.xorg;
      autoPackages = lib.listToAttrs
        (map (fn: { name = baseNameOf (toString fn); value = pkgs.callPackage fn { }; })
        (import ../auto-packages.nix));
      self = self_ // autoPackages // overrides;
      self_ = with self; helperFunctions //


# Yes, this isn't properly indented.
{

  # Make some arguments passed to all-packages.nix available
  inherit system stdenvType platform;

  # Allow callPackage to fill in the pkgs argument
  inherit pkgs;


  # We use `callPackage' to be able to omit function arguments that
  # can be obtained from `pkgs' or `pkgs.xorg' (i.e. `defaultScope').
  # Use `newScope' for sets of packages in `pkgs' (see e.g. `gnome'
  # below).
  callPackage = newScope {};

  newScope = extra: lib.callPackageWith (defaultScope // extra);


  # Override system. This is useful to build i686 packages on x86_64-linux.
  forceSystem = system: (import ./all-packages.nix) {
    inherit system;
    inherit bootStdenv noSysDirs gccWithCC gccWithProfiling config
      crossSystem platform;
  };


  # Used by wine, firefox with debugging version of Flash, ...
  pkgsi686Linux = forceSystem "i686-linux";

  callPackage_i686 = lib.callPackageWith (pkgsi686Linux // pkgsi686Linux.xorg);


  # For convenience, allow callers to get the path to Nixpkgs.
  path = ../..;


  ### Symbolic names.

  x11 = if stdenv.isDarwin then darwinX11AndOpenGL else xlibsWrapper;

  # `xlibs' is the set of X library components.  This used to be the
  # old modular X llibraries project (called `xlibs') but now it's just
  # the set of packages in the modular X.org tree (which also includes
  # non-library components like the server, drivers, fonts, etc.).
  xlibs = xorg // {xlibs = xlibsWrapper;};


  ### Helper functions.

  inherit lib config stdenvAdapters;

  inherit (lib) lowPrio hiPrio appendToName makeOverridable;
  inherit (misc) versionedDerivation;

  # Applying this to an attribute set will cause nix-env to look
  # inside the set for derivations.
  recurseIntoAttrs = attrs: attrs // { recurseForDerivations = true; };

  builderDefs = lib.composedArgsAndFun (import ../build-support/builder-defs/builder-defs.nix) {
    inherit stringsWithDeps lib stdenv writeScript
      fetchurl fetchmtn fetchgit;
  };

  builderDefsPackage = builderDefs.builderDefsPackage builderDefs;

  stringsWithDeps = lib.stringsWithDeps;


  ### Nixpkgs maintainer tools

  nix-generate-from-cpan = callPackage ../../maintainers/scripts/nix-generate-from-cpan.nix { };

  nixpkgs-lint = callPackage ../../maintainers/scripts/nixpkgs-lint.nix { };


  ### STANDARD ENVIRONMENT


  allStdenvs = import ../stdenv {
    inherit system stdenvType platform config;
    allPackages = args: import ./all-packages.nix ({ inherit config system; } // args);
  };

  defaultStdenv = allStdenvs.stdenv // { inherit platform; };

  stdenvCross = lowPrio (makeStdenvCross defaultStdenv crossSystem binutilsCross gccCrossStageFinal);

  stdenv =
    if bootStdenv != null then (bootStdenv // {inherit platform;}) else
      if crossSystem != null then
        stdenvCross
      else
        let
            changer = config.replaceStdenv or null;
        in if changer != null then
          changer {
            # We import again all-packages to avoid recursivities.
            pkgs = import ./all-packages.nix {
              # We remove packageOverrides to avoid recursivities
              config = removeAttrs config [ "replaceStdenv" ];
            };
          }
      else
        defaultStdenv;

  forceNativeDrv = drv : if crossSystem == null then drv else
    (drv // { crossDrv = drv.nativeDrv; });

  # A stdenv capable of building 32-bit binaries.  On x86_64-linux,
  # it uses GCC compiled with multilib support; on i686-linux, it's
  # just the plain stdenv.
  stdenv_32bit = lowPrio (
    if system == "x86_64-linux" then
      overrideGCC stdenv gcc48_multi
    else
      stdenv);


  ### BUILD SUPPORT

  attrSetToDir = arg: import ../build-support/upstream-updater/attrset-to-dir.nix {
    inherit writeTextFile stdenv lib;
    theAttrSet = arg;
  };

  autoreconfHook = makeSetupHook
    { substitutions = { inherit autoconf automake libtool; }; }
    ../build-support/setup-hooks/autoreconf.sh;

  buildEnv = import ../build-support/buildenv {
    inherit (pkgs) runCommand perl;
  };

  buildFHSChrootEnv = import ../build-support/build-fhs-chrootenv {
    inherit stdenv glibc glibcLocales gcc coreutils diffutils findutils;
    inherit gnused gnugrep gnutar gzip bzip2 bashInteractive xz shadow gawk;
    inherit less buildEnv;
  };

  dotnetenv = import ../build-support/dotnetenv {
    inherit stdenv;
    dotnetfx = dotnetfx40;
  };

  scatterOutputHook = makeSetupHook {} ../build-support/setup-hooks/scatter_output.sh;

  vsenv = callPackage ../build-support/vsenv {
    vs = vs90wrapper;
  };

  fetchbower = import ../build-support/fetchbower {
    inherit stdenv git;
    inherit (nodePackages) fetch-bower;
  };

  fetchbzr = import ../build-support/fetchbzr {
    inherit stdenv bazaar;
  };

  fetchcvs = import ../build-support/fetchcvs {
    inherit stdenv cvs;
  };

  fetchdarcs = import ../build-support/fetchdarcs {
    inherit stdenv darcs nix;
  };

  fetchgit = import ../build-support/fetchgit {
    inherit stdenv git cacert;
  };

  fetchgitPrivate = import ../build-support/fetchgit/private.nix {
    inherit fetchgit writeScript openssh stdenv;
  };

  fetchgitrevision = import ../build-support/fetchgitrevision runCommand git;

  fetchmtn = callPackage ../build-support/fetchmtn (config.fetchmtn or {});

  fetchsvn = import ../build-support/fetchsvn {
    inherit stdenv subversion openssh;
    sshSupport = true;
  };

  fetchsvnrevision = import ../build-support/fetchsvnrevision runCommand subversion;

  fetchsvnssh = import ../build-support/fetchsvnssh {
    inherit stdenv subversion openssh expect;
    sshSupport = true;
  };

  fetchhg = import ../build-support/fetchhg {
    inherit stdenv mercurial nix;
  };

  # `fetchurl' downloads a file from the network.
  fetchurl = import ../build-support/fetchurl {
    inherit curl stdenv;
  };

  # A wrapper around fetchurl that generates miror://gnome URLs automatically
  fetchurlGnome = callPackage ../build-support/fetchurl/gnome.nix { };

  # fetchurlBoot is used for curl and its dependencies in order to
  # prevent a cyclic dependency (curl depends on curl.tar.bz2,
  # curl.tar.bz2 depends on fetchurl, fetchurl depends on curl).  It
  # uses the curl from the previous bootstrap phase (e.g. a statically
  # linked curl in the case of stdenv-linux).
  fetchurlBoot = stdenv.fetchurlBoot;

  fetchzip = import ../build-support/fetchzip { inherit lib fetchurl unzip; };

  fetchFromGitHub = { owner, repo, rev, sha256 }: fetchzip {
    name = "${repo}-${rev}-src";
    url = "https://github.com/${owner}/${repo}/archive/${rev}.tar.gz";
    inherit sha256;
  };

  resolveMirrorURLs = {url}: fetchurl {
    showURLs = true;
    inherit url;
  };

  makeDesktopItem = import ../build-support/make-desktopitem {
    inherit stdenv;
  };

  makeAutostartItem = import ../build-support/make-startupitem {
    inherit stdenv;
    inherit lib;
  };

  makeInitrd = {contents, compressor ? "gzip -9"}:
    import ../build-support/kernel/make-initrd.nix {
      inherit stdenv perl perlArchiveCpio cpio contents ubootChooser compressor;
    };

  makeWrapper = makeSetupHook { } ../build-support/setup-hooks/make-wrapper.sh;

  makeModulesClosure = { kernel, rootModules, allowMissing ? false }:
    import ../build-support/kernel/modules-closure.nix {
      inherit stdenv kmod kernel nukeReferences rootModules allowMissing;
    };

  pathsFromGraph = ../build-support/kernel/paths-from-graph.pl;

  srcOnly = args: (import ../build-support/src-only) ({inherit stdenv; } // args);

  substituteAll = import ../build-support/substitute/substitute-all.nix {
    inherit stdenv;
  };

  replaceDependency = import ../build-support/replace-dependency.nix {
    inherit runCommand nix lib;
  };

  nukeReferences = callPackage ../build-support/nuke-references/default.nix { };

  vmTools = import ../build-support/vm/default.nix {
    inherit pkgs;
  };

  releaseTools = import ../build-support/release/default.nix {
    inherit pkgs;
  };

  composableDerivation = (import ../../lib/composable-derivation.nix) {
    inherit pkgs lib;
  };

  platforms = import ./platforms.nix;

  setJavaClassPath = makeSetupHook { } ../build-support/setup-hooks/set-java-classpath.sh;

  fixDarwinDylibNames = makeSetupHook { } ../build-support/setup-hooks/fix-darwin-dylib-names.sh;

  keepBuildTree = makeSetupHook { } ../build-support/setup-hooks/keep-build-tree.sh;

  enableGCOVInstrumentation = makeSetupHook { } ../build-support/setup-hooks/enable-coverage-instrumentation.sh;

  makeGCOVReport = makeSetupHook
    { deps = [ pkgs.lcov pkgs.enableGCOVInstrumentation ]; }
    ../build-support/setup-hooks/make-coverage-analysis-report.sh;


  ### TOOLS

  acoustidFingerprinter = callPackage ../tools/audio/acoustid-fingerprinter {
    ffmpeg = ffmpeg_1;
  };

  actdiag = pythonPackages.actdiag;

  aegisub = callPackage ../applications/video/aegisub {
    wxGTK = wxGTK30;
    lua = lua5_1;
  };

  aircrackng = callPackage ../tools/networking/aircrack-ng { };

  apktool = callPackage ../development/tools/apktool {
    buildTools = androidenv.buildTools;
  };

  arduino_core = callPackage ../development/arduino/arduino-core {
    jdk = jdk;
    jre = jdk;
  };

  asymptote = builderDefsPackage ../tools/graphics/asymptote {
    inherit freeglut ghostscriptX imagemagick fftw boehmgc
      mesa ncurses readline gsl libsigsegv python zlib perl
      texinfo xz;
    texLive = texLiveAggregationFun {
      paths = [ texLive texLiveExtra texLiveCMSuper ];
    };
  };

  ec2_api_tools = callPackage ../tools/virtualization/ec2-api-tools { };

  ec2_ami_tools = callPackage ../tools/virtualization/ec2-ami-tools { };

  amuleDaemon = appendToName "daemon" (amule.override {
    monolithic = false;
    daemon = true;
  });

  amuleGui = appendToName "gui" (amule.override {
    monolithic = false;
    client = true;
  });

  androidenv = import ../development/mobile/androidenv {
    inherit pkgs;
    pkgs_i686 = pkgsi686Linux;
  };

  pass = callPackage ../tools/security/pass {
    gnupg = gnupg1compat;
  };

  titaniumenv = callPackage ../development/mobile/titaniumenv {
    inherit pkgs;
    pkgs_i686 = pkgsi686Linux;
  };

  inherit (androidenv) androidsdk_4_1;

  aria = aria2;

  autorandr = callPackage ../tools/misc/autorandr {
    inherit (xorg) xrandr xdpyinfo;
  };

  avahi = callPackage ../development/libraries/avahi {
    qt4Support = config.avahi.qt4Support or false;
  };

  aws_mturk_clt = callPackage ../tools/misc/aws-mturk-clt { };

  bitbucket-cli = pythonPackages.bitbucket-cli;

  blockdiag = pythonPackages.blockdiag;

  btrfsProgs = callPackage ../tools/filesystems/btrfsprogs { };

  bwm_ng = callPackage ../tools/networking/bwm-ng { };

  coprthr = callPackage ../development/libraries/coprthr {
    flex = flex_2_5_35;
  };

  fasd = callPackage ../tools/misc/fasd {
    inherit (haskellPackages) pandoc;
  };

  syslogng = callPackage ../tools/system/syslog-ng { };

  syslogng_incubator = callPackage ../tools/system/syslog-ng-incubator { };

  asciidoc = callPackage ../tools/typesetting/asciidoc {
    inherit (pythonPackages) matplotlib numpy aafigure recursivePthLoader;
    enableStandardFeatures = false;
  };

  asciidoc-full = appendToName "full" (asciidoc.override {
    inherit (pythonPackages) pygments;
    enableStandardFeatures = true;
  });

  biber = callPackage ../tools/typesetting/biber {
    inherit (perlPackages)
      autovivification BusinessISBN BusinessISMN BusinessISSN ConfigAutoConf
      DataCompare DataDump DateSimple EncodeEUCJPASCII EncodeHanExtra EncodeJIS2K
      ExtUtilsLibBuilder FileSlurp IPCRun3 Log4Perl LWPProtocolHttps ListAllUtils
      ListMoreUtils ModuleBuild MozillaCA ReadonlyXS RegexpCommon TextBibTeX
      UnicodeCollate UnicodeLineBreak URI XMLLibXMLSimple XMLLibXSLT XMLWriter;
  };

  bibtextools = callPackage ../tools/typesetting/bibtex-tools {
    inherit (strategoPackages016) strategoxt sdf;
  };

  bittorrent = callPackage ../tools/networking/p2p/bittorrent {
    gui = true;
  };

  bittornado = callPackage ../tools/networking/p2p/bit-tornado { };

  blueman = callPackage ../tools/bluetooth/blueman {
    inherit (pythonPackages) notify;
  };

  bmrsa = builderDefsPackage (import ../tools/security/bmrsa/11.nix) {
    inherit unzip;
  };

  bup = callPackage ../tools/backup/bup {
    inherit (pythonPackages) pyxattr pylibacl setuptools fuse;
    inherit (haskellPackages) pandoc;
    par2Support = (config.bup.par2Support or false);
  };

  cfdg = builderDefsPackage ../tools/graphics/cfdg {
    inherit libpng bison flex ffmpeg;
  };

  cheetahTemplate = builderDefsPackage (import ../tools/text/cheetah-template/2.0.1.nix) {
    inherit makeWrapper python;
  };

  "unionfs-fuse" = callPackage ../tools/filesystems/unionfs-fuse { };

  usb_modeswitch = callPackage ../development/tools/misc/usb-modeswitch { };

  cloc = callPackage ../tools/misc/cloc {
    inherit (perlPackages) perl AlgorithmDiff RegexpCommon;
  };

  cloogppl = callPackage ../development/libraries/cloog-ppl { };

  coreutils = callPackage ../tools/misc/coreutils
    {
      # TODO: Add ACL support for cross-Linux.
      aclSupport = crossSystem == null && stdenv.isLinux;
    };

  cudatoolkit5 = callPackage ../development/compilers/cudatoolkit/5.5.nix {
    python = python26;
  };

  cudatoolkit6 = callPackage ../development/compilers/cudatoolkit/6.0.nix {
    python = python26;
  };

  cudatoolkit = cudatoolkit5;

  curl = callPackage ../tools/networking/curl rec {
    fetchurl = fetchurlBoot;
    zlibSupport = true;
    sslSupport = zlibSupport;
    scpSupport = zlibSupport && !stdenv.isSunOS && !stdenv.isCygwin;
  };

  curl3 = callPackage ../tools/networking/curl/7.15.nix rec {
    zlibSupport = true;
    sslSupport = zlibSupport;
  };

  dadadodo = builderDefsPackage (import ../tools/text/dadadodo) { };

  debian_devscripts = callPackage ../tools/misc/debian-devscripts {
    inherit (perlPackages) CryptSSLeay LWP TimeDate DBFile FileDesktopEntry;
  };

  deluge = pythonPackages.deluge;

  desktop_file_utils = callPackage ../tools/misc/desktop-file-utils { };

  docbook2odf = callPackage ../tools/typesetting/docbook2odf {
    inherit (perlPackages) PerlMagick;
  };

  docbook2x = callPackage ../tools/typesetting/docbook2x {
    inherit (perlPackages) XMLSAX XMLParser XMLNamespaceSupport;
  };

  duplicity = callPackage ../tools/backup/duplicity {
    inherit (pythonPackages) boto lockfile;
    gnupg = gnupg1;
  };

  dvdplusrwtools = callPackage ../tools/cd-dvd/dvd+rw-tools { };

  ebook_tools = callPackage ../tools/text/ebook-tools { };

  editres = callPackage ../tools/graphics/editres {
    inherit (xlibs) libXt libXaw;
    inherit (xorg) utilmacros;
  };

  enblendenfuse = callPackage ../tools/graphics/enblend-enfuse {
    boost = boost149;
  };

  enscript = callPackage ../tools/text/enscript {
    # fix syntax errors
    stdenv = if stdenv.isDarwin
      then clangStdenv
      else stdenv;
  };

  euca2ools = callPackage ../tools/virtualization/euca2ools { pythonPackages = python26Packages; };

  fabric = pythonPackages.fabric;

  finger_bsd = callPackage ../tools/networking/bsd-finger { };

  flashtool = callPackage_i686 ../development/mobile/flashtool {
    platformTools = androidenv.platformTools;
  };

  fdk_aac = callPackage ../development/libraries/fdk-aac { };

  fontforge = lowPrio (callPackage ../tools/misc/fontforge { });

  fontforgeX = callPackage ../tools/misc/fontforge {
    withX11 = true;
  };

  fox = callPackage ../development/libraries/fox/default.nix {
    libpng = libpng12;
  };

  fox_1_6 = callPackage ../development/libraries/fox/fox-1.6.nix { };

  freetalk = callPackage ../applications/networking/instant-messengers/freetalk {
    guile = guile_1_8;
  };

  ftgl212 = callPackage ../development/libraries/ftgl/2.1.2.nix { };

  fuppes = callPackage ../tools/networking/fuppes {
    ffmpeg = ffmpeg_0_6_90;
  };

  fuse_zip = callPackage ../tools/filesystems/fuse-zip { };

  fuse_exfat = callPackage ../tools/filesystems/fuse-exfat { };

  galculator = callPackage ../applications/misc/galculator {
    gtk = gtk3;
  };

  gawkInteractive = appendToName "interactive"
    (gawk.override { readlineSupport = true; });

  gbdfed = callPackage ../tools/misc/gbdfed {
    gtk = gtk2;
  };

  gnokii = builderDefsPackage (import ../tools/misc/gnokii) {
    inherit intltool perl gettext libusb pkgconfig bluez readline pcsclite
      libical gtk glib;
    inherit (xorg) libXpm;
  };

  gnufdisk = callPackage ../tools/system/fdisk {
    guile = guile_1_8;
  };

  gnugrep = callPackage ../tools/text/gnugrep {
    libiconv = libiconvOrNull;
  };

  gnupg1orig = callPackage ../tools/security/gnupg1 { };

  # use config.packageOverrides if you prefer original gnupg1
  gnupg1 = gnupg1compat;

  gnupg = callPackage ../tools/security/gnupg { libusb = libusb1; };

  gnupg2_1 = lowPrio (callPackage ../tools/security/gnupg/git.nix {
    libassuan = libassuan2_1;
  });

  gnuplot = callPackage ../tools/graphics/gnuplot {
    texLive = null;
    lua = null;
    texinfo = texinfo4; # build errors with gnuplot-4.6.3

    # use gccApple to compile on darwin, seems to resolve a malloc error
    stdenv = if stdenv.isDarwin
      then stdenvAdapters.overrideGCC stdenv gccApple
      else stdenv;
  };

  # must have AquaTerm installed separately
  gnuplot_aquaterm = gnuplot.override { aquaterm = true; };

  googleAuthenticator = callPackage ../os-specific/linux/google-authenticator { };

  /* Readded by Michael Raskin. There are programs in the wild
   * that do want 2.0 but not 2.22. Please give a day's notice for
   * objections before removal.
   */
  graphviz_2_0 = callPackage ../tools/graphics/graphviz/2.0.nix { };

  grive = callPackage ../tools/filesystems/grive {
    json_c = json-c-0-11; # won't configure with 0.12; others are vulnerable
  };

  groff = callPackage ../tools/text/groff {
    ghostscript = null;
  };

  grub = callPackage_i686 ../tools/misc/grub {
    buggyBiosCDSupport = config.grub.buggyBiosCDSupport or true;
  };

  grub2 = callPackage ../tools/misc/grub/2.0x.nix { libusb = libusb1; flex = flex_2_5_35; };

  grub2_efi = grub2.override { EFIsupport = true; };

  gssdp = callPackage ../development/libraries/gssdp {
    inherit (gnome) libsoup;
  };

  gtkgnutella = callPackage ../tools/networking/p2p/gtk-gnutella { };

  gtkvnc = callPackage ../tools/admin/gtk-vnc {};

  gupnp = callPackage ../development/libraries/gupnp {
    inherit (gnome) libsoup;
  };

  gupnp_av = callPackage ../development/libraries/gupnp-av {};

  gupnp_igd = callPackage ../development/libraries/gupnp-igd {};

  gupnptools = callPackage ../tools/networking/gupnp-tools {};

  gvpe = builderDefsPackage ../tools/networking/gvpe {
    inherit openssl gmp nettools iproute;
  };

  hdf5 = callPackage ../tools/misc/hdf5 {
    szip = null;
  };

  highlight = callPackage ../tools/text/highlight {
    lua = lua5;
  };

  httpfs2 = callPackage ../tools/filesystems/httpfs { };

  # FIXME: This Hydra snapshot is outdated and depends on the `nixPerl',
  # which no longer exists.
  #
  # hydra = callPackage ../development/tools/misc/hydra {
  #   nix = nixUnstable;
  # };

  imapsync = callPackage ../tools/networking/imapsync {
    inherit (perlPackages) MailIMAPClient;
  };

  ipmitool = callPackage ../tools/system/ipmitool {
    static = false;
  };

  isl_0_12 = callPackage ../development/libraries/isl/0.12.2.nix { };

  jd-gui = callPackage_i686 ../tools/security/jd-gui { };

  jfsrec = callPackage ../tools/filesystems/jfsrec {
    boost = boost144;
  };

  lockfileProgs = callPackage ../tools/misc/lockfile-progs { };

  minidlna = callPackage ../tools/networking/minidlna {
    ffmpeg = ffmpeg_0_10;
  };

  nodePackages = recurseIntoAttrs (import ./node-packages.nix {
    inherit pkgs stdenv nodejs fetchurl fetchgit;
    neededNatives = [python] ++ lib.optional (lib.elem system lib.platforms.linux) utillinux;
    self = pkgs.nodePackages;
  });

  libtirpc = callPackage ../development/libraries/ti-rpc { };

  logcheck = callPackage ../tools/system/logcheck {
    inherit (perlPackages) mimeConstruct;
  };

  # lsh installs `bin/nettle-lfib-stream' and so does Nettle.  Give the
  # former a lower priority than Nettle.
  lsh = lowPrio (callPackage ../tools/networking/lsh { });

  lzma = xz;

  mailutils = callPackage ../tools/networking/mailutils {
    guile = guile_1_8;
  };

  man_db = callPackage ../tools/misc/man-db { };

  memtest86plus = callPackage ../tools/misc/memtest86+ { };

  mcron = callPackage ../tools/system/mcron {
    guile = guile_1_8;
  };

  mdbtools_git = callPackage ../tools/misc/mdbtools/git.nix {
    inherit (gnome) scrollkeeper;
  };

  mednafen-server = callPackage ../misc/emulators/mednafen/server.nix { };

  minetest = callPackage ../games/minetest {
    libpng = libpng12;
  };

  mosh = callPackage ../tools/networking/mosh {
    boost = boostHeaders;
    inherit (perlPackages) IOTty;
  };

  msf = builderDefsPackage (import ../tools/security/metasploit/3.1.nix) {
    inherit ruby makeWrapper;
  };

  multitran = recurseIntoAttrs (let callPackage = newScope pkgs.multitran; in rec {
    multitrandata = callPackage ../tools/text/multitran/data { };

    libbtree = callPackage ../tools/text/multitran/libbtree { };

    libmtsupport = callPackage ../tools/text/multitran/libmtsupport { };

    libfacet = callPackage ../tools/text/multitran/libfacet { };

    libmtquery = callPackage ../tools/text/multitran/libmtquery { };

    mtutils = callPackage ../tools/text/multitran/mtutils { };
  });

  netkittftp = callPackage ../tools/networking/netkit/tftp { };

  networkmanager = callPackage ../tools/networking/network-manager { };

  networkmanager_openvpn = callPackage ../tools/networking/network-manager/openvpn.nix { };

  networkmanager_pptp = callPackage ../tools/networking/network-manager/pptp.nix { };

  networkmanager_vpnc = callPackage ../tools/networking/network-manager/vpnc.nix { };

  networkmanager_openconnect = callPackage ../tools/networking/network-manager/openconnect.nix { };

  networkmanagerapplet = newScope gnome ../tools/networking/network-manager-applet { dconf = gnome3.dconf; };

  newsbeuter-dev = callPackage ../applications/networking/feedreaders/newsbeuter/dev.nix { };

  pa_applet = callPackage ../tools/audio/pa-applet { };

  nilfs_utils = callPackage ../tools/filesystems/nilfs-utils {};

  npapi_sdk = callPackage ../development/libraries/npapi-sdk {};

  nmap_graphical = callPackage ../tools/security/nmap {
    inherit (pythonPackages) pysqlite;
    graphicalSupport = true;
  };

  nss_pam_ldapd = callPackage ../tools/networking/nss-pam-ldapd {};

  ntfs3g = callPackage ../tools/filesystems/ntfs-3g { };

  # ntfsprogs are merged into ntfs-3g
  ntfsprogs = pkgs.ntfs3g;

  nssmdns = callPackage ../tools/networking/nss-mdns { };

  nwdiag = pythonPackages.nwdiag;

  oathToolkit = callPackage ../tools/security/oath-toolkit { };

  obex_data_server = callPackage ../tools/bluetooth/obex-data-server { };

  offlineimap = callPackage ../tools/networking/offlineimap {
    inherit (pythonPackages) sqlite3;
  };

  opendylan = callPackage ../development/compilers/opendylan {
    opendylan-bootstrap = opendylan_bin;
  };

  opendylan_bin = callPackage ../development/compilers/opendylan/bin.nix { };

  openjade = callPackage ../tools/text/sgml/openjade {
    perl = perl510;
  };

  openopc = callPackage ../tools/misc/openopc {
    pythonFull = python27Full.override {
      extraLibs = [ python27Packages.pyro3 ];
    };
  };

  opensc_dnie_wrapper = callPackage ../tools/security/opensc-dnie-wrapper { };

  openssh =
    callPackage ../tools/networking/openssh {
      hpnSupport = false;
      withKerberos = false;
      etcDir = "/etc/ssh";
      pam = if stdenv.isLinux then pam else null;
    };

  openssh_hpn = pkgs.appendToName "with-hpn" (openssh.override { hpnSupport = true; });

  openssh_with_kerberos = pkgs.appendToName "with-kerberos" (openssh.override { withKerberos = true; });

  spCompat = callPackage ../tools/text/sgml/opensp/compat.nix { };

  openvpn_learnaddress = callPackage ../tools/networking/openvpn/openvpn_learnaddress.nix { };

  optipng = callPackage ../tools/graphics/optipng {
    libpng = libpng12;
  };

  parted = callPackage ../tools/misc/parted { hurd = null; };

  pitivi = callPackage ../applications/video/pitivi {
    gst = gst_all_1;
    clutter-gtk = clutter_gtk;
    inherit (gnome3) gnome_icon_theme gnome_icon_theme_symbolic;
  };

  hurdPartedCross =
    if crossSystem != null && crossSystem.config == "i586-pc-gnu"
    then (makeOverridable
            ({ hurd }:
              (parted.override {
                # Needs the Hurd's libstore.
                inherit hurd;

                # The Hurd wants a libparted.a.
                enableStatic = true;

                gettext = null;
                readline = null;
                devicemapper = null;
              }).crossDrv)
           { hurd = gnu.hurdCrossIntermediate; })
    else null;

  ipsecTools = callPackage ../os-specific/linux/ipsec-tools { flex = flex_2_5_35; };

  patch = gnupatch;

  pdsh = callPackage ../tools/networking/pdsh {
    rsh = true;          # enable internal rsh implementation
    ssh = openssh;
  };

  ploticus = callPackage ../tools/graphics/ploticus {
    libpng = libpng12;
  };

  pngtoico = callPackage ../tools/graphics/pngtoico {
    libpng = libpng12;
  };

  polkit_gnome = callPackage ../tools/security/polkit-gnome { };

  prey-bash-client = callPackage ../tools/security/prey { };

  pystringtemplate = callPackage ../development/python-modules/stringtemplate { };

  pythonDBus = dbus_python;

  pythonIRClib = builderDefsPackage (import ../development/python-modules/irclib) {
    inherit python;
  };

  pythonSexy = builderDefsPackage (import ../development/python-modules/libsexy) {
    inherit python libsexy pkgconfig libxml2 pygtk pango gtk glib;
  };

  reaverwps = callPackage ../tools/networking/reaver-wps {};

  relfs = callPackage ../tools/filesystems/relfs {
    inherit (gnome) gnome_vfs GConf;
  };

  rdiff_backup = callPackage ../tools/backup/rdiff-backup { };

  riemann_c_client = callPackage ../tools/misc/riemann-c-client { };

  rng_tools = callPackage ../tools/security/rng-tools { };

  rsnapshot = callPackage ../tools/backup/rsnapshot {
    # For the `logger' command, we can use either `utillinux' or
    # GNU Inetutils.  The latter is more portable.
    logger = inetutils;
  };

  rockbox_utility = callPackage ../tools/misc/rockbox-utility { };

  rpPPPoE = builderDefsPackage (import ../tools/networking/rp-pppoe) {
    inherit ppp;
  };

  s3cmd_15_pre_81e3842f7a = lowPrio (callPackage ../tools/networking/s3cmd/git.nix { });

  s3sync = callPackage ../tools/networking/s3sync {
    ruby = ruby18;
  };

  salut_a_toi = callPackage ../applications/networking/instant-messengers/salut-a-toi {};

  setserial = builderDefsPackage (import ../tools/system/setserial) {
    inherit groff;
  };

  seqdiag = pythonPackages.seqdiag;

  silc_client = callPackage ../applications/networking/instant-messengers/silc-client { };

  silc_server = callPackage ../servers/silc-server { };

  slimrat = callPackage ../tools/networking/slimrat {
    inherit (perlPackages) WWWMechanize LWP;
  };

  smbldaptools = callPackage ../tools/networking/smbldaptools {
    inherit (perlPackages) NetLDAP CryptSmbHash DigestSHA1;
  };

  snx = callPackage_i686 ../tools/networking/snx {
    inherit (pkgsi686Linux) pam gcc33;
    inherit (pkgsi686Linux.xlibs) libX11;
  };

  sproxy = haskellPackages.callPackage ../tools/networking/sproxy { };

  sproxy-web = haskellPackages.callPackage ../tools/networking/sproxy-web { };

  stardict = callPackage ../applications/misc/stardict/stardict.nix {
    inherit (gnome) libgnomeui scrollkeeper;
  };

  socat2pre = lowPrio (callPackage ../tools/networking/socat/2.x.nix { });

  sourceHighlight = callPackage ../tools/text/source-highlight {
    # Boost 1.54 causes the "test_regexranges" test to fail
    boost = boost149;
  };

  spaceFM = callPackage ../applications/misc/spacefm { };

  squashfsTools = callPackage ../tools/filesystems/squashfs { };

  sshfsFuse = callPackage ../tools/filesystems/sshfs-fuse { };

  suidChroot = builderDefsPackage (import ../tools/system/suid-chroot) { };

  ssmtp = callPackage ../tools/networking/ssmtp {
    tlsSupport = true;
  };

  storeBackup = callPackage ../tools/backup/store-backup { };

  su = shadow.su;

  swec = callPackage ../tools/networking/swec {
    inherit (perlPackages) LWP URI HTMLParser HTTPServerSimple Parent;
  };

  system_config_printer = callPackage ../tools/misc/system-config-printer {
    libxml2 = libxml2Python;
   };

  teamviewer = callPackage_i686 ../applications/networking/remote/teamviewer { };

  # Work In Progress: it doesn't start unless running a daemon as root
  teamviewer8 = lowPrio (callPackage_i686 ../applications/networking/remote/teamviewer/8.nix { });

  texmacs = callPackage ../applications/editors/texmacs {
    tex = texLive; /* tetex is also an option */
    extraFonts = true;
    guile = guile_1_8;
  };

  tiled-qt = callPackage ../applications/editors/tiled-qt { qt = qt4; };

  tiny8086 = callPackage ../applications/virtualization/8086tiny { };

  torbrowser = callPackage ../tools/security/tor/torbrowser.nix { };

  torsocks = callPackage ../tools/security/tor/torsocks.nix { };

  twitterBootstrap = callPackage ../development/web/twitter-bootstrap {};

  vbetool = builderDefsPackage ../tools/system/vbetool {
    inherit pciutils libx86 zlib;
  };

  viking = callPackage ../applications/misc/viking {
    inherit (gnome) scrollkeeper;
  };

  vncrec = builderDefsPackage ../tools/video/vncrec {
    inherit (xlibs) imake libX11 xproto gccmakedep libXt
      libXmu libXaw libXext xextproto libSM libICE libXpm
      libXp;
  };

  openconnect = callPackage ../tools/networking/openconnect.nix { };

  wal_e = callPackage ../tools/backup/wal-e { };

  htmlTidy = callPackage ../tools/text/html-tidy { };

  tftp_hpa = callPackage ../tools/networking/tftp-hpa {};

  tigervnc = callPackage ../tools/admin/tigervnc {
    fontDirectories = [ xorg.fontadobe75dpi xorg.fontmiscmisc xorg.fontcursormisc
      xorg.fontbhlucidatypewriter75dpi ];
    inherit (xorg) xorgserver;
    fltk = fltk13;
  };

  tightvnc = callPackage ../tools/admin/tightvnc {
    fontDirectories = [ xorg.fontadobe75dpi xorg.fontmiscmisc xorg.fontcursormisc
      xorg.fontbhlucidatypewriter75dpi ];
  };

  tkgate = callPackage ../applications/science/electronics/tkgate/1.x.nix {
    inherit (xlibs) libX11 imake xproto gccmakedep;
  };

  # The newer package is low-priority because it segfaults at startup.
  tkgate2 = lowPrio (callPackage ../applications/science/electronics/tkgate/2.x.nix {
    inherit (xlibs) libX11;
  });

  transfig = callPackage ../tools/graphics/transfig {
    libpng = libpng12;
  };

  truecrypt = callPackage ../applications/misc/truecrypt {
    wxGUI = config.truecrypt.wxGUI or true;
  };

  unzipNLS = lowPrio (unzip.override { enableNLS = true; });

  varnish2 = callPackage ../servers/varnish/2.1.nix { };

  venus = callPackage ../tools/misc/venus {
    python = python27;
  };

  w3cCSSValidator = callPackage ../tools/misc/w3c-css-validator {
    tomcat = tomcat6;
  };

  webdruid = builderDefsPackage ../tools/admin/webdruid {
    inherit zlib libpng freetype gd which
      libxml2 geoip;
  };

  wget = callPackage ../tools/networking/wget {
    inherit (perlPackages) LWP;
  };

  x11_ssh_askpass = callPackage ../tools/networking/x11-ssh-askpass { };

  xbursttools = assert stdenv ? glibc; import ../tools/misc/xburst-tools {
    inherit stdenv fetchgit autoconf automake confuse pkgconfig libusb libusb1;
    # It needs a cross compiler for mipsel to build the firmware it will
    # load into the Ben Nanonote
    gccCross =
      let
        pkgsCross = (import ./all-packages.nix) {
          inherit system;
          inherit bootStdenv noSysDirs gccWithCC gccWithProfiling config;
          # Ben Nanonote system
          crossSystem = {
            config = "mipsel-unknown-linux";
            bigEndian = true;
            arch = "mips";
            float = "soft";
            withTLS = true;
            libc = "uclibc";
            platform = {
              name = "ben_nanonote";
              kernelMajor = "2.6";
              # It's not a bcm47xx processor, but for the headers this should work
              kernelHeadersBaseConfig = "bcm47xx_defconfig";
              kernelArch = "mips";
            };
            gcc = {
              arch = "mips32";
            };
          };
        };
      in
        pkgsCross.gccCrossStageStatic;
  };

  xmlroff = callPackage ../tools/typesetting/xmlroff {
    inherit (gnome) libgnomeprint;
  };

  xmpppy = builderDefsPackage (import ../development/python-modules/xmpppy) {
    inherit python setuptools;
  };

  xpf = callPackage ../tools/text/xml/xpf {
    libxml2 = libxml2Python;
  };

  xvfb_run = callPackage ../tools/misc/xvfb-run { inherit (texFunctions) fontsConf; };

  youtubeDL = callPackage ../tools/misc/youtube-dl { };

  zbar = callPackage ../tools/graphics/zbar {
    pygtk = lib.overrideDerivation pygtk (x: {
      gtk = gtk2;
    });
  };

  zfstools = callPackage ../tools/filesystems/zfstools {
    zfs = linuxPackages.zfs;
  };

  zpaqd = callPackage ../tools/archivers/zpaq/zpaqd.nix { };


  ### SHELLS

  bash = lowPrio (callPackage ../shells/bash {
    texinfo = null;
  });

  bashInteractive = appendToName "interactive" (callPackage ../shells/bash {
    interactive = true;
    readline = readline63; # Includes many vi mode fixes
  });

  bashCompletion = callPackage ../shells/bash-completion { };

  fish = callPackage ../shells/fish {
    python = python27Full;
  };


  ### DEVELOPMENT / COMPILERS

  abc =
    abcPatchable [];

  abcPatchable = patches :
    import ../development/compilers/abc/default.nix {
      inherit stdenv fetchurl patches jre apacheAnt;
      javaCup = callPackage ../development/libraries/java/cup { };
    };

  ats2 = callPackage ../development/compilers/ats2 { };

  ccl = builderDefsPackage ../development/compilers/ccl {};

  clang = wrapClang llvmPackages.clang;

  clang_34 = wrapClang llvmPackages_34.clang;
  clang_33 = wrapClang (clangUnwrapped llvm_33 ../development/compilers/llvm/3.3/clang.nix);

  clangAnalyzer = callPackage ../development/tools/analysis/clang-analyzer {
    clang = clang_34;
    llvmPackages = llvmPackages_34;
  };

  clangUnwrapped = llvm: pkg: callPackage pkg {
      stdenv = if stdenv.isDarwin
         then stdenvAdapters.overrideGCC stdenv gccApple
         else stdenv;
      llvm = llvm;
  };

  clangSelf = clangWrapSelf llvmPackagesSelf.clang;

  clangWrapSelf = build: (import ../build-support/clang-wrapper) {
    clang = build;
    stdenv = clangStdenv;
    libc = glibc;
    binutils = binutils;
    shell = bash;
    inherit libcxx coreutils zlib;
    nativeTools = false;
    nativeLibc = false;
  };

  #Use this instead of stdenv to build with clang
  clangStdenv = lowPrio (stdenvAdapters.overrideGCC stdenv clang);
  libcxxStdenv = stdenvAdapters.overrideGCC stdenv (clangWrapSelf llvmPackages.clang);

  closurecompiler = callPackage ../development/compilers/closure { };

  cmucl_binary = callPackage ../development/compilers/cmucl/binary.nix { };

  cryptol1 = lowPrio (callPackage ../development/compilers/cryptol/1.8.x.nix {});
  cryptol2 = haskellPackages_ghc763.cryptol; # doesn't compile with the lastest 7.8.3 release

  cython = pythonPackages.cython;
  cython3 = python3Packages.cython;

  dylan = callPackage ../development/compilers/gwydion-dylan {
    dylan = callPackage ../development/compilers/gwydion-dylan/binary.nix {  };
  };

  adobe_flex_sdk = callPackage ../development/compilers/adobe-flex-sdk { };

  fpc_2_4_0 = callPackage ../development/compilers/fpc/2.4.0.nix { };

  gcc = gcc48;

  gcc33 = wrapGCC (import ../development/compilers/gcc/3.3 {
    inherit fetchurl stdenv noSysDirs;
  });

  gcc34 = wrapGCC (import ../development/compilers/gcc/3.4 {
    inherit fetchurl stdenv noSysDirs;
  });

  gcc48_realCross = lib.addMetaAttrs { hydraPlatforms = []; }
    (callPackage ../development/compilers/gcc/4.8 {
      inherit noSysDirs;
      binutilsCross = binutilsCross;
      libcCross = libcCross;
      profiledCompiler = false;
      enableMultilib = false;
      crossStageStatic = false;
      cross = assert crossSystem != null; crossSystem;
    });

  gcc_realCross = gcc48_realCross;

  gccCrossStageStatic = let
      libcCross1 =
        if stdenv.cross.libc == "msvcrt" then windows.mingw_w64_headers
        else if stdenv.cross.libc == "libSystem" then darwin.xcode
        else null;
    in
      wrapGCCCross {
      gcc = forceNativeDrv (lib.addMetaAttrs { hydraPlatforms = []; } (
        gcc_realCross.override {
          crossStageStatic = true;
          langCC = false;
          libcCross = libcCross1;
          enableShared = false;
        }));
      libc = libcCross1;
      binutils = binutilsCross;
      cross = assert crossSystem != null; crossSystem;
  };

  # Only needed for mingw builds
  gccCrossMingw2 = wrapGCCCross {
    gcc = gccCrossStageStatic.gcc;
    libc = windows.mingw_headers2;
    binutils = binutilsCross;
    cross = assert crossSystem != null; crossSystem;
  };

  gccCrossStageFinal = wrapGCCCross {
    gcc = forceNativeDrv (gcc_realCross.override {
      libpthreadCross =
        # FIXME: Don't explicitly refer to `i586-pc-gnu'.
        if crossSystem != null && crossSystem.config == "i586-pc-gnu"
        then gnu.libpthreadCross
        else null;

      # XXX: We have troubles cross-compiling libstdc++ on MinGW (see
      # <http://hydra.nixos.org/build/4268232>), so don't even try.
      langCC = (crossSystem == null
                || crossSystem.config != "i686-pc-mingw32");
     });
    libc = libcCross;
    binutils = binutilsCross;
    cross = assert crossSystem != null; crossSystem;
  };

  gcc44 = lowPrio (wrapGCC (makeOverridable (import ../development/compilers/gcc/4.4) {
    inherit fetchurl stdenv gmp mpfr /* ppl cloogppl */
      gettext which noSysDirs;
    texinfo = texinfo4;
    profiledCompiler = true;
  }));

  gcc45 = lowPrio (wrapGCC (callPackage ../development/compilers/gcc/4.5 {
    inherit fetchurl stdenv gmp mpfr mpc libelf zlib perl
      gettext which noSysDirs;
    texinfo = texinfo4;

    ppl = null;
    cloogppl = null;

    # bootstrapping a profiled compiler does not work in the sheevaplug:
    # http://gcc.gnu.org/bugzilla/show_bug.cgi?id=43944
    profiledCompiler = !stdenv.isArm;

    # When building `gcc.crossDrv' (a "Canadian cross", with host == target
    # and host != build), `cross' must be null but the cross-libc must still
    # be passed.
    cross = null;
    libcCross = if crossSystem != null then libcCross else null;
    libpthreadCross =
      if crossSystem != null && crossSystem.config == "i586-pc-gnu"
      then gnu.libpthreadCross
      else null;
  }));

  gcc46 = lowPrio (wrapGCC (callPackage ../development/compilers/gcc/4.6 {
    inherit noSysDirs;

    ppl = null;
    cloog = null;

    # bootstrapping a profiled compiler does not work in the sheevaplug:
    # http://gcc.gnu.org/bugzilla/show_bug.cgi?id=43944
    profiledCompiler = false;

    # When building `gcc.crossDrv' (a "Canadian cross", with host == target
    # and host != build), `cross' must be null but the cross-libc must still
    # be passed.
    cross = null;
    libcCross = if crossSystem != null then libcCross else null;
    libpthreadCross =
      if crossSystem != null && crossSystem.config == "i586-pc-gnu"
      then gnu.libpthreadCross
      else null;
    texinfo = texinfo413;
  }));

  gcc48 = lowPrio (wrapGCC (callPackage ../development/compilers/gcc/4.8 {
    inherit noSysDirs;

    # PGO seems to speed up compilation by gcc by ~10%, see #445 discussion
    profiledCompiler = with stdenv; (!isDarwin && (isi686 || isx86_64));

    # When building `gcc.crossDrv' (a "Canadian cross", with host == target
    # and host != build), `cross' must be null but the cross-libc must still
    # be passed.
    cross = null;
    libcCross = if crossSystem != null then libcCross else null;
    libpthreadCross =
      if crossSystem != null && crossSystem.config == "i586-pc-gnu"
      then gnu.libpthreadCross
      else null;
  }));

  gcc48_multi =
    if system == "x86_64-linux" then lowPrio (
      wrapGCCWith (import ../build-support/gcc-wrapper) glibc_multi (gcc48.gcc.override {
        stdenv = overrideGCC stdenv (wrapGCCWith (import ../build-support/gcc-wrapper) glibc_multi gcc.gcc);
        profiledCompiler = false;
        enableMultilib = true;
      }))
    else throw "Multilib gcc not supported on ‘${system}’";

  gcc48_debug = lowPrio (wrapGCC (callPackage ../development/compilers/gcc/4.8 {
    stripped = false;

    inherit noSysDirs;
    cross = null;
    libcCross = null;
    binutilsCross = null;
  }));

  gcc49 = lowPrio (wrapGCC (callPackage ../development/compilers/gcc/4.9 {
    inherit noSysDirs;

    # PGO seems to speed up compilation by gcc by ~10%, see #445 discussion
    profiledCompiler = with stdenv; (!isDarwin && (isi686 || isx86_64));

    # When building `gcc.crossDrv' (a "Canadian cross", with host == target
    # and host != build), `cross' must be null but the cross-libc must still
    # be passed.
    cross = null;
    libcCross = if crossSystem != null then libcCross else null;
    libpthreadCross =
      if crossSystem != null && crossSystem.config == "i586-pc-gnu"
      then gnu.libpthreadCross
      else null;
  }));

  gccApple =
    assert stdenv.isDarwin;
    wrapGCC (makeOverridable (import ../development/compilers/gcc/4.2-apple64) {
      inherit fetchurl noSysDirs;
      profiledCompiler = true;
      # Since it fails to build with GCC 4.6, build it with the "native"
      # Apple-GCC.
      stdenv = allStdenvs.stdenvNative;
    });

  gfortran = gfortran48;

  gfortran48 = wrapGCC (gcc48.gcc.override {
    name = "gfortran";
    langFortran = true;
    langCC = false;
    langC = false;
    profiledCompiler = false;
  });

  gcj = gcj48;

  gcj48 = wrapGCC (gcc48.gcc.override {
    name = "gcj";
    langJava = true;
    langFortran = false;
    langCC = false;
    langC = false;
    profiledCompiler = false;
    inherit zip unzip zlib boehmgc gettext pkgconfig perl;
    inherit gtk;
    inherit (gnome) libart_lgpl;
    inherit (xlibs) libX11 libXt libSM libICE libXtst libXi libXrender
      libXrandr xproto renderproto xextproto inputproto randrproto;
  });

  gnat = gnat45;

  gnat45 = wrapGCC (gcc45.gcc.override {
    name = "gnat";
    langCC = false;
    langC = true;
    langAda = true;
    profiledCompiler = false;
    inherit gnatboot;
    # We can't use the ppl stuff, because we would have
    # libstdc++ problems.
    cloogppl = null;
    ppl = null;
  });

  gnat46 = wrapGCC (gcc46.gcc.override {
    name = "gnat";
    langCC = false;
    langC = true;
    langAda = true;
    profiledCompiler = false;
    gnatboot = gnat45;
    # We can't use the ppl stuff, because we would have
    # libstdc++ problems.
    ppl = null;
    cloog = null;
  });

  gnatboot = wrapGCC (import ../development/compilers/gnatboot {
    inherit fetchurl stdenv;
  });

  gccgo = gccgo48;

  gccgo48 = wrapGCC (gcc48.gcc.override {
    name = "gccgo";
    langCC = true; #required for go.
    langC = true;
    langGo = true;
  });

  ghdl = wrapGCC (import ../development/compilers/gcc/4.3 {
    inherit stdenv fetchurl gmp mpfr noSysDirs gnat;
    texinfo = texinfo4;
    name = "ghdl";
    langVhdl = true;
    langCC = false;
    langC = false;
    profiledCompiler = false;
    enableMultilib = false;
  });

  ghdl_mcode = callPackage ../development/compilers/ghdl { };

  gcl = builderDefsPackage ../development/compilers/gcl {
    inherit mpfr m4 binutils fetchcvs emacs zlib which
      texinfo;
    gmp = gmp4;
    inherit (xlibs) libX11 xproto inputproto libXi
      libXext xextproto libXt libXaw libXmu;
    inherit stdenv;
    texLive = texLiveAggregationFun {
      paths = [
        texLive texLiveExtra
      ];
    };
  };

  jhc = callPackage ../development/compilers/jhc {
    inherit (haskellPackages_ghc763) ghc binary zlib utf8String readline fgl
      regexCompat HsSyck random;
  };

  gcc-arm-embedded-4_7 = callPackage_i686 ../development/compilers/gcc-arm-embedded {
    version = "4.7-2013q3-20130916";
    releaseType = "update";
    sha256 = "1bd9bi9q80xn2rpy0rn1vvj70rh15kb7dmah0qs4q2rv78fqj40d";
  };
  gcc-arm-embedded-4_8 = callPackage_i686 ../development/compilers/gcc-arm-embedded {
    version = "4.8-2014q1-20140314";
    releaseType = "update";
    sha256 = "ce92859550819d4a3d1a6e2672ea64882b30afa2c08cf67fa8e1d93788c2c577";
  };
  gcc-arm-embedded = gcc-arm-embedded-4_8;

  # Haskell and GHC

  # Import Haskell infrastructure.

  haskell = let pkgs_       = pkgs // { gmp = gmp.override { withStatic = true; }; };
                callPackage = newScope pkgs_;
                newScope    = extra: lib.callPackageWith (pkgs_ // pkgs_.xorg // extra);
            in callPackage ./haskell-defaults.nix { pkgs = pkgs_; inherit callPackage newScope; };

  # Available GHC versions.

  # For several compiler versions, we export a large set of Haskell-related
  # packages.

  # NOTE (recurseIntoAttrs): After discussion, we originally decided to
  # enable it for all GHC versions. However, this is getting too much,
  # particularly in connection with Hydra builds for all these packages.
  # So we enable it for selected versions only. We build all ghcs, though

  ghc = recurseIntoAttrs (lib.mapAttrs' (name: value:
    lib.nameValuePair (builtins.substring (builtins.stringLength "packages_") (builtins.stringLength name) name) value.ghc
  ) (lib.filterAttrs (name: value:
    builtins.substring 0 (builtins.stringLength "packages_") name == "packages_"
  ) haskell));

  haskellPackages = haskellPackages_ghc783;
  haskellPlatform = haskellPlatformPackages."2013_2_0_0";

  haskellPackages_ghc6104 = haskell.packages_ghc6104;
  haskellPackages_ghc6123 = haskell.packages_ghc6123;
  haskellPackages_ghc704  = haskell.packages_ghc704;
  haskellPackages_ghc722  = haskell.packages_ghc722;
  haskellPackages_ghc742  = haskell.packages_ghc742;
  haskellPackages_ghc763  = haskell.packages_ghc763;
  haskellPackages_ghc783_no_profiling = recurseIntoAttrs haskell.packages_ghc783.noProfiling;
  haskellPackages_ghc783_profiling    = recurseIntoAttrs haskell.packages_ghc783.profiling;
  haskellPackages_ghc783              = recurseIntoAttrs haskell.packages_ghc783.highPrio;
  haskellPackages_ghcHEAD = haskell.packages_ghcHEAD;

  haskellPlatformPackages = recurseIntoAttrs (import ../development/libraries/haskell/haskell-platform { inherit pkgs; });

  hiphopvm = hhvm; /* Compatibility alias */

  falcon = builderDefsPackage (import ../development/interpreters/falcon) {
    inherit cmake;
  };

  go_1_0 = callPackage ../development/compilers/go { };

  go_1_1 =
    if stdenv.isDarwin then
      callPackage ../development/compilers/go/1.1-darwin.nix { }
    else
      callPackage ../development/compilers/go/1.1.nix { };

  go_1_2 = callPackage ../development/compilers/go/1.2.nix { };

  go_1_3 = callPackage ../development/compilers/go/1.3.nix { };

  go = go_1_3;

  gox = callPackage ../development/compilers/go/gox.nix { };

  gwt240 = callPackage ../development/compilers/gwt/2.4.0.nix { };

  icedtea7_jdk = callPackage ../development/compilers/icedtea rec {
    jdk = openjdk;
    jdkPath = "${openjdk}/lib/openjdk";
  } // { outputs = [ "out" ]; };

  icedtea7_jre = (lib.setName "icedtea7-${lib.getVersion pkgs.icedtea7_jdk.jre}" (lib.addMetaAttrs
    { description = "Free Java runtime environment based on OpenJDK 7.0 and the IcedTea project"; }
    pkgs.icedtea7_jdk.jre)) // { outputs = [ "jre" ]; };

  icedtea7_web = callPackage ../development/compilers/icedtea-web {
    jdk = "${icedtea7_jdk}/lib/icedtea";
  };

  openjdk =
    if stdenv.isDarwin then
      callPackage ../development/compilers/openjdk-darwin { }
    else
      let
        openjdkBootstrap = callPackage ../development/compilers/openjdk/bootstrap.nix { };
      in (callPackage ../development/compilers/openjdk {
        jdk = openjdkBootstrap;
      }) // { outputs = [ "out" ]; };

  # FIXME: Need a way to set per-output meta attributes.
  openjre = (lib.setName "openjre-${lib.getVersion pkgs.openjdk.jre}" (lib.addMetaAttrs
    { description = "The open-source Java Runtime Environment"; }
    pkgs.openjdk.jre)) // { outputs = [ "jre" ]; };

  jdk = if stdenv.isDarwin || stdenv.system == "i686-linux" || stdenv.system == "x86_64-linux"
    then pkgs.openjdk
    else pkgs.oraclejdk;
  jre = if stdenv.isDarwin || stdenv.system == "i686-linux" || stdenv.system == "x86_64-linux"
    then pkgs.openjre
    else pkgs.oraclejre;

  oraclejdk = pkgs.jdkdistro true false;

  oraclejdk7 = pkgs.oraclejdk7distro true false;

  oraclejdk8 = pkgs.oraclejdk8distro true false;

  oraclejre = lowPrio (pkgs.jdkdistro false false);

  oraclejre7 = lowPrio (pkgs.oraclejdk7distro false false);

  oraclejre8 = lowPrio (pkgs.oraclejdk8distro false false);

  jrePlugin = lowPrio (pkgs.jdkdistro false true);

  supportsJDK =
    system == "i686-linux" ||
    system == "x86_64-linux";

  jdkdistro = installjdk: pluginSupport:
    assert supportsJDK;
    (if pluginSupport then appendToName "with-plugin" else x: x)
      (callPackage ../development/compilers/oraclejdk/jdk6-linux.nix { });

  oraclejdk7distro = installjdk: pluginSupport:
    assert supportsJDK;
    (if pluginSupport then appendToName "with-plugin" else x: x)
      (callPackage ../development/compilers/oraclejdk/jdk7-linux.nix { inherit installjdk; });

  oraclejdk8distro = installjdk: pluginSupport:
    assert supportsJDK;
    (if pluginSupport then appendToName "with-plugin" else x: x)
      (callPackage ../development/compilers/oraclejdk/jdk8-linux.nix { inherit installjdk; });

  juliaGit = callPackage ../development/compilers/julia/git-20131013.nix {
    liblapack = liblapack.override {shared = true;};
    llvm = llvm_33;
  };
  julia021 = callPackage ../development/compilers/julia/0.2.1.nix {
    liblapack = liblapack.override {shared = true;};
    llvm = llvm_33;
  };
  julia = julia021;

  lazarus = builderDefsPackage (import ../development/compilers/fpc/lazarus.nix) {
    inherit makeWrapper gtk glib pango atk gdk_pixbuf;
    inherit (xlibs) libXi inputproto libX11 xproto libXext xextproto;
    fpc = fpc;
  };

  llvm = llvmPackages.llvm;

  llvm_34 = llvmPackages_34.llvm;
  llvm_33 = llvm_v ../development/compilers/llvm/3.3/llvm.nix;

  llvm_v = path: callPackage path {
    stdenv = if stdenv.isDarwin
      then stdenvAdapters.overrideGCC stdenv gccApple
      else stdenv;
  };

  llvmPackages = if !stdenv.isDarwin then llvmPackages_34 else llvmPackages_34 // {
    # until someone solves build problems with _34
    llvm = llvm_33;
    clang = clang_33;
  };

  llvmPackages_34 = recurseIntoAttrs (import ../development/compilers/llvm/3.4 {
    inherit stdenv newScope fetchurl;
    isl = isl_0_12;
  });
  llvmPackagesSelf = import ../development/compilers/llvm/3.4 { inherit newScope fetchurl; isl = isl_0_12; stdenv = libcxxStdenv; };

  mentorToolchains = recurseIntoAttrs (
    callPackage_i686 ../development/compilers/mentor {}
  );

  mitscheme = callPackage ../development/compilers/mit-scheme { };

  mono = callPackage ../development/compilers/mono {
    inherit (xlibs) libX11;
  };

  monoDLLFixer = callPackage ../build-support/mono-dll-fixer { };

  nvidia_cg_toolkit = callPackage ../development/compilers/nvidia-cg-toolkit { };

  ocaml = ocamlPackages.ocaml;

  ocaml_3_08_0 = callPackage ../development/compilers/ocaml/3.08.0.nix { };

  ocaml_3_10_0 = callPackage ../development/compilers/ocaml/3.10.0.nix { };

  ocaml_3_11_2 = callPackage ../development/compilers/ocaml/3.11.2.nix { };

  ocaml_3_12_1 = callPackage ../development/compilers/ocaml/3.12.1.nix { };

  ocaml_4_00_1 = callPackage ../development/compilers/ocaml/4.00.1.nix { };

  ocaml_4_01_0 = callPackage ../development/compilers/ocaml/4.01.0.nix { };

  metaocaml_3_09 = callPackage ../development/compilers/ocaml/metaocaml-3.09.nix { };

  ber_metaocaml_003 = callPackage ../development/compilers/ocaml/ber-metaocaml-003.nix { };

  mkOcamlPackages = ocaml: self: let callPackage = newScope self; in rec {
    inherit ocaml;

    camlidl = callPackage ../development/tools/ocaml/camlidl { };

    camlp5_5_strict = callPackage ../development/tools/ocaml/camlp5/5.15.nix { };

    camlp5_5_transitional = callPackage ../development/tools/ocaml/camlp5/5.15.nix {
      transitional = true;
    };

    camlp5_6_strict = callPackage ../development/tools/ocaml/camlp5 { };

    camlp5_6_transitional = callPackage ../development/tools/ocaml/camlp5 {
      transitional = true;
    };

    camlp5_strict = camlp5_6_strict;

    camlp5_transitional = camlp5_6_transitional;

    camlzip = callPackage ../development/ocaml-modules/camlzip { };

    camomile_0_8_2 = callPackage ../development/ocaml-modules/camomile/0.8.2.nix { };
    camomile = callPackage ../development/ocaml-modules/camomile { };

    camlimages = callPackage ../development/ocaml-modules/camlimages {
      libpng = libpng12;
      giflib = giflib_4_1;
    };

    biniou = callPackage ../development/ocaml-modules/biniou { };

    ocaml_cairo = callPackage ../development/ocaml-modules/ocaml-cairo { };

    cppo = callPackage ../development/tools/ocaml/cppo { };

    cryptokit = callPackage ../development/ocaml-modules/cryptokit { };

    deriving = callPackage ../development/tools/ocaml/deriving { };

    easy-format = callPackage ../development/ocaml-modules/easy-format { };

    findlib = callPackage ../development/tools/ocaml/findlib { };

    dypgen = callPackage ../development/ocaml-modules/dypgen { };

    patoline = callPackage ../tools/typesetting/patoline { };

    gmetadom = callPackage ../development/ocaml-modules/gmetadom { };

    lablgl = callPackage ../development/ocaml-modules/lablgl { };

    lablgtk = callPackage ../development/ocaml-modules/lablgtk {
      inherit (gnome) libgnomecanvas libglade gtksourceview;
    };

    lablgtkmathview = callPackage ../development/ocaml-modules/lablgtkmathview {
      gtkmathview = callPackage ../development/libraries/gtkmathview { };
    };

    menhir = callPackage ../development/ocaml-modules/menhir { };

    mldonkey = callPackage ../applications/networking/p2p/mldonkey { };

    mlgmp =  callPackage ../development/ocaml-modules/mlgmp { };

    ocaml_batteries = callPackage ../development/ocaml-modules/batteries { };

    ocaml_cryptgps = callPackage ../development/ocaml-modules/cryptgps { };

    ocaml_data_notation = callPackage ../development/ocaml-modules/odn { };

    ocaml_expat = callPackage ../development/ocaml-modules/expat { };

    ocamlgraph = callPackage ../development/ocaml-modules/ocamlgraph { };

    ocaml_http = callPackage ../development/ocaml-modules/http { };

    ocamlify = callPackage ../development/tools/ocaml/ocamlify { };

    ocaml_lwt = callPackage ../development/ocaml-modules/lwt { };

    ocamlmod = callPackage ../development/tools/ocaml/ocamlmod { };

    ocaml_mysql = callPackage ../development/ocaml-modules/mysql { };

    ocamlnet = callPackage ../development/ocaml-modules/ocamlnet { };

    ocaml_oasis = callPackage ../development/tools/ocaml/oasis { };

    ocaml_pcre = callPackage ../development/ocaml-modules/pcre {
      inherit pcre;
    };

    ocaml_react = callPackage ../development/ocaml-modules/react { };

    ocamlsdl= callPackage ../development/ocaml-modules/ocamlsdl { };

    ocaml_sqlite3 = callPackage ../development/ocaml-modules/sqlite3 { };

    ocaml_ssl = callPackage ../development/ocaml-modules/ssl { };

    ounit = callPackage ../development/ocaml-modules/ounit { };

    ulex = callPackage ../development/ocaml-modules/ulex { };

    ulex08 = callPackage ../development/ocaml-modules/ulex/0.8 {
      camlp5 = camlp5_transitional;
    };

    ocaml_typeconv = callPackage ../development/ocaml-modules/typeconv { };

    ocaml_typeconv_3_0_5 = callPackage ../development/ocaml-modules/typeconv/3.0.5.nix { };

    ocaml_sexplib = callPackage ../development/ocaml-modules/sexplib { };

    ocaml_extlib = callPackage ../development/ocaml-modules/extlib { };

    pycaml = callPackage ../development/ocaml-modules/pycaml { };

    opam_1_0_0 = callPackage ../development/tools/ocaml/opam/1.0.0.nix { };
    opam_1_1 = callPackage ../development/tools/ocaml/opam/1.1.nix { };
    opam = opam_1_1;

    yojson = callPackage ../development/ocaml-modules/yojson { };

    zarith = callPackage ../development/ocaml-modules/zarith { };
  };

  ocamlPackages = recurseIntoAttrs ocamlPackages_4_01_0;
  ocamlPackages_3_10_0 = mkOcamlPackages ocaml_3_10_0 pkgs.ocamlPackages_3_10_0;
  ocamlPackages_3_11_2 = mkOcamlPackages ocaml_3_11_2 pkgs.ocamlPackages_3_11_2;
  ocamlPackages_3_12_1 = mkOcamlPackages ocaml_3_12_1 pkgs.ocamlPackages_3_12_1;
  ocamlPackages_4_00_1 = mkOcamlPackages ocaml_4_00_1 pkgs.ocamlPackages_4_00_1;
  ocamlPackages_4_01_0 = mkOcamlPackages ocaml_4_01_0 pkgs.ocamlPackages_4_01_0;
  ocamlPackages_latest = ocamlPackages_4_01_0;

  ocaml_make = callPackage ../development/ocaml-modules/ocamlmake { };

  opa = let callPackage = newScope pkgs.ocamlPackages_3_12_1; in callPackage ../development/compilers/opa { };

  ocamlnat = let callPackage = newScope pkgs.ocamlPackages_3_12_1; in callPackage ../development/ocaml-modules/ocamlnat { };

  qcmm = callPackage ../development/compilers/qcmm {
    lua   = lua4;
    ocaml = ocaml_3_08_0;
  };

  sbclBootstrap = callPackage ../development/compilers/sbcl/bootstrap.nix {};
  sbcl = callPackage ../development/compilers/sbcl {
    clisp = clisp_2_44_1;
  };

  scala_2_9 = callPackage ../development/compilers/scala/2.9.nix { };
  scala_2_10 = callPackage ../development/compilers/scala/2.10.nix { };
  scala_2_11 = callPackage ../development/compilers/scala { };
  scala = scala_2_11;

  smlnjBootstrap = callPackage ../development/compilers/smlnj/bootstrap.nix { };
  smlnj = callPackage_i686 ../development/compilers/smlnj { };

  strategoPackages = recurseIntoAttrs strategoPackages018;

  strategoPackages016 = callPackage ../development/compilers/strategoxt/0.16.nix {
    stdenv = overrideInStdenv stdenv [gnumake380];
  };

  strategoPackages017 = callPackage ../development/compilers/strategoxt/0.17.nix {
    readline = readline5;
  };

  strategoPackages018 = callPackage ../development/compilers/strategoxt/0.18.nix {
    readline = readline5;
  };

  metaBuildEnv = callPackage ../development/compilers/meta-environment/meta-build-env { };

  swiProlog = callPackage ../development/compilers/swi-prolog { };

  vala = callPackage ../development/compilers/vala/default.nix { };

  visualcpp = callPackage ../development/compilers/visual-c++ { };

  win32hello = callPackage ../development/compilers/visual-c++/test { };

  wrapGCCWith = gccWrapper: glibc: baseGCC: gccWrapper {
    nativeTools = stdenv ? gcc && stdenv.gcc.nativeTools;
    nativeLibc = stdenv ? gcc && stdenv.gcc.nativeLibc;
    nativePrefix = if stdenv ? gcc then stdenv.gcc.nativePrefix else "";
    gcc = baseGCC;
    libc = glibc;
    shell = bash;
    inherit stdenv binutils coreutils zlib;
  };

  wrapClangWith = clangWrapper: glibc: baseClang: clangWrapper {
    nativeTools = stdenv.gcc.nativeTools or false;
    nativeLibc = stdenv.gcc.nativeLibc or false;
    nativePrefix = stdenv.gcc.nativePrefix or "";
    clang = baseClang;
    libc = glibc;
    shell = bash;
    binutils = stdenv.gcc.binutils;
    inherit stdenv coreutils zlib;
  };

  wrapClang = wrapClangWith (makeOverridable (import ../build-support/clang-wrapper)) glibc;

  wrapGCC = wrapGCCWith (makeOverridable (import ../build-support/gcc-wrapper)) glibc;

  wrapGCCCross =
    {gcc, libc, binutils, cross, shell ? "", name ? "gcc-cross-wrapper"}:

    forceNativeDrv (import ../build-support/gcc-cross-wrapper {
      nativeTools = false;
      nativeLibc = false;
      noLibc = (libc == null);
      inherit stdenv gcc binutils libc shell name cross;
    });

  # prolog

  ### DEVELOPMENT / INTERPRETERS

  acl2 = builderDefsPackage ../development/interpreters/acl2 {
    inherit sbcl;
  };

  # compatibility issues in 2.47 - at list 2.44.1 is known good
  # for sbcl bootstrap
  clisp_2_44_1 = callPackage ../development/interpreters/clisp/2.44.1.nix {
    libsigsegv = libsigsegv_25;
  };

  clooj = callPackage ../development/interpreters/clojure/clooj.nix { };

  erlangR14 = callPackage ../development/interpreters/erlang/R14.nix { };
  erlangR15 = callPackage ../development/interpreters/erlang/R15.nix { };
  erlangR16 = callPackage ../development/interpreters/erlang/R16.nix { };
  erlangR17 = callPackage ../development/interpreters/erlang/R17.nix { };
  erlang = erlangR17;

  guile_1_8 = callPackage ../development/interpreters/guile/1.8.nix { };

  guile_2_0 = callPackage ../development/interpreters/guile { };

  guile = guile_2_0;

  love = callPackage ../development/interpreters/love {lua=lua5;};
  love_luajit = callPackage ../development/interpreters/love {lua=luajit;};
  love_0_9 = callPackage ../development/interpreters/love/0.9.nix { };

  lua4 = callPackage ../development/interpreters/lua-4 { };
  lua5_0 = callPackage ../development/interpreters/lua-5/5.0.3.nix { };
  lua5_1 = callPackage ../development/interpreters/lua-5/5.1.nix { };
  lua5_2 = callPackage ../development/interpreters/lua-5/5.2.nix { };
  lua5_2_compat = callPackage ../development/interpreters/lua-5/5.2.nix {
    compat = true;
  };
  lua5 = lua5_1;
  lua = lua5;

  lua5_sockets = callPackage ../development/interpreters/lua-5/sockets.nix {};
  lua5_expat = callPackage ../development/interpreters/lua-5/expat.nix {};
  lua5_filesystem = callPackage ../development/interpreters/lua-5/filesystem.nix {};
  lua5_sec = callPackage ../development/interpreters/lua-5/sec.nix {};

  luarocks = callPackage ../development/tools/misc/luarocks {
     lua = lua5;
  };

  lush2 = callPackage ../development/interpreters/lush {};

  maude = callPackage ../development/interpreters/maude {
    bison = bison2;
    flex = flex_2_5_35;
  };

  octave = callPackage ../development/interpreters/octave {
    fltk = fltk13;
    qt = null;
    ghostscript = null;
    llvm = null;
    hdf5 = null;
    glpk = null;
    suitesparse = null;
    openjdk = null;
    gnuplot = null;
    readline = readline63;
  };
  octaveFull = (lowPrio (callPackage ../development/interpreters/octave {
    fltk = fltk13;
    qt = qt4;
  }));

  # mercurial (hg) bleeding edge version
  octaveHG = callPackage ../development/interpreters/octave/hg.nix { };

  perl58 = callPackage ../development/interpreters/perl/5.8 {
    impureLibcPath = if stdenv.isLinux then null else "/usr";
  };

  perl510 = callPackage ../development/interpreters/perl/5.10 { };

  perl514 = callPackage ../development/interpreters/perl/5.14 { };

  perl516 = callPackage ../development/interpreters/perl/5.16 {
    fetchurl = fetchurlBoot;
  };

  perl520 = callPackage ../development/interpreters/perl/5.20 { };

  perl = if system != "i686-cygwin" then perl516 else sysPerl;

  php = php54;

  phpPackages = recurseIntoAttrs (import ./php-packages.nix {
    inherit php pkgs;
  });

  php53 = callPackage ../development/interpreters/php/5.3.nix { };

  php_fpm53 = callPackage ../development/interpreters/php/5.3.nix {
    config = config // {
      php = (config.php or {}) // {
        fpm = true;
        apxs2 = false;
      };
    };
  };

  php54 = callPackage ../development/interpreters/php/5.4.nix { };

  pltScheme = racket; # just to be sure

  pure = callPackage ../development/interpreters/pure {
    llvm = llvm_33 ;
  };

  python = python2;
  python2 = python27;
  python3 = python34;

  # pythonPackages further below, but assigned here because they need to be in sync
  pythonPackages = python2Packages;
  python2Packages = python27Packages;
  python3Packages = python34Packages;

  pythonFull = python2Full;
  python2Full = python27Full;

  python26 = callPackage ../development/interpreters/python/2.6 { db = db47; };
  python27 = callPackage ../development/interpreters/python/2.7 { };
  python32 = callPackage ../development/interpreters/python/3.2 { };
  python33 = callPackage ../development/interpreters/python/3.3 { };
  python34 = hiPrio (callPackage ../development/interpreters/python/3.4 { });

  pypy = callPackage ../development/interpreters/pypy/2.3 { };

  python26Full = callPackage ../development/interpreters/python/wrapper.nix {
    extraLibs = [];
    postBuild = "";
    python = python26;
    inherit (python26Packages) recursivePthLoader;
  };
  python27Full = callPackage ../development/interpreters/python/wrapper.nix {
    extraLibs = [];
    postBuild = "";
    python = python27;
    inherit (python27Packages) recursivePthLoader;
  };

  pythonDocs = recurseIntoAttrs (import ../development/interpreters/python/docs {
    inherit stdenv fetchurl lib;
  });

  pythonLinkmeWrapper = callPackage ../development/interpreters/python/python-linkme-wrapper.nix { };

  pypi2nix = python27Packages.pypi2nix;

  pyrex = pyrex095;

  pyrex095 = callPackage ../development/interpreters/pyrex/0.9.5.nix { };

  pyrex096 = callPackage ../development/interpreters/pyrex/0.9.6.nix { };

  renpy = callPackage ../development/interpreters/renpy {
    wrapPython = pythonPackages.wrapPython;
  };

  ruby18 = callPackage ../development/interpreters/ruby/ruby-18.nix { };
  ruby19 = callPackage ../development/interpreters/ruby/ruby-19.nix { };
  ruby2 = lowPrio (callPackage ../development/interpreters/ruby/ruby-2.0.nix { });

  ruby = ruby19;

  rubyLibs = recurseIntoAttrs (callPackage ../development/interpreters/ruby/libs.nix { });

  rake = rubyLibs.rake;

  rubySqlite3 = callPackage ../development/ruby-modules/sqlite3 { };

  rubygemsFun = ruby: builderDefsPackage (import ../development/interpreters/ruby/rubygems.nix) {
    inherit ruby makeWrapper;
  };
  rubygems = hiPrio (rubygemsFun ruby);

  spidermonkey_1_8_0rc1 = callPackage ../development/interpreters/spidermonkey/1.8.0-rc1.nix { };
  spidermonkey_185 = callPackage ../development/interpreters/spidermonkey/185-1.0.0.nix { };
  spidermonkey_17 = callPackage ../development/interpreters/spidermonkey/17.0.nix { };
  spidermonkey_24 = callPackage ../development/interpreters/spidermonkey/24.2.nix { };

  supercollider = callPackage ../development/interpreters/supercollider {
    qt = qt4;
    fftw = fftwSinglePrec;
  };

  supercollider_scel = supercollider.override { useSCEL = true; };

  sysPerl = callPackage ../development/interpreters/perl/sys-perl { };

  xulrunnerWrapper = {application, launcher}:
    import ../development/interpreters/xulrunner/wrapper {
      inherit stdenv application launcher xulrunner;
    };

  xulrunner = pkgs.firefoxPkgs.xulrunner;


  ### DEVELOPMENT / MISC

  amdadlsdk = callPackage ../development/misc/amdadl-sdk { };

  amdappsdk26 = callPackage ../development/misc/amdapp-sdk {
    version = "2.6";
  };

  amdappsdk27 = callPackage ../development/misc/amdapp-sdk {
    version = "2.7";
  };

  amdappsdk28 = callPackage ../development/misc/amdapp-sdk {
    version = "2.8";
  };

  amdappsdk = amdappsdk28;

  amdappsdkFull = callPackage ../development/misc/amdapp-sdk {
    version = "2.8";
    samples = true;
  };

  avrgcclibc = callPackage ../development/misc/avr-gcc-with-avr-libc {
    gcc = gcc46;
    stdenv = overrideGCC stdenv gcc46;
  };

  avr8burnomat = callPackage ../development/misc/avr8-burn-omat { };

  sourceFromHead = import ../build-support/source-from-head-fun.nix {
    inherit config;
  };

  jdtsdk = callPackage ../development/eclipse/jdt-sdk { };

  jruby165 = callPackage ../development/interpreters/jruby { };

  guileCairo = callPackage ../development/guile-modules/guile-cairo { };

  guileGnome = callPackage ../development/guile-modules/guile-gnome {
    gconf = gnome.GConf;
    inherit (gnome) gnome_vfs libglade libgnome libgnomecanvas libgnomeui;
  };

  guile_lib = callPackage ../development/guile-modules/guile-lib { };

  guile_ncurses = callPackage ../development/guile-modules/guile-ncurses { };

  windowssdk = (
    import ../development/misc/windows-sdk {
      inherit fetchurl stdenv cabextract;
    });


  ### DEVELOPMENT / TOOLS

  antlr = callPackage ../development/tools/parsing/antlr/2.7.7.nix { };

  antlr3 = callPackage ../development/tools/parsing/antlr { };

  ant = apacheAnt;

  apacheAnt = callPackage ../development/tools/build-managers/apache-ant { };

  autoconf213 = callPackage ../development/tools/misc/autoconf/2.13.nix { };

  autocutsel = callPackage ../tools/X11/autocutsel{ };

  automake = automake112x;

  automake111x = callPackage ../development/tools/misc/automake/automake-1.11.x.nix { };

  automake112x = callPackage ../development/tools/misc/automake/automake-1.12.x.nix { };

  automake113x = callPackage ../development/tools/misc/automake/automake-1.13.x.nix { };

  automake114x = callPackage ../development/tools/misc/automake/automake-1.14.x.nix { };

  binutils = callPackage ../development/tools/misc/binutils {
    inherit noSysDirs;
  };

  binutils_nogold = lowPrio (callPackage ../development/tools/misc/binutils {
    inherit noSysDirs;
    gold = false;
  });

  binutilsCross =
    if crossSystem != null && crossSystem.libc == "libSystem" then darwin.cctools
    else lowPrio (forceNativeDrv (import ../development/tools/misc/binutils {
      inherit stdenv fetchurl zlib bison;
      noSysDirs = true;
      cross = assert crossSystem != null; crossSystem;
    }));

  bison2 = callPackage ../development/tools/parsing/bison/2.x.nix { };
  bison3 = callPackage ../development/tools/parsing/bison/3.x.nix { };
  bison = bison3;

  buildbot = callPackage ../development/tools/build-managers/buildbot {
    inherit (pythonPackages) twisted jinja2 sqlalchemy sqlalchemy_migrate;
    dateutil = pythonPackages.dateutil_1_5;
  };

  buildbotSlave = callPackage ../development/tools/build-managers/buildbot-slave {
    inherit (pythonPackages) twisted;
  };

  # Wrapper that works as gcc or g++
  # It can be used by setting in nixpkgs config like this, for example:
  #    replaceStdenv = { pkgs }: pkgs.ccacheStdenv;
  # But if you build in chroot, you should have that path in chroot
  # If instantiated directly, it will use the HOME/.ccache as cache directory.
  # You can use an override in packageOverrides to set extraConfig:
  #    packageOverrides = pkgs: {
  #     ccacheWrapper = pkgs.ccacheWrapper.override {
  #       extraConfig = ''
  #         CCACHE_COMPRESS=1
  #         CCACHE_DIR=/bin/.ccache
  #       '';
  #     };
  #
  ccacheWrapper = makeOverridable ({ extraConfig ? "" }:
     wrapGCC (ccache.links extraConfig)) {};
  ccacheStdenv = lowPrio (overrideGCC stdenv ccacheWrapper);

  chromedriver = callPackage ../development/tools/selenium/chromedriver { gconf = gnome.GConf; };

  "cl-launch" = callPackage ../development/tools/misc/cl-launch {};

  ctagsWrapped = import ../development/tools/misc/ctags/wrapped.nix {
    inherit pkgs ctags writeScriptBin;
  };

  cmake264 = callPackage ../development/tools/build-managers/cmake/264.nix { };

  cmakeCurses = cmake.override { useNcurses = true; };

  cmakeWithGui = cmakeCurses.override { useQt4 = true; };

  framac = callPackage ../development/tools/analysis/frama-c { };

  libcxx = callPackage ../development/libraries/libc++ { stdenv = pkgs.clangStdenv; };
  libcxxabi = callPackage ../development/libraries/libc++abi { stdenv = pkgs.clangStdenv; };

  dfeet = callPackage ../development/tools/misc/d-feet {
    inherit (pythonPackages) pep8;
  };

  # distccWrapper: wrapper that works as gcc or g++
  # It can be used by setting in nixpkgs config like this, for example:
  #    replaceStdenv = { pkgs }: pkgs.distccStdenv;
  # But if you build in chroot, a default 'nix' will create
  # a new net namespace, and won't have network access.
  # You can use an override in packageOverrides to set extraConfig:
  #    packageOverrides = pkgs: {
  #     distccWrapper = pkgs.distccWrapper.override {
  #       extraConfig = ''
  #         DISTCC_HOSTS="myhost1 myhost2"
  #       '';
  #     };
  #
  distccWrapper = makeOverridable ({ extraConfig ? "" }:
     wrapGCC (distcc.links extraConfig)) {};
  distccStdenv = lowPrio (overrideGCC stdenv distccWrapper);

  distccMasquerade = callPackage ../development/tools/misc/distcc/masq.nix {
    gccRaw = gcc.gcc;
    binutils = binutils;
  };

  docutils = builderDefsPackage (import ../development/tools/documentation/docutils) {
    inherit python pil makeWrapper;
  };

  doxygen = callPackage ../development/tools/documentation/doxygen {
    qt4 = null;
  };

  doxygen_gui = lowPrio (doxygen.override { inherit qt4; });

  flex_2_5_35 = callPackage ../development/tools/parsing/flex/2.5.35.nix { };
  flex_2_5_39 = callPackage ../development/tools/parsing/flex/2.5.39.nix { };
  flex = flex_2_5_39;

  m4 = gnum4;

  gnome_doc_utils = callPackage ../development/tools/documentation/gnome-doc-utils {};

  gnumake380 = callPackage ../development/tools/build-managers/gnumake/3.80 { };
  gnumake381 = callPackage ../development/tools/build-managers/gnumake/3.81 { };
  gnumake382 = callPackage ../development/tools/build-managers/gnumake/3.82 { };
  gnumake40  = callPackage ../development/tools/build-managers/gnumake/4.0  { };
  gnumake = gnumake382;

  gtk_doc = callPackage ../development/tools/documentation/gtk-doc { };

  guileLint = callPackage ../development/tools/guile/guile-lint { };

  gwrap = callPackage ../development/tools/guile/g-wrap { };

  help2man = callPackage ../development/tools/misc/help2man {
    inherit (perlPackages) LocaleGettext;
  };

  iconnamingutils = callPackage ../development/tools/misc/icon-naming-utils {
    inherit (perlPackages) XMLSimple;
  };

  inotifyTools = callPackage ../development/tools/misc/inotify-tools { };

  ired = callPackage ../development/tools/analysis/radare/ired.nix { };

  libtool = libtool_2;

  libtool_1_5 = callPackage ../development/tools/misc/libtool { };

  libtool_2 = callPackage ../development/tools/misc/libtool/libtool2.nix { };

  lttngTools = callPackage ../development/tools/misc/lttng-tools { };

  lttngUst = callPackage ../development/tools/misc/lttng-ust { };

  neoload = callPackage ../development/tools/neoload {
    licenseAccepted = (config.neoload.accept_license or false);
  };

  node_webkit = callPackage ../development/tools/node-webkit {
    gconf = pkgs.gnome.GConf;
  };

  omake_rc1 = callPackage ../development/tools/ocaml/omake/0.9.8.6-rc1.nix { };

  phantomjs = callPackage ../development/tools/phantomjs {
    stdenv = if stdenv.isDarwin
      then overrideGCC stdenv gccApple
      else stdenv;
  };

  /* Make pkgconfig always return a nativeDrv, never a proper crossDrv,
     because most usage of pkgconfig as buildInput (inheritance of
     pre-cross nixpkgs) means using it using as nativeBuildInput
     cross_renaming: we should make all programs use pkgconfig as
     nativeBuildInput after the renaming.
     */
  pkgconfig = forceNativeDrv (callPackage ../development/tools/misc/pkgconfig { });
  pkgconfigUpstream = lowPrio (pkgconfig.override { vanilla = true; });

  premake3 = callPackage ../development/tools/misc/premake/3.nix { };

  premake4 = callPackage ../development/tools/misc/premake { };

  premake = premake4;

  pstack = callPackage ../development/tools/misc/gdb/pstack.nix { };

  radare = callPackage ../development/tools/analysis/radare {
    inherit (gnome) vte;
    lua = lua5;
    useX11 = config.radare.useX11 or false;
    pythonBindings = config.radare.pythonBindings or false;
    rubyBindings = config.radare.rubyBindings or false;
    luaBindings = config.radare.luaBindings or false;
  };

  # couldn't find the source yet
  seleniumRCBin = callPackage ../development/tools/selenium/remote-control {
    jre = jdk;
  };

  selenium-server-standalone = callPackage ../development/tools/selenium/server { };

  simpleBuildTool = callPackage ../development/tools/build-managers/simple-build-tool { };

  smatch = callPackage ../development/tools/analysis/smatch {
    buildllvmsparse = false;
    buildc2xml = false;
  };

  speedtest_cli = callPackage ../tools/networking/speedtest-cli { };

  swig2 = callPackage ../development/tools/misc/swig/2.x.nix { };

  swig3 = callPackage ../development/tools/misc/swig/3.x.nix { };

  swigWithJava = swig;

  teensy-loader = callPackage ../development/tools/misc/teensy { };

  texinfo413 = callPackage ../development/tools/misc/texinfo/4.13a.nix { };
  texinfo5 = callPackage ../development/tools/misc/texinfo/5.2.nix { };
  texinfo4 = texinfo413;
  texinfo = texinfo5;
  texinfoInteractive = appendToName "interactive" (
    texinfo.override { interactive = true; }
  );

  vagrant = callPackage ../development/tools/vagrant {
    ruby = ruby2;
  };

  gdb = callPackage ../development/tools/misc/gdb {
    hurd = gnu.hurdCross;
    readline = readline63;
    inherit (gnu) mig;
  };

  gdbCross = lowPrio (callPackage ../development/tools/misc/gdb {
    target = crossSystem;
  });

  valgrind = callPackage ../development/tools/analysis/valgrind {
    stdenv =
      # On Darwin, Valgrind 3.7.0 expects Apple's GCC (for
      # `__private_extern'.)
      if stdenv.isDarwin
      then overrideGCC stdenv gccApple
      else stdenv;
  };

  xxdiff = callPackage ../development/tools/misc/xxdiff {
    bison = bison2;
  };

  yacc = bison;


  ### DEVELOPMENT / LIBRARIES

  activemq = callPackage ../development/libraries/apache-activemq { };

  allegro5 = callPackage ../development/libraries/allegro/5.nix {};
  allegro5unstable = callPackage
    ../development/libraries/allegro/5-unstable.nix {};

  aprutil = callPackage ../development/libraries/apr-util {
    bdbSupport = true;
  };

  aspellDicts = recurseIntoAttrs (import ../development/libraries/aspell/dictionaries.nix {
    inherit fetchurl stdenv aspell which;
  });

  aterm = aterm25;

  aterm25 = callPackage ../development/libraries/aterm/2.5.nix { };

  aterm28 = lowPrio (callPackage ../development/libraries/aterm/2.8.nix { });

  audiofile = callPackage ../development/libraries/audiofile {
    stdenv = if stdenv.isDarwin
      then overrideGCC stdenv gccApple
      else stdenv;
  };

  babl_0_0_22 = callPackage ../development/libraries/babl/0_0_22.nix { };

  boehmgc = callPackage ../development/libraries/boehm-gc { };

  boost144 = callPackage ../development/libraries/boost/1.44.nix { };
  boost149 = callPackage ../development/libraries/boost/1.49.nix { };
  boost155 = callPackage ../development/libraries/boost/1.55.nix { };
  boost = boost155;

  boostHeaders = callPackage ../development/libraries/boost/header-only-wrapper.nix { };

  botanUnstable = callPackage ../development/libraries/botan/unstable.nix { };

  box2d_2_0_1 = callPackage ../development/libraries/box2d/2.0.1.nix { };

  c-ares = callPackage ../development/libraries/c-ares {
    fetchurl = fetchurlBoot;
  };

  ccrtp_1_8 = callPackage ../development/libraries/ccrtp/1.8.nix { };

  celt_0_7 = callPackage ../development/libraries/celt/0.7.nix {};
  celt_0_5_1 = callPackage ../development/libraries/celt/0.5.1.nix {};

  cgal = callPackage ../development/libraries/CGAL {};

  chipmunk = builderDefsPackage (import ../development/libraries/chipmunk) {
    inherit cmake freeglut mesa;
    inherit (xlibs) libX11 xproto inputproto libXi libXmu;
  };

  cilaterm = callPackage ../development/libraries/cil-aterm {
    stdenv = overrideInStdenv stdenv [gnumake380];
  };

  classpath = callPackage ../development/libraries/java/classpath {
    javac = gcj;
    jvm = gcj;
    gconf = gnome.GConf;
  };

  clppcre = builderDefsPackage (import ../development/libraries/cl-ppcre) { };

  clucene_core_2 = callPackage ../development/libraries/clucene-core/2.x.nix { };

  clucene_core_1 = callPackage ../development/libraries/clucene-core { };

  clucene_core = clucene_core_1;

  clutter_1_18 = callPackage ../development/libraries/clutter/1.18.nix {
    cogl = cogl_1_18;
  };

  clutter_gtk = callPackage ../development/libraries/clutter-gtk { };
  clutter_gtk_0_10 = callPackage ../development/libraries/clutter-gtk/0.10.8.nix { };

  cogl_1_18 = callPackage ../development/libraries/cogl/1.18.nix { };

  cppnetlib = callPackage ../development/libraries/cppnetlib {
    boost = boostHeaders;
  };

  cryptopp = callPackage ../development/libraries/crypto++ { };

  cyrus_sasl = callPackage ../development/libraries/cyrus-sasl { };

  # Make bdb5 the default as it is the last release under the custom
  # bsd-like license
  db = db5;
  db4 = db48;
  db44 = callPackage ../development/libraries/db/db-4.4.nix { };
  db45 = callPackage ../development/libraries/db/db-4.5.nix { };
  db47 = callPackage ../development/libraries/db/db-4.7.nix { };
  db48 = callPackage ../development/libraries/db/db-4.8.nix { };
  db5 = db53;
  db53 = callPackage ../development/libraries/db/db-5.3.nix { };
  db6 = db60;
  db60 = callPackage ../development/libraries/db/db-6.0.nix { };

  dbus_cplusplus  = callPackage ../development/libraries/dbus-cplusplus { };
  dbus_glib       = callPackage ../development/libraries/dbus-glib { };
  dbus_java       = callPackage ../development/libraries/java/dbus-java { };
  dbus_python     = callPackage ../development/python-modules/dbus { };

  # Should we deprecate these? Currently there are many references.
  dbus_tools = pkgs.dbus.tools;
  dbus_libs = pkgs.dbus.libs;
  dbus_daemon = pkgs.dbus.daemon;

  dillo = callPackage ../applications/networking/browsers/dillo {
    fltk = fltk13;
  };

  dragonegg = llvmPackages.dragonegg;

  eigen2 = callPackage ../development/libraries/eigen/2.0.nix {};

  extremetuxracer = builderDefsPackage (import ../games/extremetuxracer) {
    inherit mesa tcl freeglut SDL SDL_mixer pkgconfig
      gettext intltool;
    inherit (xlibs) libX11 xproto libXi inputproto
      libXmu libXext xextproto libXt libSM libICE;
    libpng = libpng12;
  };

  farstream = callPackage ../development/libraries/farstream {
    inherit (gst_all_1)
      gstreamer gst-plugins-base gst-python gst-plugins-good gst-plugins-bad
      gst-libav;
  };

  ffmpeg_0_6 = callPackage ../development/libraries/ffmpeg/0.6.nix {
    vpxSupport = !stdenv.isMips;
  };

  ffmpeg_0_6_90 = callPackage ../development/libraries/ffmpeg/0.6.90.nix {
    vpxSupport = !stdenv.isMips;
  };

  ffmpeg_0_10 = callPackage ../development/libraries/ffmpeg/0.10.nix {
    vpxSupport = !stdenv.isMips;

    stdenv = if stdenv.isDarwin
      then overrideGCC stdenv gccApple
      else stdenv;
  };

  ffmpeg_1 = callPackage ../development/libraries/ffmpeg/1.x.nix {
    vpxSupport = !stdenv.isMips;
  };

  ffmpeg_2 = callPackage ../development/libraries/ffmpeg/2.x.nix { };

  ffmpeg = ffmpeg_2;

  fftwSinglePrec = fftw.override { precision = "single"; };
  fftwFloat = fftwSinglePrec; # the configure option is just an alias

  fltk13 = callPackage ../development/libraries/fltk/fltk13.nix { };

  fltk20 = callPackage ../development/libraries/fltk { };

  makeFontsConf = let fontconfig_ = fontconfig; in {fontconfig ? fontconfig_, fontDirectories}:
    import ../development/libraries/fontconfig/make-fonts-conf.nix {
      inherit runCommand libxslt fontconfig fontDirectories;
    };

  freeglut = if stdenv.isDarwin then darwinX11AndOpenGL else
    callPackage ../development/libraries/freeglut { };

  fam = gamin;

  gdome2 = callPackage ../development/libraries/gdome2 {
    inherit (gnome) gtkdoc;
  };

  gegl = callPackage ../development/libraries/gegl {
    #  avocodec avformat librsvg
  };

  gegl_0_0_22 = callPackage ../development/libraries/gegl/0_0_22.nix {
    #  avocodec avformat librsvg
    libpng = libpng12;
  };

  geoclue2 = callPackage ../development/libraries/geoclue/2.0.nix {};

  gettext = gettext_0_18;

  gettext_0_17 = callPackage ../development/libraries/gettext/0.17.nix { };
  gettext_0_18 = callPackage ../development/libraries/gettext { };

  libgit2 = callPackage ../development/libraries/git2 { };

  glfw = glfw3;
  glfw2 = callPackage ../development/libraries/glfw/2.x.nix { };
  glfw3 = callPackage ../development/libraries/glfw/3.x.nix { };

  glibc = callPackage ../development/libraries/glibc/2.19 {
    kernelHeaders = linuxHeaders;
    installLocales = config.glibc.locales or false;
    machHeaders = null;
    hurdHeaders = null;
    gccCross = null;
  };

  glibc_memusage = callPackage ../development/libraries/glibc/2.19 {
    kernelHeaders = linuxHeaders;
    installLocales = false;
    withGd = true;
  };

  glibcCross = forceNativeDrv (makeOverridable (import ../development/libraries/glibc/2.19)
    (let crossGNU = crossSystem != null && crossSystem.config == "i586-pc-gnu";
     in {
       inherit stdenv fetchurl;
       gccCross = gccCrossStageStatic;
       kernelHeaders = if crossGNU then gnu.hurdHeaders else linuxHeadersCross;
       installLocales = config.glibc.locales or false;
     }
     // lib.optionalAttrs crossGNU {
        inherit (gnu) machHeaders hurdHeaders libpthreadHeaders mig;
        inherit fetchgit;
      }));


  # We can choose:
  libcCrossChooser = name : if name == "glibc" then glibcCross
    else if name == "uclibc" then uclibcCross
    else if name == "msvcrt" then windows.mingw_w64
    else if name == "libSystem" then darwin.xcode
    else throw "Unknown libc";

  libcCross = assert crossSystem != null; libcCrossChooser crossSystem.libc;

  eglibc = callPackage ../development/libraries/eglibc {
    kernelHeaders = linuxHeaders;
    installLocales = config.glibc.locales or false;
  };

  glibcLocales = callPackage ../development/libraries/glibc/2.19/locales.nix { };

  glibcInfo = callPackage ../development/libraries/glibc/2.19/info.nix { };

  glibc_multi =
    runCommand "${glibc.name}-multi"
      { glibc64 = glibc;
        glibc32 = (import ./all-packages.nix {system = "i686-linux";}).glibc;
      }
      ''
        mkdir -p $out
        ln -s $glibc64/* $out/

        rm $out/lib $out/lib64
        mkdir -p $out/lib
        ln -s $glibc64/lib/* $out/lib
        ln -s $glibc32/lib $out/lib/32
        ln -s lib $out/lib64

        # fixing ldd RLTDLIST
        rm $out/bin
        cp -rs $glibc64/bin $out
        chmod u+w $out/bin
        rm $out/bin/ldd
        sed -e "s|^RTLDLIST=.*$|RTLDLIST=\"$out/lib/ld-2.19.so $out/lib/32/ld-linux.so.2\"|g" \
            $glibc64/bin/ldd > $out/bin/ldd
        chmod 555 $out/bin/ldd

        rm $out/include
        cp -rs $glibc32/include $out
        chmod -R u+w $out/include
        cp -rsf $glibc64/include $out
      '' # */
      ;

  glsurf = callPackage ../applications/science/math/glsurf {
    inherit (ocamlPackages) lablgl findlib camlimages ocaml_mysql mlgmp;
    libpng = libpng12;
    giflib = giflib_4_1;
  };

  gmp = gmp5;
  gmp5 = gmp51;

  gmpxx = appendToName "with-cxx" (gmp.override { cxx = true; });

  # The GHC bootstrap binaries link against libgmp.so.3, which is in GMP 4.x.
  gmp4 = callPackage ../development/libraries/gmp/4.3.2.nix { };

  gmp51 = callPackage ../development/libraries/gmp/5.1.x.nix { };

  #GMP ex-satellite, so better keep it near gmp
  mpfr = callPackage ../development/libraries/mpfr/default.nix { };

  gobjectIntrospection = callPackage ../development/libraries/gobject-introspection { };

  gst_all_1 = recurseIntoAttrs(callPackage ../development/libraries/gstreamer {
    callPackage = pkgs.newScope (pkgs // { libav = pkgs.libav_9; });
  });

  gst_all = {
    inherit (pkgs) gstreamer gnonlin gst_python qt_gstreamer;
    gstPluginsBase = pkgs.gst_plugins_base;
    gstPluginsBad = pkgs.gst_plugins_bad;
    gstPluginsGood = pkgs.gst_plugins_good;
    gstPluginsUgly = pkgs.gst_plugins_ugly;
    gstFfmpeg = pkgs.gst_ffmpeg;
  };

  gstreamer = callPackage ../development/libraries/gstreamer/legacy/gstreamer {
    bison = bison2;
  };

  gst_plugins_base = callPackage ../development/libraries/gstreamer/legacy/gst-plugins-base {};

  gst_plugins_good = callPackage ../development/libraries/gstreamer/legacy/gst-plugins-good {};

  gst_plugins_bad = callPackage ../development/libraries/gstreamer/legacy/gst-plugins-bad {};

  gst_plugins_ugly = callPackage ../development/libraries/gstreamer/legacy/gst-plugins-ugly {};

  gst_ffmpeg = callPackage ../development/libraries/gstreamer/legacy/gst-ffmpeg {
    ffmpeg = ffmpeg_0_10;
  };

  gst_python = callPackage ../development/libraries/gstreamer/legacy/gst-python {};

  gusb = callPackage ../development/libraries/gusb {
    inherit (gnome) gtkdoc;
  };

  qt_gstreamer = callPackage ../development/libraries/gstreamer/legacy/qt-gstreamer {};

  gnutls = gnutls32;

  gnutls31 = callPackage ../development/libraries/gnutls/3.1.nix {
    guileBindings = config.gnutls.guile or false;
  };

  gnutls32 = callPackage ../development/libraries/gnutls/3.2.nix {
    guileBindings = config.gnutls.guile or false;
  };

  gnutls_with_guile = lowPrio (gnutls.override { guileBindings = true; });

  gpgme = callPackage ../development/libraries/gpgme {
    gnupg1 = gnupg1orig;
  };

  gtkLibs = {
    inherit (pkgs) glib glibmm atk atkmm cairo pango pangomm gdk_pixbuf gtk
      gtkmm;
  };

  glib = callPackage ../development/libraries/glib {
    stdenv = if stdenv.isDarwin
      then overrideGCC stdenv gccApple
      else stdenv;
  };
  glib-tested = glib.override { doCheck = true; }; # checked version separate to break cycles
  glib_networking = callPackage ../development/libraries/glib-networking {};

  atkmm = callPackage ../development/libraries/atkmm { };

  cairo = callPackage ../development/libraries/cairo {
    glSupport = config.cairo.gl or (stdenv.isLinux &&
      !stdenv.isArm && !stdenv.isMips);
  };
  pangomm = callPackage ../development/libraries/pangomm { };

  pangox_compat = callPackage ../development/libraries/pangox-compat { };

  gdk_pixbuf = callPackage ../development/libraries/gdk-pixbuf {
    # workaround signal 10 in gdk_pixbuf tests
    stdenv = if stdenv.isDarwin
      then clangStdenv
      else stdenv;
  };

  gtk2 = callPackage ../development/libraries/gtk+/2.x.nix {
    cupsSupport = config.gtk2.cups or stdenv.isLinux;
  };

  gtk3 = callPackage ../development/libraries/gtk+/3.x.nix {
    inherit (gnome3) at_spi2_atk;
  };

  gtk = pkgs.gtk2;

  gtkmm = callPackage ../development/libraries/gtkmm/2.x.nix { };
  gtkmm3 = callPackage ../development/libraries/gtkmm/3.x.nix { };

  gtkmozembedsharp = callPackage ../development/libraries/gtkmozembed-sharp {
    gtksharp = gtksharp2;
  };

  gtksharp1 = callPackage ../development/libraries/gtk-sharp-1 {
    inherit (gnome) libglade libgtkhtml gtkhtml
              libgnomecanvas libgnomeui libgnomeprint
              libgnomeprintui GConf;
  };

  gtksharp2 = callPackage ../development/libraries/gtk-sharp-2 {
    inherit (gnome) libglade libgtkhtml gtkhtml
              libgnomecanvas libgnomeui libgnomeprint
              libgnomeprintui GConf gnomepanel;
  };

  gtksourceviewsharp = callPackage ../development/libraries/gtksourceview-sharp {
    inherit (gnome) gtksourceview;
    gtksharp = gtksharp2;
  };

  gtkspell3 = callPackage ../development/libraries/gtkspell/3.nix { };

  gvfs = callPackage ../development/libraries/gvfs { gconf = gnome.GConf; };

  # TODO : Add MIT Kerberos and let admin choose.
  kerberos = heimdal;

  heimdal = callPackage ../development/libraries/kerberos/heimdal.nix { };

  hspellDicts = callPackage ../development/libraries/hspell/dicts.nix { };

  http-parser = callPackage ../development/libraries/http-parser { inherit (pythonPackages) gyp; };

  hwloc = callPackage ../development/libraries/hwloc {
    inherit (xlibs) libX11;
  };

  hydraAntLogger = callPackage ../development/libraries/java/hydra-ant-logger { };

  imlib = callPackage ../development/libraries/imlib {
    libpng = libpng12;
  };

  irrlicht3843 = callPackage ../development/libraries/irrlicht { };

  isocodes = callPackage ../development/libraries/iso-codes { };

  jamp = builderDefsPackage ../games/jamp {
    inherit mesa SDL SDL_image SDL_mixer;
  };

  jetty_gwt = callPackage ../development/libraries/java/jetty-gwt { };

  jetty_util = callPackage ../development/libraries/java/jetty-util { };

  json_glib = callPackage ../development/libraries/json-glib { };

  json-c-0-11 = callPackage ../development/libraries/json-c/0.11.nix { }; # vulnerable
  json_c = callPackage ../development/libraries/json-c { };

  keybinder = callPackage ../development/libraries/keybinder {
    automake = automake111x;
    lua = lua5_1;
  };

  keybinder3 = callPackage ../development/libraries/keybinder3 {
    automake = automake111x;
    lua = lua5_1;
  };

  krb5 = callPackage ../development/libraries/kerberos/krb5.nix { };

  lcms = lcms1;

  lcms1 = callPackage ../development/libraries/lcms { };

  lesstif93 = callPackage ../development/libraries/lesstif-0.93 { };

  leptonica = callPackage ../development/libraries/leptonica {
    libpng = libpng12;
  };

  lgi = callPackage ../development/libraries/lgi {
    lua = lua5_1;
  };

  libao = callPackage ../development/libraries/libao {
    usePulseAudio = config.pulseaudio or true;
  };

  libassuan2_1 = callPackage ../development/libraries/libassuan/git.nix { };

  libav = libav_10;
  libav_all = callPackage ../development/libraries/libav { };
  inherit (libav_all) libav_0_8 libav_9 libav_10;

  libcanberra_gtk3 = libcanberra.override { gtk = gtk3; };
  libcanberra_kde = if (config.kde_runtime.libcanberraWithoutGTK or true)
    then libcanberra.override { gtk = null; }
    else libcanberra;

  libcdio082 = callPackage ../development/libraries/libcdio/0.82.nix { };

  libcdr = callPackage ../development/libraries/libcdr { lcms = lcms2; };

  libchamplain = callPackage ../development/libraries/libchamplain {
    inherit (gnome) libsoup;
  };

  libchamplain_0_6 = callPackage ../development/libraries/libchamplain/0.6.nix {};

  inherit (gnome3) libcroco;

  libdbiDriversBase = callPackage ../development/libraries/libdbi-drivers {
    mysql = null;
    sqlite = null;
  };

  libdbiDrivers = libdbiDriversBase.override {
    inherit sqlite mysql;
  };

  libdbusmenu_qt = callPackage ../development/libraries/libdbusmenu-qt { };

  libdrm = callPackage ../development/libraries/libdrm {
    inherit fetchurl stdenv pkgconfig;
    inherit (xorg) libpthreadstubs;
  };

  libgdata = gnome3.libgdata;

  libgnome_keyring = callPackage ../development/libraries/libgnome-keyring { };
  libgnome_keyring3 = gnome3.libgnome_keyring;

  liblrdf = librdf;

  libe-book_00 = callPackage ../development/libraries/libe-book/0.0.nix {};

  libev = builderDefsPackage ../development/libraries/libev { };

  libevent14 = callPackage ../development/libraries/libevent/1.4.nix { };
  libexosip = callPackage ../development/libraries/exosip {};

  libexosip_3 = callPackage ../development/libraries/exosip/3.x.nix {
    libosip = libosip_3;
  };

  libextractor = callPackage ../development/libraries/libextractor {
    libmpeg2 = mpeg2dec;
  };

  libffcall = builderDefsPackage (import ../development/libraries/libffcall) {
    inherit fetchcvs;
  };

  libftdi1 = callPackage ../development/libraries/libftdi/1.x.nix { };

  libgcrypt_1_6 = lowPrio (callPackage ../development/libraries/libgcrypt/1.6.nix { });

  libgpgerror = callPackage ../development/libraries/libgpg-error { };

  libgphoto2_4 = callPackage ../development/libraries/libgphoto2/2.4.nix { };

  libgpod = callPackage ../development/libraries/libgpod {
    inherit (pkgs.pythonPackages) mutagen;
  };

  libiodbc = callPackage ../development/libraries/libiodbc {
    useGTK = config.libiodbc.gtk or false;
  };

  liblqr1 = callPackage ../development/libraries/liblqr-1 { };

  libQGLViewer = callPackage ../development/libraries/libqglviewer { };

  librem = callPackage ../development/libraries/librem {};

  libsamplerate = callPackage ../development/libraries/libsamplerate {
    stdenv = if stdenv.isDarwin
      then overrideGCC stdenv gccApple
      else stdenv;
  };

  libiconvOrEmpty = if libiconvOrNull == null then [] else [libiconv];

  libiconvOrNull =
    if gcc.libc or null != null || stdenv.isGlibc
    then null
    else libiconv;

  # The logic behind this attribute is broken: libiconvOrNull==null does
  # NOT imply libiconv=glibc! On Darwin, for example, we have a native
  # libiconv library which is not glibc.
  libiconvOrLibc = if libiconvOrNull == null then gcc.libc else libiconv;

  # On non-GNU systems we need GNU Gettext for libintl.
  libintlOrEmpty = stdenv.lib.optional (!stdenv.isLinux) gettext;

  libinfinity = callPackage ../development/libraries/libinfinity {
    inherit (gnome) gtkdoc;
  };

  libjpeg_original = callPackage ../development/libraries/libjpeg { };
  libjpeg_turbo = callPackage ../development/libraries/libjpeg-turbo { };
  libjpeg = if (stdenv.isLinux) then libjpeg_turbo else libjpeg_original; # some problems, both on FreeBSD and Darwin

  libjpeg62 = callPackage ../development/libraries/libjpeg/62.nix {
    libtool = libtool_1_5;
  };

  libjson_rpc_cpp = callPackage ../development/libraries/libjson-rpc-cpp { };

  libmatthew_java = callPackage ../development/libraries/java/libmatthew-java { };

  libmikmod = callPackage ../development/libraries/libmikmod {
    # resolve the "stray '@' in program" errors
    stdenv = if stdenv.isDarwin
      then overrideGCC stdenv gccApple
      else stdenv;
  };

  libmusicbrainz2 = callPackage ../development/libraries/libmusicbrainz/2.x.nix { };

  libmusicbrainz3 = callPackage ../development/libraries/libmusicbrainz { };

  libmusicbrainz5 = callPackage ../development/libraries/libmusicbrainz/5.x.nix { };

  libmusicbrainz = libmusicbrainz3;

  libmwaw_02 = callPackage ../development/libraries/libmwaw/0.2.nix { };

  libosip = callPackage ../development/libraries/osip {};

  libosip_3 = callPackage ../development/libraries/osip/3.nix {};

  libotr = callPackage ../development/libraries/libotr {
    libgcrypt = libgcrypt_1_6;
  };

  libotr_3_2 = callPackage ../development/libraries/libotr/3.2.nix { };

  libpng_apng = libpng.override { apngSupport = true; };
  libpng12 = callPackage ../development/libraries/libpng/12.nix { };
  libpng15 = callPackage ../development/libraries/libpng/15.nix { };

  libproxy = callPackage ../development/libraries/libproxy {
    stdenv = if stdenv.isDarwin
      then overrideGCC stdenv gcc
      else stdenv;
  };

  librsvg = callPackage ../development/libraries/librsvg {
    gtk2 = null; gtk3 = null; # neither gtk version by default
  };

  libsigcxx12 = callPackage ../development/libraries/libsigcxx/1.2.nix { };

  # To bootstrap SBCL, I need CLisp 2.44.1; it needs libsigsegv 2.5
  libsigsegv_25 = callPackage ../development/libraries/libsigsegv/2.5.nix { };

  libsndfile = callPackage ../development/libraries/libsndfile {
    stdenv = if stdenv.isDarwin
      then overrideGCC stdenv gccApple
      else stdenv;
  };

  libstartup_notification = callPackage ../development/libraries/startup-notification { };

  libtorrentRasterbar = callPackage ../development/libraries/libtorrent-rasterbar {
    # fix "unrecognized option -arch" error
    stdenv = if stdenv.isDarwin
      then clangStdenv
      else stdenv;
  };

  libupnp = callPackage ../development/libraries/pupnp { };

  giflib_4_1 = callPackage ../development/libraries/giflib/4.1.nix { };

  libungif = callPackage ../development/libraries/giflib/libungif.nix { };

  libunique = callPackage ../development/libraries/libunique/default.nix { };

  libusb = callPackage ../development/libraries/libusb {
    stdenv = if stdenv.isDarwin
      then overrideGCC stdenv gccApple
      else stdenv;
  };

  libusb1 = callPackage ../development/libraries/libusb1 {
    stdenv = if stdenv.isDarwin # http://gcc.gnu.org/bugzilla/show_bug.cgi?id=50909
      then overrideGCC stdenv gccApple
      else stdenv;
  };

  libv4l = lowPrio (v4l_utils.override {
    withQt4 = false;
  });

  libwnck = libwnck2;
  libwnck2 = callPackage ../development/libraries/libwnck { };
  libwnck3 = callPackage ../development/libraries/libwnck/3.x.nix { };

  libwpd_08 = callPackage ../development/libraries/libwpd/0.8.nix { };

  libx86 = builderDefsPackage ../development/libraries/libx86 {};

  libxdg_basedir = callPackage ../development/libraries/libxdg-basedir { };

  libxml2 = callPackage ../development/libraries/libxml2 {
    pythonSupport = false;
  };

  libxml2Python = lowPrio (libxml2.override {
    pythonSupport = true;
  });

  libixp_for_wmii = lowPrio (import ../development/libraries/libixp_for_wmii {
    inherit fetchurl stdenv;
  });

  libyamlcpp = callPackage ../development/libraries/libyaml-cpp { };
  libyamlcpp03 = callPackage ../development/libraries/libyaml-cpp/0.3.x.nix { };

  libzrtpcpp_1_6 = callPackage ../development/libraries/libzrtpcpp/1.6.nix {
    ccrtp = ccrtp_1_8;
  };

  liquidwar = builderDefsPackage ../games/liquidwar {
    inherit (xlibs) xproto libX11 libXrender;
    inherit gmp mesa libjpeg
      expat gettext perl
      SDL SDL_image SDL_mixer SDL_ttf
      curl sqlite
      libogg libvorbis
      ;
    guile = guile_1_8;
    libpng = libpng15; # 0.0.13 needs libpng 1.2--1.5
  };

  mdds_0_7_1 = callPackage ../development/libraries/mdds/0.7.1.nix { };
  # failed to build
  mesaSupported = lib.elem system lib.platforms.mesaPlatforms;

  mesa_original = callPackage ../development/libraries/mesa {
    # makes it slower, but during runtime we link against just mesa_drivers
    # through /run/opengl-driver*, which is overriden according to config.grsecurity
    grsecEnabled = true;
  };

  mesa_noglu = if stdenv.isDarwin
    then darwinX11AndOpenGL // { driverLink = mesa_noglu; }
    else mesa_original;
  mesa_drivers = let
      mo = mesa_original.override { grsecEnabled = config.grsecurity or false; };
    in mo.drivers;
  mesa_glu = callPackage ../development/libraries/mesa-glu { };
  mesa = if stdenv.isDarwin then darwinX11AndOpenGL
    else buildEnv {
      name = "mesa-${mesa_noglu.version}";
      paths = [ mesa_glu mesa_noglu ];
    };
  darwinX11AndOpenGL = callPackage ../os-specific/darwin/native-x11-and-opengl { };

  metaEnvironment = recurseIntoAttrs (let callPackage = newScope pkgs.metaEnvironment; in rec {
    sdfLibrary    = callPackage ../development/libraries/sdf-library { aterm = aterm28; };
    toolbuslib    = callPackage ../development/libraries/toolbuslib { aterm = aterm28; inherit (windows) w32api; };
    cLibrary      = callPackage ../development/libraries/c-library { aterm = aterm28; };
    errorSupport  = callPackage ../development/libraries/error-support { aterm = aterm28; };
    ptSupport     = callPackage ../development/libraries/pt-support { aterm = aterm28; };
    ptableSupport = callPackage ../development/libraries/ptable-support { aterm = aterm28; };
    configSupport = callPackage ../development/libraries/config-support { aterm = aterm28; };
    asfSupport    = callPackage ../development/libraries/asf-support { aterm = aterm28; };
    tideSupport   = callPackage ../development/libraries/tide-support { aterm = aterm28; };
    rstoreSupport = callPackage ../development/libraries/rstore-support { aterm = aterm28; };
    sdfSupport    = callPackage ../development/libraries/sdf-support { aterm = aterm28; };
    sglr          = callPackage ../development/libraries/sglr { aterm = aterm28; };
    ascSupport    = callPackage ../development/libraries/asc-support { aterm = aterm28; };
    pgen          = callPackage ../development/libraries/pgen { aterm = aterm28; };
  });

  miro = callPackage ../applications/video/miro {
    inherit (pythonPackages) pywebkitgtk pysqlite pycurl mutagen;
  };

  mpeg2dec = libmpeg2;

  mu = callPackage ../tools/networking/mu {
    texinfo = texinfo4;
  };

  myguiSvn = callPackage ../development/libraries/mygui/svn.nix {};

  ncurses = callPackage ../development/libraries/ncurses {
    unicode = system != "i686-cygwin";
    stdenv =
      # On Darwin, NCurses uses `-no-cpp-precomp', which is specific to
      # Apple-GCC.  Since NCurses is part of stdenv, always use
      # `stdenvNative' to build it.
      if stdenv.isDarwin
      then allStdenvs.stdenvNative
      else stdenv;
  };

  neon = callPackage ../development/libraries/neon {
    compressionSupport = true;
    sslSupport = true;
  };

  nethack = builderDefsPackage (import ../games/nethack) {
    inherit ncurses flex bison;
  };

  nix-plugins = callPackage ../development/libraries/nix-plugins {
    nix = pkgs.nixUnstable;
  };

  nss = lowPrio (callPackage ../development/libraries/nss { });

  nssTools = callPackage ../development/libraries/nss {
    includeTools = true;
  };

  ode = builderDefsPackage (import ../development/libraries/ode) { };

  # added because I hope that it has been easier to compile on x86 (for blender)
  openalSoft = callPackage ../development/libraries/openal-soft { };

  opencascade_6_5 = callPackage ../development/libraries/opencascade/6.5.nix {
    automake = automake111x;
    ftgl = ftgl212;
  };

  opencascade_oce = callPackage ../development/libraries/opencascade/oce.nix { };

  opencv_2_1 = callPackage ../development/libraries/opencv/2.1.nix {
    libpng = libpng12;
  };

  # this ctl version is needed by openexr_viewers
  libopensc_dnie = callPackage ../development/libraries/libopensc-dnie { };

  openjpeg = callPackage ../development/libraries/openjpeg { lcms = lcms2; };

  openscenegraph = callPackage ../development/libraries/openscenegraph {
    giflib = giflib_4_1;
    ffmpeg = ffmpeg_0_10;
  };

  openssl = callPackage ../development/libraries/openssl {
    fetchurl = fetchurlBoot;
    cryptodevHeaders = linuxPackages.cryptodev.override {
      fetchurl = fetchurlBoot;
      onlyHeaders = true;
    };
  };

  ortp = callPackage ../development/libraries/ortp {
    srtp = srtp_linphone;
  };

  p11_kit = callPackage ../development/libraries/p11-kit { };

  pcl = callPackage ../development/libraries/pcl {
    vtk = vtkWithQt4;
  };

  pcre = callPackage ../development/libraries/pcre {
    unicodeSupport = config.pcre.unicode or true;
  };

  pdf2xml = callPackage ../development/libraries/pdf2xml {} ;

  pdf2htmlex = callPackage ../development/libraries/pdf2htmlex {} ;

  phonon_backend_gstreamer = callPackage ../development/libraries/phonon-backend-gstreamer { };

  phonon_backend_vlc = callPackage ../development/libraries/phonon-backend-vlc { };

  polkit = callPackage ../development/libraries/polkit {
    spidermonkey = spidermonkey_185;
  };

  polkit_qt_1 = callPackage ../development/libraries/polkit-qt-1 { };

  poppler = callPackage ../development/libraries/poppler { lcms = lcms2; };
  popplerQt4 = poppler.poppler_qt4;

  portaudio = callPackage ../development/libraries/portaudio {
    # resolves a variety of compile-time errors
    stdenv = if stdenv.isDarwin
      then clangStdenv
      else stdenv;
  };

  portaudioSVN = callPackage ../development/libraries/portaudio/svn-head.nix { };

  qca2_ossl = callPackage ../development/libraries/qca2/ossl.nix {};

  qt3 = callPackage ../development/libraries/qt-3 {
    openglSupport = mesaSupported;
    libpng = libpng12;
  };

  qt4 = pkgs.kde4.qt4;

  qt48 = callPackage ../development/libraries/qt-4.x/4.8 {
    # GNOME dependencies are not used unless gtkStyle == true
    mesa = mesa_noglu;
    inherit (pkgs.gnome) libgnomeui GConf gnome_vfs;
    cups = if stdenv.isLinux then cups else null;

    # resolve unrecognised flag '-fconstant-cfstrings' errors
    stdenv = if stdenv.isDarwin
      then clangStdenv
      else stdenv;
  };

  qt48Full = qt48.override {
    docs = true;
    demos = true;
    examples = true;
    developerBuild = true;
  };

  qt4SDK = qtcreator.override {
    sdkBuild = true;
    qtLib = qt48Full;
  };

  qt5 = callPackage ../development/libraries/qt-5 {
    mesa = mesa_noglu;
    cups = if stdenv.isLinux then cups else null;
    # GNOME dependencies are not used unless gtkStyle == true
    inherit (gnome) libgnomeui GConf gnome_vfs;
    bison = bison2; # error: too few arguments to function 'int yylex(...
  };

  qt5Full = qt5.override {
    buildDocs = true;
    buildExamples = true;
    buildTests = true;
    developerBuild = true;
  };

  qt5SDK = qtcreator.override {
    sdkBuild = true;
    qtLib = qt5Full;
  };

  qtcreator = callPackage ../development/qtcreator {
    qtLib = qt48.override { developerBuild = true; };
  };

  qwt6 = callPackage ../development/libraries/qwt/6.nix { };

  readline = readline6; # 6.2 works, 6.3 breaks python, parted

  readline4 = callPackage ../development/libraries/readline/readline4.nix { };

  readline5 = callPackage ../development/libraries/readline/readline5.nix { };

  readline6 = callPackage ../development/libraries/readline/readline6.nix {
    stdenv =
      # On Darwin, Readline uses `-arch_only', which is specific to
      # Apple-GCC.  So give it what it expects.
      if stdenv.isDarwin
      then overrideGCC stdenv gccApple
      else stdenv;
  };

  readline63 = callPackage ../development/libraries/readline/readline6.3.nix {
    stdenv =
      # On Darwin, Readline uses `-arch_only', which is specific to
      # Apple-GCC.  So give it what it expects.
      if stdenv.isDarwin
      then overrideGCC stdenv gccApple
      else stdenv;
  };

  librdf_raptor = callPackage ../development/libraries/librdf/raptor.nix { };

  librdf_raptor2 = callPackage ../development/libraries/librdf/raptor2.nix { };

  librdf_rasqal = callPackage ../development/libraries/librdf/rasqal.nix { };

  librdf_redland = callPackage ../development/libraries/librdf/redland.nix { };

  redland = pkgs.librdf_redland;

  rhino = callPackage ../development/libraries/java/rhino {
    javac = gcj;
    jvm = gcj;
  };

  rubberband = callPackage ../development/libraries/rubberband {
    fftw = fftwSinglePrec;
    inherit (vamp) vampSDK;
  };

  SDL = callPackage ../development/libraries/SDL {
    openglSupport = mesaSupported;
    alsaSupport = (!stdenv.isDarwin);
    x11Support = true;
    pulseaudioSupport = stdenv.isDarwin; # better go through ALSA

    # resolve the unrecognized -fpascal-strings option error
    stdenv = if stdenv.isDarwin
      then clangStdenv
      else stdenv;
  };

  SDL_image = callPackage ../development/libraries/SDL_image {
    # provide an Objective-C compiler
    stdenv = if stdenv.isDarwin
      then clangStdenv
      else stdenv;
  };

  SDL2 = callPackage ../development/libraries/SDL2 {
    openglSupport = mesaSupported;
    alsaSupport = true;
    x11Support = true;
    pulseaudioSupport = false; # better go through ALSA
  };

  graphite2 = callPackage ../development/libraries/silgraphite/graphite2.nix {};

  sfml_git = callPackage ../development/libraries/sfml { };

  slibGuile = callPackage ../development/libraries/slib {
    scheme = guile_1_8;
    texinfo = texinfo4; # otherwise erros: must be after `@defun' to use `@defunx'
  };

  snack = callPackage ../development/libraries/snack {
        # optional
  };

  sofia_sip = callPackage ../development/libraries/sofia-sip { };

  speech_tools = callPackage ../development/libraries/speech-tools {};

  spice = callPackage ../development/libraries/spice {
    celt = celt_0_5_1;
    inherit (xlibs) libXrandr libXfixes libXext libXrender libXinerama;
    inherit (pythonPackages) pyparsing;
  };

  spice_gtk = callPackage ../development/libraries/spice-gtk { };

  spice_protocol = callPackage ../development/libraries/spice-protocol { };

  srtp_linphone = callPackage ../development/libraries/srtp/linphone.nix { };

  sqlite = lowPrio (callPackage ../development/libraries/sqlite {
    readline = null;
    ncurses = null;
  });

  sqliteInteractive = appendToName "interactive" (sqlite.override {
    inherit readline ncurses;
  });

  sqlcipher = lowPrio (callPackage ../development/libraries/sqlcipher {
    readline = null;
    ncurses = null;
  });

  stfl = callPackage ../development/libraries/stfl {
    stdenv = if stdenv.isDarwin
      then overrideGCC stdenv gccApple
      else stdenv;
  };

  strigi = callPackage ../development/libraries/strigi { clucene_core = clucene_core_2; };

  taglib_extras = callPackage ../development/libraries/taglib-extras { };

  telepathy_glib = callPackage ../development/libraries/telepathy/glib { };

  telepathy_farstream = callPackage ../development/libraries/telepathy/farstream {};

  telepathy_qt = callPackage ../development/libraries/telepathy/qt { };

  tinyxml = tinyxml2;

  tinyxml2 = callPackage ../development/libraries/tinyxml/2.6.2.nix { };

  tokyocabinet = callPackage ../development/libraries/tokyo-cabinet { };
  tokyotyrant = callPackage ../development/libraries/tokyo-tyrant { };

  unixODBCDrivers = recurseIntoAttrs (import ../development/libraries/unixODBCDrivers {
    inherit fetchurl stdenv unixODBC glibc libtool openssl zlib;
    inherit postgresql mysql sqlite;
  });

  usbredir = callPackage ../development/libraries/usbredir {
    libusb = libusb1;
  };

  v8 = callPackage ../development/libraries/v8 {
    inherit (pythonPackages) gyp;
  };

  vaapiIntel = callPackage ../development/libraries/vaapi-intel { };

  vaapiVdpau = callPackage ../development/libraries/vaapi-vdpau { };

  vigra = callPackage ../development/libraries/vigra {
    inherit (pkgs.pythonPackages) numpy;
  };

  vtkWithQt4 = vtk.override { qtLib = qt4; };

  vxl = callPackage ../development/libraries/vxl {
    libpng = libpng12;
  };

  webkit = webkitgtk;

  webkitgtk = callPackage ../development/libraries/webkitgtk {
    harfbuzz = harfbuzz.override {
      withIcu = true;
    };
    gst-plugins-base = gst_all_1.gst-plugins-base;
  };

  webkitgtk2 = webkitgtk.override {
    withGtk2 = true;
    enableIntrospection = false;
  };

  wxGTK = wxGTK28;

  wxGTK28 = callPackage ../development/libraries/wxGTK-2.8 {
    inherit (gnome) GConf;
    withMesa = lib.elem system lib.platforms.mesaPlatforms;
  };

  wxGTK29 = callPackage ../development/libraries/wxGTK-2.9/default.nix {
    inherit (gnome) GConf;
    withMesa = lib.elem system lib.platforms.mesaPlatforms;

    # use for Objective-C++ compiler
    stdenv = if stdenv.isDarwin
      then clangStdenv
      else stdenv;
  };

  wxGTK30 = callPackage ../development/libraries/wxGTK-3.0/default.nix {
    inherit (gnome) GConf;
    withMesa = lib.elem system lib.platforms.mesaPlatforms;

    # use for Objective-C++ compiler
    stdenv = if stdenv.isDarwin
      then clangStdenv
      else stdenv;
  };

  xapianBindings = callPackage ../development/libraries/xapian/bindings {  # TODO perl php Java, tcl, C#, python
  };

  xapian10 = callPackage ../development/libraries/xapian/1.0.x.nix { };

  xapianBindings10 = callPackage ../development/libraries/xapian/bindings/1.0.x.nix {  # TODO perl php Java, tcl, C#, python
  };

  xineLib = callPackage ../development/libraries/xine-lib {
    ffmpeg = ffmpeg_1;
  };

  xlibsWrapper = callPackage ../development/libraries/xlibs-wrapper {
    packages = [
      freetype fontconfig xlibs.xproto xlibs.libX11 xlibs.libXt
      xlibs.libXft xlibs.libXext xlibs.libSM xlibs.libICE
      xlibs.xextproto
    ];
  };

  xmlrpc_c = callPackage ../development/libraries/xmlrpc-c { };

  zangband = builderDefsPackage (import ../games/zangband) {
    inherit ncurses flex bison autoconf automake m4 coreutils;
  };

  zlib = callPackage ../development/libraries/zlib {
    fetchurl = fetchurlBoot;
  };

  zlibStatic = lowPrio (appendToName "static" (callPackage ../development/libraries/zlib {
    static = true;
  }));

  zeromq2 = callPackage ../development/libraries/zeromq/2.x.nix {};
  zeromq3 = callPackage ../development/libraries/zeromq/3.x.nix {};
  zeromq4 = callPackage ../development/libraries/zeromq/4.x.nix {};


  ### DEVELOPMENT / LIBRARIES / JAVA

  atermjava = callPackage ../development/libraries/java/aterm {
    stdenv = overrideInStdenv stdenv [gnumake380];
  };

  commonsFileUpload = callPackage ../development/libraries/java/jakarta-commons/file-upload { };

  gwtdragdrop = callPackage ../development/libraries/java/gwt-dragdrop { };

  gwtwidgets = callPackage ../development/libraries/java/gwt-widgets { };

  jakartabcel = callPackage ../development/libraries/java/jakarta-bcel {
    regexp = jakartaregexp;
  };

  jakartaregexp = callPackage ../development/libraries/java/jakarta-regexp { };

  javaCup = callPackage ../development/libraries/java/cup { };

  jjtraveler = callPackage ../development/libraries/java/jjtraveler {
    stdenv = overrideInStdenv stdenv [gnumake380];
  };

  saxonb = callPackage ../development/libraries/java/saxon/default8.nix { };

  sharedobjects = callPackage ../development/libraries/java/shared-objects {
    stdenv = overrideInStdenv stdenv [gnumake380];
  };

  swt = callPackage ../development/libraries/java/swt {
    inherit (gnome) libsoup;
  };


  ### DEVELOPMENT / LIBRARIES / JAVASCRIPT

  jquery_ui = callPackage ../development/libraries/javascript/jquery-ui { };

  ### DEVELOPMENT / LISP MODULES

  asdf = callPackage ../development/lisp-modules/asdf {
    texLive = null;
  };

  clwrapperFunction = callPackage ../development/lisp-modules/clwrapper;

  wrapLisp = lisp: clwrapperFunction { inherit lisp; };

  lispPackagesFor = clwrapper: callPackage ../development/lisp-modules/lisp-packages.nix {
    inherit clwrapper;
  };

  lispPackagesClisp = lispPackagesFor (wrapLisp clisp);
  lispPackagesSBCL = lispPackagesFor (wrapLisp sbcl);
  lispPackages = recurseIntoAttrs lispPackagesSBCL;


  ### DEVELOPMENT / PERL MODULES

  buildPerlPackage = import ../development/perl-modules/generic perl;

  perlPackages = recurseIntoAttrs (import ./perl-packages.nix {
    inherit pkgs;
    overrides = (config.perlPackageOverrides or (p: {})) pkgs;
  });

  perl510Packages = import ./perl-packages.nix {
    pkgs = pkgs // {
      perl = perl510;
      buildPerlPackage = import ../development/perl-modules/generic perl510;
    };
    overrides = (config.perl510PackageOverrides or (p: {})) pkgs;
  };

  perl514Packages = import ./perl-packages.nix {
    pkgs = pkgs // {
      perl = perl514;
      buildPerlPackage = import ../development/perl-modules/generic perl514;
    };
    overrides = (config.perl514PackageOverrides or (p: {})) pkgs;
  };

  perlXMLParser = perlPackages.XMLParser;

  ack = perlPackages.ack;

  perlArchiveCpio = perlPackages.ArchiveCpio;

  perlcritic = perlPackages.PerlCritic;

  planetary_annihilation = callPackage ../games/planetaryannihilation { };


  ### DEVELOPMENT / PYTHON MODULES

  # python function with default python interpreter
  buildPythonPackage = pythonPackages.buildPythonPackage;

  # `nix-env -i python-nose` installs for 2.7, the default python.
  # Therefore we do not recurse into attributes here, in contrast to
  # python27Packages. `nix-env -iA python26Packages.nose` works
  # regardless.
  python26Packages = import ./python-packages.nix {
    inherit pkgs;
    python = python26;
  };

  python27Packages = lib.hiPrioSet (recurseIntoAttrs (import ./python-packages.nix {
    inherit pkgs;
    python = python27;
  }));

  python32Packages = import ./python-packages.nix {
    inherit pkgs;
    python = python32;
  };

  python33Packages = recurseIntoAttrs (import ./python-packages.nix {
    inherit pkgs;
    python = python33;
  });

  python34Packages = recurseIntoAttrs (import ./python-packages.nix {
    inherit pkgs;
    python = python34;
  });

  pypyPackages = recurseIntoAttrs (import ./python-packages.nix {
    inherit pkgs;
    python = pypy;
  });

  foursuite = callPackage ../development/python-modules/4suite { };

  pil = pythonPackages.pil;

  pycairo = pythonPackages.pycairo;

  pycapnp = pythonPackages.pycapnp;

  pycrypto = pythonPackages.pycrypto;

  pygobject = pythonPackages.pygobject;

  pygobject3 = pythonPackages.pygobject3;

  pygtk = pythonPackages.pygtk;

  pyGtkGlade = pythonPackages.pyGtkGlade;

  pyopenssl = builderDefsPackage (import ../development/python-modules/pyopenssl) {
    inherit python openssl;
  };

  pyqt4 = callPackage ../development/python-modules/pyqt/4.x.nix {
    stdenv = if stdenv.isDarwin
      then clangStdenv
      else stdenv;
  };

  pysideApiextractor = callPackage ../development/python-modules/pyside/apiextractor.nix { };

  pysideGeneratorrunner = callPackage ../development/python-modules/pyside/generatorrunner.nix { };

  pysideTools = callPackage ../development/python-modules/pyside/tools.nix { };

  pysideShiboken = callPackage ../development/python-modules/pyside/shiboken.nix { };

  setuptools = pythonPackages.setuptools;

  wxPython = pythonPackages.wxPython;
  wxPython28 = pythonPackages.wxPython28;

  twisted = pythonPackages.twisted;

  ZopeInterface = pythonPackages.zope_interface;

  ### DEVELOPMENT / R MODULES

  R = callPackage ../applications/science/math/R {
    inherit (xlibs) libX11 libXt;
    texLive = texLiveAggregationFun { paths = [ texLive texLiveExtra ]; };
    withRecommendedPackages = false;
  };

  rWrapper = callPackage ../development/r-modules/wrapper.nix {
    # Those packages are usually installed as part of the R build.
    recommendedPackages = with rPackages; [ MASS lattice Matrix nlme
      survival boot cluster codetools foreign KernSmooth rpart class
      nnet spatial mgcv ];
    # Override this attribute to register additional libraries.
    packages = [];
  };

  rPackages = import ../development/r-modules/cran-packages.nix {
    inherit pkgs;
    overrides = (config.rPackageOverrides or (p: {})) pkgs;
  };

  ### SERVERS

  rdf4store = callPackage ../servers/http/4store { };

  apacheHttpd = pkgs.apacheHttpd_2_2;

  apacheHttpd_2_2 = callPackage ../servers/http/apache-httpd/2.2.nix {
    sslSupport = true;
  };

  apacheHttpd_2_4 = lowPrio (callPackage ../servers/http/apache-httpd/2.4.nix {
    sslSupport = true;
  });

  couchdb = callPackage ../servers/http/couchdb {
    spidermonkey = spidermonkey_185;
    python = python27;
    sphinx = python27Packages.sphinx;
    erlang = erlangR16;
  };

  dict = callPackage ../servers/dict {
      libmaa = callPackage ../servers/dict/libmaa.nix {};
  };

  dictdDBs = recurseIntoAttrs (import ../servers/dict/dictd-db.nix {
    inherit builderDefs;
  });

  dictDBCollector = import ../servers/dict/dictd-db-collector.nix {
    inherit stdenv lib dict;
  };

  dictdWiktionary = callPackage ../servers/dict/dictd-wiktionary.nix {};

  dictdWordnet = callPackage ../servers/dict/dictd-wordnet.nix {};

  dovecot = dovecot21;

  dovecot21 = callPackage ../servers/mail/dovecot { };

  dovecot22 = callPackage ../servers/mail/dovecot/2.2.x.nix { };

  dovecot_pigeonhole = callPackage ../servers/mail/dovecot-pigeonhole { };

  ejabberd = callPackage ../servers/xmpp/ejabberd {
    erlang = erlangR16;
  };

  felix_remoteshell = callPackage ../servers/felix/remoteshell.nix { };

  fingerd_bsd = callPackage ../servers/fingerd/bsd-fingerd { };

  firebird = callPackage ../servers/firebird { icu = null; };
  firebirdSuper = callPackage ../servers/firebird { superServer = true; };

  ghostOne = callPackage ../servers/games/ghost-one {
    boost = boost144.override { taggedLayout = true; };
  };

  ircdHybrid = callPackage ../servers/irc/ircd-hybrid { };

  jboss_mysql_jdbc = callPackage ../servers/http/jboss/jdbc/mysql { };

  jetty61 = callPackage ../servers/http/jetty/6.1 { };

  mod_dnssd = callPackage ../servers/http/apache-modules/mod_dnssd/default.nix { };

  mpd = callPackage ../servers/mpd {
    aacSupport    = config.mpd.aacSupport or true;
    ffmpegSupport = config.mpd.ffmpegSupport or true;
  };

  mpd_clientlib = callPackage ../servers/mpd/clientlib.nix { };

  miniHttpd = callPackage ../servers/http/mini-httpd {};

  nginx = callPackage ../servers/http/nginx {
    rtmp        = true;
    fullWebDAV  = true;
    syslog      = true;
    moreheaders = true;
  };

  postfix211 = callPackage ../servers/mail/postfix/2.11.nix { };

  pulseaudio = callPackage ../servers/pulseaudio {
    gconf = gnome.GConf;
    # The following are disabled in the default build, because if this
    # functionality is desired, they are only needed in the PulseAudio
    # server.
    bluez = null;
    avahi = null;
  };

  tomcat_connectors = callPackage ../servers/http/apache-modules/tomcat-connectors { };

  #monetdb = callPackage ../servers/sql/monetdb { };

  riak = callPackage ../servers/nosql/riak/1.3.1.nix { };

  mysql51 = import ../servers/sql/mysql/5.1.x.nix {
    inherit fetchurl ncurses zlib perl openssl stdenv;
    ps = procps; /* !!! Linux only */
  };

  mysql55 = callPackage ../servers/sql/mysql/5.5.x.nix { };

  mysql = mysql51;

  mysql_jdbc = callPackage ../servers/sql/mysql/jdbc { };

  nagiosPluginsOfficial = callPackage ../servers/monitoring/nagios/plugins/official-2.x.nix { };

  net_snmp = callPackage ../servers/monitoring/net-snmp { };

  oracleXE = callPackage ../servers/sql/oracle-xe { };

  postgresql = postgresql92;

  postgresql84 = callPackage ../servers/sql/postgresql/8.4.x.nix { };

  postgresql90 = callPackage ../servers/sql/postgresql/9.0.x.nix { };

  postgresql91 = callPackage ../servers/sql/postgresql/9.1.x.nix { };

  postgresql92 = callPackage ../servers/sql/postgresql/9.2.x.nix { };

  postgresql93 = callPackage ../servers/sql/postgresql/9.3.x.nix { };

  postgresql_jdbc = callPackage ../servers/sql/postgresql/jdbc { };

  pyIRCt = builderDefsPackage (import ../servers/xmpp/pyIRCt) {
    inherit xmpppy pythonIRClib python makeWrapper;
  };

  pyMAILt = builderDefsPackage (import ../servers/xmpp/pyMAILt) {
    inherit xmpppy python makeWrapper fetchcvs;
  };

  rabbitmq_server = callPackage ../servers/amqp/rabbitmq-server { };

  redis = callPackage ../servers/nosql/redis {
    stdenv =
      if stdenv.isDarwin
      then overrideGCC stdenv gccApple
      else stdenv;
  };

  spamassassin = callPackage ../servers/mail/spamassassin {
    inherit (perlPackages) HTMLParser NetDNS NetAddrIP DBFile
      HTTPDate MailDKIM LWP IOSocketSSL;
  };

  # A lightweight Samba, useful for non-Linux-based OSes.
  samba_light = lowPrio (callPackage ../servers/samba {
    pam = null;
    fam = null;
    cups = null;
    acl = null;
    openldap = null;
    # libunwind 1.0.1 is not ported to GNU/Hurd.
    libunwind = null;
  });

  spawn_fcgi = callPackage ../servers/http/spawn-fcgi { };

  squids = recurseIntoAttrs( import ../servers/squid/squids.nix {
    inherit fetchurl stdenv perl lib composableDerivation
      openldap pam db cyrus_sasl kerberos libcap expat libxml2 libtool
      openssl;
  });
  squid = squids.squid31; # has ipv6 support

  tomcat5 = callPackage ../servers/http/tomcat/5.0.nix { };

  tomcat6 = callPackage ../servers/http/tomcat/6.0.nix { };

  tomcat_mysql_jdbc = callPackage ../servers/http/tomcat/jdbc/mysql { };

  virtuoso6 = callPackage ../servers/sql/virtuoso/6.x.nix { };

  virtuoso7 = callPackage ../servers/sql/virtuoso/7.x.nix { };

  virtuoso = virtuoso6;

  xorg = recurseIntoAttrs (import ../servers/x11/xorg/default.nix {
    inherit fetchurl fetchgit fetchpatch stdenv pkgconfig intltool freetype fontconfig
      libxslt expat libdrm libpng zlib perl mesa_drivers
      dbus libuuid openssl gperf m4
      autoconf automake libtool xmlto asciidoc udev flex bison python mtdev pixman;
    mesa = mesa_noglu;
  } // {
    xf86videointel-testing = callPackage ../servers/x11/xorg/xf86-video-intel-testing.nix { };
  });

  xorgReplacements = callPackage ../servers/x11/xorg/replacements.nix { };

  xorgVideoUnichrome = callPackage ../servers/x11/xorg/unichrome/default.nix { };

  zabbix = recurseIntoAttrs (import ../servers/monitoring/zabbix {
    inherit fetchurl stdenv pkgconfig postgresql curl openssl zlib;
  });

  zabbix20 = callPackage ../servers/monitoring/zabbix/2.0.nix { };
  zabbix22 = callPackage ../servers/monitoring/zabbix/2.2.nix { };


  ### OS-SPECIFIC

  amdUcode = callPackage ../os-specific/linux/microcode/amd.nix { };

  autofs5 = callPackage ../os-specific/linux/autofs/autofs-v5.nix { };

  _915resolution = callPackage ../os-specific/linux/915resolution { };

  nfsUtils = callPackage ../os-specific/linux/nfs-utils { };

  alsaLib = callPackage ../os-specific/linux/alsa-lib { };

  alsaPlugins = callPackage ../os-specific/linux/alsa-plugins {
    jackaudio = null;
  };

  alsaPluginWrapper = callPackage ../os-specific/linux/alsa-plugins/wrapper.nix { };

  alsaUtils = callPackage ../os-specific/linux/alsa-utils { };
  alsaOss = callPackage ../os-specific/linux/alsa-oss { };

  microcode2ucode = callPackage ../os-specific/linux/microcode/converter.nix { };

  microcodeIntel = callPackage ../os-specific/linux/microcode/intel.nix { };

  apparmor = callPackage ../os-specific/linux/apparmor {
    inherit (perlPackages) LocaleGettext TermReadKey RpcXML;
    bison = bison2;
  };

  b43Firmware_5_1_138 = callPackage ../os-specific/linux/firmware/b43-firmware/5.1.138.nix { };

  b43FirmwareCutter = callPackage ../os-specific/linux/firmware/b43-firmware-cutter { };

  batctl = callPackage ../os-specific/linux/batman-adv/batctl.nix { };

  bluez4 = callPackage ../os-specific/linux/bluez {
    pygobject = pygobject3;
  };

  bluez5 = lowPrio (callPackage ../os-specific/linux/bluez/bluez5.nix { });

  bluez = bluez4;

  inherit (pythonPackages) bedup;

  bridge_utils = callPackage ../os-specific/linux/bridge-utils { };

  cifs_utils = callPackage ../os-specific/linux/cifs-utils { };

  conky = callPackage ../os-specific/linux/conky {
    mpdSupport   = config.conky.mpdSupport   or true;
    x11Support   = config.conky.x11Support   or false;
    xdamage      = config.conky.xdamage      or false;
    wireless     = config.conky.wireless     or false;
    luaSupport   = config.conky.luaSupport   or false;
    rss          = config.conky.rss          or false;
    weatherMetar = config.conky.weatherMetar or false;
    weatherXoap  = config.conky.weatherXoap  or false;
  };

  darwin = rec {
    cctools = forceNativeDrv (callPackage ../os-specific/darwin/cctools-port {
      cross = assert crossSystem != null; crossSystem;
      inherit maloader;
      xctoolchain = xcode.toolchain;
    });

    maloader = callPackage ../os-specific/darwin/maloader {
      inherit opencflite;
    };

    opencflite = callPackage ../os-specific/darwin/opencflite {};

    xcode = callPackage ../os-specific/darwin/xcode {};
  };

  devicemapper = lvm2;

  disk_indicator = callPackage ../os-specific/linux/disk-indicator { };

  directvnc = builderDefsPackage ../os-specific/linux/directvnc {
    inherit libjpeg pkgconfig zlib directfb;
    inherit (xlibs) xproto;
  };

  dstat = callPackage ../os-specific/linux/dstat {
    # pythonFull includes the "curses" standard library module, for pretty
    # dstat color output
    python = pythonFull;
  };

  libossp_uuid = callPackage ../development/libraries/libossp-uuid { };

  libuuid =
    if crossSystem != null && crossSystem.config == "i586-pc-gnu"
    then (utillinux // {
      crossDrv = lib.overrideDerivation utillinux.crossDrv (args: {
        # `libblkid' fails to build on GNU/Hurd.
        configureFlags = args.configureFlags
          + " --disable-libblkid --disable-mount --disable-libmount"
          + " --disable-fsck --enable-static --disable-partx";
        doCheck = false;
        CPPFLAGS =                    # ugly hack for ugly software!
          lib.concatStringsSep " "
            (map (v: "-D${v}=4096")
                 [ "PATH_MAX" "MAXPATHLEN" "MAXHOSTNAMELEN" ]);
      });
    })
    else if stdenv.isLinux
    then utillinux
    else null;

  eject = utillinux;

  gradm = callPackage ../os-specific/linux/gradm {
    flex = flex_2_5_35;
  };

  htop =
    if stdenv.isLinux then
      callPackage ../os-specific/linux/htop { }
    else if stdenv.isDarwin then
      callPackage ../os-specific/darwin/htop { }
    else null;

  # GNU/Hurd core packages.
  gnu = recurseIntoAttrs (callPackage ../os-specific/gnu {
    inherit platform crossSystem;
  });

  iputils = callPackage ../os-specific/linux/iputils {
    sp = spCompat;
    inherit (perlPackages) SGMLSpm;
  };

  libnl_3_2_19 = callPackage ../os-specific/linux/libnl/3.2.19.nix { };

  linuxConsoleTools = callPackage ../os-specific/linux/consoletools { };

  # -- Linux kernel expressions ------------------------------------------------

  linuxHeaders = linuxHeaders_3_7;

  linuxHeaders24Cross = forceNativeDrv (import ../os-specific/linux/kernel-headers/2.4.nix {
    inherit stdenv fetchurl perl;
    cross = assert crossSystem != null; crossSystem;
  });

  linuxHeaders26Cross = forceNativeDrv (import ../os-specific/linux/kernel-headers/2.6.32.nix {
    inherit stdenv fetchurl perl;
    cross = assert crossSystem != null; crossSystem;
  });

  linuxHeaders_3_7 = callPackage ../os-specific/linux/kernel-headers/3.7.nix { };

  linuxHeaders_3_14 = callPackage ../os-specific/linux/kernel-headers/3.14.nix { };

  # We can choose:
  linuxHeadersCrossChooser = ver : if ver == "2.4" then linuxHeaders24Cross
    else if ver == "2.6" then linuxHeaders26Cross
    else throw "Unknown linux kernel version";

  linuxHeadersCross = assert crossSystem != null;
    linuxHeadersCrossChooser crossSystem.platform.kernelMajor;

  kernelPatches = callPackage ../os-specific/linux/kernel/patches.nix { };

  linux_3_2 = makeOverridable (import ../os-specific/linux/kernel/linux-3.2.nix) {
    inherit fetchurl stdenv perl buildLinux;
    kernelPatches = [];
  };

  linux_3_2_xen = lowPrio (linux_3_2.override {
    extraConfig = ''
      XEN_DOM0 y
    '';
  });

  linux_3_4 = makeOverridable (import ../os-specific/linux/kernel/linux-3.4.nix) {
    inherit fetchurl stdenv perl buildLinux;
    kernelPatches = lib.optionals ((platform.kernelArch or null) == "mips")
      [ kernelPatches.mips_fpureg_emu
        kernelPatches.mips_fpu_sigill
      ];
  };

  linux_3_6_rpi = makeOverridable (import ../os-specific/linux/kernel/linux-rpi-3.6.nix) {
    inherit fetchurl stdenv perl buildLinux;
  };

  linux_3_10 = makeOverridable (import ../os-specific/linux/kernel/linux-3.10.nix) {
    inherit fetchurl stdenv perl buildLinux;
    kernelPatches = lib.optionals ((platform.kernelArch or null) == "mips")
      [ kernelPatches.mips_fpureg_emu
        kernelPatches.mips_fpu_sigill
        kernelPatches.mips_ext3_n32
      ];
  };

  linux_3_10_tuxonice = linux_3_10.override (attrs: {
    kernelPatches = attrs.kernelPatches ++ [
      kernelPatches.tuxonice_3_10
    ];
    extraConfig = ''
      TOI_CORE y
    '';
  });

  linux_3_12 = makeOverridable (import ../os-specific/linux/kernel/linux-3.12.nix) {
    inherit fetchurl stdenv perl buildLinux;
    kernelPatches = lib.optionals ((platform.kernelArch or null) == "mips")
      [ kernelPatches.mips_fpureg_emu
        kernelPatches.mips_fpu_sigill
        kernelPatches.mips_ext3_n32
      ];
  };

  linux_3_14 = makeOverridable (import ../os-specific/linux/kernel/linux-3.14.nix) {
    inherit fetchurl stdenv perl buildLinux;
    kernelPatches = lib.optionals ((platform.kernelArch or null) == "mips")
      [ kernelPatches.mips_fpureg_emu
        kernelPatches.mips_fpu_sigill
        kernelPatches.mips_ext3_n32
      ];
  };

  linux_3_15 = makeOverridable (import ../os-specific/linux/kernel/linux-3.15.nix) {
    inherit fetchurl stdenv perl buildLinux;
    kernelPatches = lib.optionals ((platform.kernelArch or null) == "mips")
      [ kernelPatches.mips_fpureg_emu
        kernelPatches.mips_fpu_sigill
        kernelPatches.mips_ext3_n32
      ];
  };

  linux_testing = makeOverridable (import ../os-specific/linux/kernel/linux-testing.nix) {
    inherit fetchurl stdenv perl buildLinux;
    kernelPatches = lib.optionals ((platform.kernelArch or null) == "mips")
      [ kernelPatches.mips_fpureg_emu
        kernelPatches.mips_fpu_sigill
        kernelPatches.mips_ext3_n32
      ];
  };

  /* grsec configuration

     We build several flavors of 'default' grsec kernels. These are
     built by default with Hydra. If the user selects a matching
     'default' flavor, then the pre-canned package set can be
     chosen. Typically, users will make very basic choices like
     'security' + 'server' or 'performance' + 'desktop' with
     virtualisation support. These will then be picked.

     Note: Xen guest kernels are included for e.g. NixOps deployments
     to EC2, where Xen is the Hypervisor.
  */

  grFlavors = import ../build-support/grsecurity/flavors.nix;

  mkGrsecurity = opts:
    (import ../build-support/grsecurity {
      grsecOptions = opts;
      inherit pkgs lib;
    });

  grKernel  = opts: (mkGrsecurity opts).grsecKernel;
  grPackage = opts: recurseIntoAttrs (mkGrsecurity opts).grsecPackage;

  # Stable kernels
  linux_grsec_stable_desktop    = grKernel grFlavors.linux_grsec_stable_desktop;
  linux_grsec_stable_server     = grKernel grFlavors.linux_grsec_stable_server;
  linux_grsec_stable_server_xen = grKernel grFlavors.linux_grsec_stable_server_xen;

  # Testing kernels
  linux_grsec_testing_desktop = grKernel grFlavors.linux_grsec_testing_desktop;
  linux_grsec_testing_server  = grKernel grFlavors.linux_grsec_testing_server;
  linux_grsec_testing_server_xen = grKernel grFlavors.linux_grsec_testing_server_xen;

  /* Linux kernel modules are inherently tied to a specific kernel.  So
     rather than provide specific instances of those packages for a
     specific kernel, we have a function that builds those packages
     for a specific kernel.  This function can then be called for
     whatever kernel you're using. */

  linuxPackagesFor = kernel: self: let callPackage = newScope self; in {
    inherit kernel;

    acpi_call = callPackage ../os-specific/linux/acpi-call {};

    batman_adv = callPackage ../os-specific/linux/batman-adv {};

    bbswitch = callPackage ../os-specific/linux/bbswitch {};

    ati_drivers_x11 = callPackage ../os-specific/linux/ati-drivers { };

    blcr = callPackage ../os-specific/linux/blcr { };

    cryptodev = callPackage ../os-specific/linux/cryptodev { };

    cpupower = callPackage ../os-specific/linux/cpupower { };

    e1000e = callPackage ../os-specific/linux/e1000e {};

    v4l2loopback = callPackage ../os-specific/linux/v4l2loopback { };

    frandom = callPackage ../os-specific/linux/frandom { };

    ktap = callPackage ../os-specific/linux/ktap { };

    lttngModules = callPackage ../os-specific/linux/lttng-modules { };

    broadcom_sta = callPackage ../os-specific/linux/broadcom-sta/default.nix { };

    nvidiabl = callPackage ../os-specific/linux/nvidiabl { };

    nvidia_x11 = callPackage ../os-specific/linux/nvidia-x11 { };

    nvidia_x11_legacy173 = callPackage ../os-specific/linux/nvidia-x11/legacy173.nix { };
    nvidia_x11_legacy304 = callPackage ../os-specific/linux/nvidia-x11/legacy304.nix { };

    openafsClient = callPackage ../servers/openafs-client { };

    openiscsi = callPackage ../os-specific/linux/open-iscsi { };

    wis_go7007 = callPackage ../os-specific/linux/wis-go7007 { };

    kernelHeaders = callPackage ../os-specific/linux/kernel-headers { };

    klibc = callPackage ../os-specific/linux/klibc { };

    klibcShrunk = lowPrio (callPackage ../os-specific/linux/klibc/shrunk.nix { });


    /* compiles but has to be integrated into the kernel somehow
       Let's have it uncommented and finish it..
    */
    ndiswrapper = callPackage ../os-specific/linux/ndiswrapper { };

    netatop = callPackage ../os-specific/linux/netatop { };

    perf = callPackage ../os-specific/linux/kernel/perf.nix { };

    psmouse_alps = callPackage ../os-specific/linux/psmouse-alps { };

    spl = callPackage ../os-specific/linux/spl { };
    spl_git = callPackage ../os-specific/linux/spl/git.nix { };

    sysdig = callPackage ../os-specific/linux/sysdig {};

    tp_smapi = callPackage ../os-specific/linux/tp_smapi { };

    v86d = callPackage ../os-specific/linux/v86d { };

    virtualbox = callPackage ../applications/virtualization/virtualbox {
      stdenv = stdenv_32bit;
      inherit (gnome) libIDL;
      enableExtensionPack = config.virtualbox.enableExtensionPack or false;
    };

    virtualboxGuestAdditions = callPackage ../applications/virtualization/virtualbox/guest-additions { };

    zfs = callPackage ../os-specific/linux/zfs { };
    zfs_git = callPackage ../os-specific/linux/zfs/git.nix { };
  };

  # The current default kernel / kernel modules.
  linux = linuxPackages.kernel;
  linuxPackages = linuxPackages_3_12;

  # Update this when adding the newest kernel major version!
  linux_latest = pkgs.linux_3_15;
  linuxPackages_latest = pkgs.linuxPackages_3_15;

  # Build the kernel modules for the some of the kernels.
  linuxPackages_3_2 = recurseIntoAttrs (linuxPackagesFor pkgs.linux_3_2 linuxPackages_3_2);
  linuxPackages_3_2_xen = linuxPackagesFor pkgs.linux_3_2_xen linuxPackages_3_2_xen;
  linuxPackages_3_4 = recurseIntoAttrs (linuxPackagesFor pkgs.linux_3_4 linuxPackages_3_4);
  linuxPackages_3_6_rpi = linuxPackagesFor pkgs.linux_3_6_rpi linuxPackages_3_6_rpi;
  linuxPackages_3_10 = recurseIntoAttrs (linuxPackagesFor pkgs.linux_3_10 linuxPackages_3_10);
  linuxPackages_3_10_tuxonice = linuxPackagesFor pkgs.linux_3_10_tuxonice linuxPackages_3_10_tuxonice;
  linuxPackages_3_12 = recurseIntoAttrs (linuxPackagesFor pkgs.linux_3_12 linuxPackages_3_12);
  linuxPackages_3_14 = recurseIntoAttrs (linuxPackagesFor pkgs.linux_3_14 linuxPackages_3_14);
  linuxPackages_3_15 = recurseIntoAttrs (linuxPackagesFor pkgs.linux_3_15 linuxPackages_3_15);
  linuxPackages_testing = recurseIntoAttrs (linuxPackagesFor pkgs.linux_testing linuxPackages_testing);

  # grsecurity flavors
  # Stable kernels
  linuxPackages_grsec_stable_desktop    = grPackage grFlavors.linux_grsec_stable_desktop;
  linuxPackages_grsec_stable_server     = grPackage grFlavors.linux_grsec_stable_server;
  linuxPackages_grsec_stable_server_xen = grPackage grFlavors.linux_grsec_stable_server_xen;

  # Testing kernels
  linuxPackages_grsec_testing_desktop = grPackage grFlavors.linux_grsec_testing_desktop;
  linuxPackages_grsec_testing_server  = grPackage grFlavors.linux_grsec_testing_server;
  linuxPackages_grsec_testing_server_xen = grPackage grFlavors.linux_grsec_testing_server_xen;

  # A function to build a manually-configured kernel
  linuxManualConfig = pkgs.buildLinux;
  buildLinux = import ../os-specific/linux/kernel/manual-config.nix {
    inherit (pkgs) stdenv runCommand nettools bc perl kmod writeTextFile ubootChooser;
  };

  lm_sensors = callPackage ../os-specific/linux/lm-sensors { };

  kvm = qemu_kvm;

  libcap_progs = callPackage ../os-specific/linux/libcap/progs.nix { };

  libcap_pam = callPackage ../os-specific/linux/libcap/pam.nix { };

  libcap_manpages = callPackage ../os-specific/linux/libcap/man.nix { };

  libcap_ng = callPackage ../os-specific/linux/libcap-ng { };

  module_init_tools = callPackage ../os-specific/linux/module-init-tools { };

  aggregateModules = modules:
    callPackage ../os-specific/linux/kmod/aggregator.nix {
      inherit modules;
    };

  multipath_tools = callPackage ../os-specific/linux/multipath-tools { };

  nettools = callPackage ../os-specific/linux/net-tools { };

  neverball = callPackage ../games/neverball {
    libpng = libpng15;
  };

  # pam_bioapi ( see http://www.thinkwiki.org/wiki/How_to_enable_the_fingerprint_reader )

  pam_console = callPackage ../os-specific/linux/pam_console {
    libtool = libtool_1_5;
  };

  pcmciaUtils = callPackage ../os-specific/linux/pcmciautils {
    firmware = config.pcmciaUtils.firmware or [];
    config = config.pcmciaUtils.config or null;
  };

  plymouth = callPackage ../os-specific/linux/plymouth {
    automake = automake113x;
  };

  pmutils = callPackage ../os-specific/linux/pm-utils { };

  procps = procps-ng;

  procps-old = lowPrio (callPackage ../os-specific/linux/procps { });

  watch = callPackage ../os-specific/linux/procps/watch.nix { };

  qemu_kvm = lowPrio (qemu.override { x86Only = true; });

  firmwareLinuxNonfree = callPackage ../os-specific/linux/firmware/firmware-linux-nonfree { };

  raspberrypifw = callPackage ../os-specific/linux/firmware/raspberrypi {};

  rfkill_udev = callPackage ../os-specific/linux/rfkill/udev.nix { };

  statifier = builderDefsPackage (import ../os-specific/linux/statifier) { };

  sysdig = callPackage ../os-specific/linux/sysdig {
    kernel = null;
  }; # pkgs.sysdig is a client, for a driver look at linuxPackagesFor

  sysprof = callPackage ../development/tools/profiling/sysprof {
    inherit (gnome) libglade;
  };

  # Provided with sysfsutils.
  libsysfs = sysfsutils;
  systool = sysfsutils;

  systemd = callPackage ../os-specific/linux/systemd {
    linuxHeaders = linuxHeaders_3_14;
  };

  systemtap = callPackage ../development/tools/profiling/systemtap {
    inherit (gnome) libglademm;
  };

  # In nixos, you can set systemd.package = pkgs.systemd_with_lvm2 to get
  # LVM2 working in systemd.
  systemd_with_lvm2 = pkgs.lib.overrideDerivation pkgs.systemd (p: {
      name = p.name + "-with-lvm2";
      postInstall = p.postInstall + ''
        cp "${pkgs.lvm2}/lib/systemd/system-generators/"* $out/lib/systemd/system-generators
      '';
  });

  sysvtools = callPackage ../os-specific/linux/sysvinit {
    withoutInitTools = true;
  };

  # FIXME: `tcp-wrapper' is actually not OS-specific.
  tcp_wrappers = callPackage ../os-specific/linux/tcp-wrappers { };

  trackballs = callPackage ../games/trackballs {
    debug = false;
    guile = guile_1_8;
  };

  ubootChooser = name : if name == "upstream" then ubootUpstream
    else if name == "sheevaplug" then ubootSheevaplug
    else if name == "guruplug" then ubootGuruplug
    else if name == "nanonote" then ubootNanonote
    else throw "Unknown uboot";

  ubootUpstream = callPackage ../misc/uboot { };

  ubootSheevaplug = callPackage ../misc/uboot/sheevaplug.nix { };

  ubootNanonote = callPackage ../misc/uboot/nanonote.nix { };

  ubootGuruplug = callPackage ../misc/uboot/guruplug.nix { };

  uclibcCross = lowPrio (callPackage ../os-specific/linux/uclibc {
    inherit fetchurl stdenv libiconv;
    linuxHeaders = linuxHeadersCross;
    gccCross = gccCrossStageStatic;
    cross = assert crossSystem != null; crossSystem;
  });

  udev145 = callPackage ../os-specific/linux/udev/145.nix { };
  udev = pkgs.systemd;

  udisks1 = callPackage ../os-specific/linux/udisks/1-default.nix { };
  udisks2 = callPackage ../os-specific/linux/udisks/2-default.nix { };
  udisks = udisks1;

  udisks_glue = callPackage ../os-specific/linux/udisks-glue { };

  upower_99 = callPackage ../os-specific/linux/upower/0.99.nix { };

  utillinux = lowPrio (callPackage ../os-specific/linux/util-linux {
    ncurses = null;
    perl = null;
  });

  utillinuxCurses = utillinux.override {
    inherit ncurses perl;
  };

  v4l_utils = callPackage ../os-specific/linux/v4l-utils {
    withQt4 = true;
  };

  windows = rec {
    cygwinSetup = callPackage ../os-specific/windows/cygwin-setup { };

    jom = callPackage ../os-specific/windows/jom { };

    w32api = callPackage ../os-specific/windows/w32api {
      gccCross = gccCrossStageStatic;
      binutilsCross = binutilsCross;
    };

    w32api_headers = w32api.override {
      onlyHeaders = true;
    };

    mingw_runtime = callPackage ../os-specific/windows/mingwrt {
      gccCross = gccCrossMingw2;
      binutilsCross = binutilsCross;
    };

    mingw_runtime_headers = mingw_runtime.override {
      onlyHeaders = true;
    };

    mingw_headers1 = buildEnv {
      name = "mingw-headers-1";
      paths = [ w32api_headers mingw_runtime_headers ];
    };

    mingw_headers2 = buildEnv {
      name = "mingw-headers-2";
      paths = [ w32api mingw_runtime_headers ];
    };

    mingw_headers3 = buildEnv {
      name = "mingw-headers-3";
      paths = [ w32api mingw_runtime ];
    };

    mingw_w64 = callPackage ../os-specific/windows/mingw-w64 {
      gccCross = gccCrossStageStatic;
      binutilsCross = binutilsCross;
    };

    mingw_w64_headers = callPackage ../os-specific/windows/mingw-w64 {
      onlyHeaders = true;
    };

    mingw_w64_pthreads = callPackage ../os-specific/windows/mingw-w64 {
      onlyPthreads = true;
    };

    pthreads = callPackage ../os-specific/windows/pthread-w32 {
      mingw_headers = mingw_headers3;
    };

    wxMSW = callPackage ../os-specific/windows/wxMSW-2.8 { };
  };

  wesnoth = callPackage ../games/wesnoth {
    lua = lua5;
  };

  wirelesstools = callPackage ../os-specific/linux/wireless-tools { };

  wpa_supplicant_gui = callPackage ../os-specific/linux/wpa_supplicant/gui.nix { };

  xf86_input_mtrack = callPackage ../os-specific/linux/xf86-input-mtrack {
    inherit (xorg) utilmacros xproto inputproto xorgserver;
  };

  xf86_input_multitouch =
    callPackage ../os-specific/linux/xf86-input-multitouch { };

  xf86_input_wacom = callPackage ../os-specific/linux/xf86-input-wacom { };

  xf86_video_nested = callPackage ../os-specific/linux/xf86-video-nested {
    inherit (xorg) fontsproto renderproto utilmacros xorgserver;
  };

  xf86_video_nouveau = xorg.xf86videonouveau;

  xmoto = builderDefsPackage (import ../games/xmoto) {
    inherit chipmunk sqlite curl zlib bzip2 libjpeg libpng
      freeglut mesa SDL SDL_mixer SDL_image SDL_net SDL_ttf
      lua5 ode libxdg_basedir libxml2;
  };

  xorg_sys_opengl = callPackage ../os-specific/linux/opengl/xorg-sys { };

  zd1211fw = callPackage ../os-specific/linux/firmware/zd1211 { };


  ### DATA

  anonymousPro = callPackage ../data/fonts/anonymous-pro {};

  arkpandora_ttf = builderDefsPackage (import ../data/fonts/arkpandora) { };

  bakoma_ttf = callPackage ../data/fonts/bakoma-ttf { };

  cantarell_fonts = callPackage ../data/fonts/cantarell-fonts { };

  wrapFonts = paths : ((import ../data/fonts/fontWrap) {
    inherit fetchurl stdenv builderDefs paths;
    inherit (xorg) mkfontdir mkfontscale;
  });

  cm_unicode = callPackage ../data/fonts/cm-unicode {};

  dejavu_fonts = callPackage ../data/fonts/dejavu-fonts {
    inherit (perlPackages) FontTTF;
  };

  docbook5 = callPackage ../data/sgml+xml/schemas/docbook-5.0 { };

  docbook_sgml_dtd_31 = callPackage ../data/sgml+xml/schemas/sgml-dtd/docbook/3.1.nix { };

  docbook_sgml_dtd_41 = callPackage ../data/sgml+xml/schemas/sgml-dtd/docbook/4.1.nix { };

  docbook_xml_dtd_412 = callPackage ../data/sgml+xml/schemas/xml-dtd/docbook/4.1.2.nix { };

  docbook_xml_dtd_42 = callPackage ../data/sgml+xml/schemas/xml-dtd/docbook/4.2.nix { };

  docbook_xml_dtd_43 = callPackage ../data/sgml+xml/schemas/xml-dtd/docbook/4.3.nix { };

  docbook_xml_dtd_45 = callPackage ../data/sgml+xml/schemas/xml-dtd/docbook/4.5.nix { };

  docbook_xml_ebnf_dtd = callPackage ../data/sgml+xml/schemas/xml-dtd/docbook-ebnf { };

  docbook_xml_xslt = docbook_xsl;

  docbook_xsl = callPackage ../data/sgml+xml/stylesheets/xslt/docbook-xsl { };

  docbook5_xsl = docbook_xsl_ns;

  docbook_xsl_ns = callPackage ../data/sgml+xml/stylesheets/xslt/docbook-xsl-ns { };

  dosemu_fonts = callPackage ../data/fonts/dosemu-fonts { };

  freefont_ttf = callPackage ../data/fonts/freefont-ttf { };

  gnome_user_docs = callPackage ../data/documentation/gnome-user-docs { };

  inherit (gnome3) gsettings_desktop_schemas;

  hicolor_icon_theme = callPackage ../data/icons/hicolor-icon-theme { };

  liberation_ttf = callPackage ../data/fonts/redhat-liberation-fonts { };

  libertine = builderDefsPackage (import ../data/fonts/libertine) {
    inherit fetchurl fontforge lib;
  };

  lmmath = callPackage ../data/fonts/lmodern/lmmath.nix {};

  manpages = callPackage ../data/documentation/man-pages { };

  mobile_broadband_provider_info = callPackage ../data/misc/mobile-broadband-provider-info { };

  mph_2b_damase = callPackage ../data/fonts/mph-2b-damase { };

  posix_man_pages = callPackage ../data/documentation/man-pages-posix { };

  pthreadmanpages = callPackage ../data/documentation/pthread-man-pages { };

  shared_mime_info = callPackage ../data/misc/shared-mime-info { };

  shared_desktop_ontologies = callPackage ../data/misc/shared-desktop-ontologies { };

  stdmanpages = callPackage ../data/documentation/std-man-pages { };

  iana_etc = callPackage ../data/misc/iana-etc { };

  poppler_data = callPackage ../data/misc/poppler-data { };

  r3rs = callPackage ../data/documentation/rnrs/r3rs.nix { };

  r4rs = callPackage ../data/documentation/rnrs/r4rs.nix { };

  r5rs = callPackage ../data/documentation/rnrs/r5rs.nix { };

  sourceCodePro = callPackage ../data/fonts/source-code-pro {};

  themes = name: import (../data/misc/themes + ("/" + name + ".nix")) {
    inherit fetchurl;
  };

  tempora_lgc = callPackage ../data/fonts/tempora-lgc { };

  terminus_font = callPackage ../data/fonts/terminus-font { };

  ttf_bitstream_vera = callPackage ../data/fonts/ttf-bitstream-vera { };

  ubuntu_font_family = callPackage ../data/fonts/ubuntu-font-family { };

  ucsFonts = callPackage ../data/fonts/ucs-fonts { };

  vistafonts = callPackage ../data/fonts/vista-fonts { };

  wqy_microhei = callPackage ../data/fonts/wqy-microhei { };

  wqy_zenhei = callPackage ../data/fonts/wqy-zenhei { };

  xkeyboard_config = xorg.xkeyboardconfig;


  ### APPLICATIONS

  aangifte2006 = callPackage_i686 ../applications/taxes/aangifte-2006 { };

  aangifte2007 = callPackage_i686 ../applications/taxes/aangifte-2007 { };

  aangifte2008 = callPackage_i686 ../applications/taxes/aangifte-2008 { };

  aangifte2009 = callPackage_i686 ../applications/taxes/aangifte-2009 { };

  aangifte2010 = callPackage_i686 ../applications/taxes/aangifte-2010 { };

  aangifte2011 = callPackage_i686 ../applications/taxes/aangifte-2011 { };

  aangifte2012 = callPackage_i686 ../applications/taxes/aangifte-2012 { };

  aangifte2013 = callPackage_i686 ../applications/taxes/aangifte-2013 { };

  abcde = callPackage ../applications/audio/abcde {
    inherit (perlPackages) DigestSHA MusicBrainz MusicBrainzDiscID;
    libcdio = libcdio082;
  };

  abiword = callPackage ../applications/office/abiword {
    inherit (gnome) libglade libgnomecanvas;
  };

  adobe-reader = callPackage_i686 ../applications/misc/adobe-reader { };

  ardour = ardour3;

  ardour3 =  lowPrio (callPackage ../applications/audio/ardour {
    inherit (gnome) libgnomecanvas libgnomecanvasmm;
  });

  atom = callPackage ../applications/editors/atom {
    gconf = gnome.GConf;
  };

  aseprite = callPackage ../applications/editors/aseprite {
    giflib = giflib_4_1;
  };

  audacity = callPackage ../applications/audio/audacity {
    ffmpeg = ffmpeg_0_10;
  };

  aumix = callPackage ../applications/audio/aumix {
    gtkGUI = false;
  };

  avogadro = callPackage ../applications/science/chemistry/avogadro {
    eigen = eigen2;
  };

  awesome-3-4 = callPackage ../applications/window-managers/awesome/3.4.nix {
    lua = lua5;
    cairo = cairo.override { xcbSupport = true; };
  };
  awesome-3-5 = callPackage ../applications/window-managers/awesome {
    lua   = lua5_1;
    cairo = cairo.override { xcbSupport = true; };
  };
  awesome = awesome-3-5;

  inherit (gnome3) baobab;

  baresip = callPackage ../applications/networking/instant-messengers/baresip {
    ffmpeg = ffmpeg_1;
  };

  bazaarTools = builderDefsPackage (import ../applications/version-management/bazaar/tools.nix) {
    inherit bazaar;
  };

  beast = callPackage ../applications/audio/beast {
    inherit (gnome) libgnomecanvas libart_lgpl;
    guile = guile_1_8;
  };

  bitlbee = callPackage ../applications/networking/instant-messengers/bitlbee {
    gnutls = gnutls;
    libotr = libotr_3_2;
  };

  blender = callPackage  ../applications/misc/blender {
    python = python34;
  };

  calf = callPackage ../applications/audio/calf {
      inherit (gnome) libglade;
  };

  carrier = builderDefsPackage (import ../applications/networking/instant-messengers/carrier/2.5.0.nix) {
    inherit fetchurl stdenv pkgconfig perl perlXMLParser libxml2 openssl nss
      gtkspell aspell gettext ncurses avahi dbus dbus_glib python
      libtool automake autoconf gstreamer;
    inherit gtk glib;
    inherit (gnome) startupnotification GConf ;
    inherit (xlibs) libXScrnSaver scrnsaverproto libX11 xproto kbproto;
  };
  funpidgin = carrier;

  cddiscid = callPackage ../applications/audio/cd-discid { };

  cdparanoia = cdparanoiaIII;

  cdparanoiaIII = callPackage ../applications/audio/cdparanoia { };

  cgminer = callPackage ../applications/misc/cgminer {
    amdappsdk = amdappsdk28;
  };

  chromium = lowPrio (callPackage ../applications/networking/browsers/chromium {
    channel = "stable";
    pulseSupport = config.pulseaudio or true;
    enablePepperFlash = config.chromium.enablePepperFlash or false;
    enablePepperPDF = config.chromium.enablePepperPDF or false;
  });

  chromiumBeta = lowPrio (chromium.override { channel = "beta"; });
  chromiumBetaWrapper = lowPrio (wrapChromium chromiumBeta);

  chromiumDev = lowPrio (chromium.override { channel = "dev"; });
  chromiumDevWrapper = lowPrio (wrapChromium chromiumDev);

  chromiumWrapper = wrapChromium chromium;

  compiz = callPackage ../applications/window-managers/compiz {
    inherit (gnome) GConf ORBit2 metacity;
    boost = boost149; # https://bugs.launchpad.net/compiz/+bug/1131864
  };

  coriander = callPackage ../applications/video/coriander {
    inherit (gnome) libgnomeui GConf;
  };

  cinepaint = callPackage ../applications/graphics/cinepaint {
    fltk = fltk13;
    libpng = libpng12;
  };

  codeblocksFull = callPackage ../applications/editors/codeblocks { contribPlugins = true; };

  codeville = builderDefsPackage (import ../applications/version-management/codeville/0.8.0.nix) {
    inherit makeWrapper;
    python = pythonFull;
  };

  conkerorWrapper = wrapFirefox {
    browser = conkeror;
    browserName = "conkeror";
    desktopName = "Conkeror";
  };

  cuneiform = builderDefsPackage (import ../tools/graphics/cuneiform) {
    inherit cmake patchelf;
    imagemagick = imagemagick;
  };

  darcs = haskellPackages_ghc763.darcs.override {
    # A variant of the Darcs derivation that containts only the executable and
    # thus has no dependencies on other Haskell packages. We have to use the older
    # GHC 7.6.3 package set because darcs won't compile with 7.8.x.
    cabal = haskellPackages_ghc763.cabal.override {
      extension = self : super : {
        isLibrary = false;
        configureFlags = "-f-library " + super.configureFlags or "";
      };
    };
  };

  darktable = callPackage ../applications/graphics/darktable {
    inherit (gnome) GConf libglade;
  };

  dd-agent = callPackage ../tools/networking/dd-agent { inherit (pythonPackages) tornado; };

  dia = callPackage ../applications/graphics/dia {
    inherit (pkgs.gnome) libart_lgpl libgnomeui;
  };

  djview4 = pkgs.djview;

  dmenu = callPackage ../applications/misc/dmenu {
    enableXft = config.dmenu.enableXft or false;
  };

  dmtx = builderDefsPackage (import ../tools/graphics/dmtx) {
    inherit libpng libtiff libjpeg imagemagick librsvg
      pkgconfig bzip2 zlib libtool freetype fontconfig
      ghostscript jasper xz;
    inherit (xlibs) libX11;
  };

  dvb_apps  = callPackage ../applications/video/dvb-apps { };

  dwb = callPackage ../applications/networking/browsers/dwb { dconf = gnome3.dconf; };

  dwbWrapper = wrapFirefox
    { browser = dwb; browserName = "dwb"; desktopName = "dwb";
    };

  dwm = callPackage ../applications/window-managers/dwm {
    patches = config.dwm.patches or [];
  };

  eclipses = recurseIntoAttrs (callPackage ../applications/editors/eclipse { });

  emacs = emacs24;

  emacs24 = callPackage ../applications/editors/emacs-24 {
    # use override to enable additional features
    libXaw = xlibs.libXaw;
    Xaw3d = null;
    gconf = null;
    librsvg = null;
    alsaLib = null;
    imagemagick = null;

    # resolve unrecognized section __static_data in __DATA segment
    stdenv = if stdenv.isDarwin
      then clangStdenv
      else stdenv;
  };

  emacs24-nox = lowPrio (appendToName "nox" (emacs24.override {
    withX = false;
  }));

  emacs24Macport = lowPrio (callPackage ../applications/editors/emacs-24/macport.nix {
    # resolve unrecognised flag '-fconstant-cfstrings' errors
    stdenv = if stdenv.isDarwin
      then clangStdenv
      else stdenv;
  });

  emacsPackages = emacs: self: let callPackage = newScope self; in rec {
    inherit emacs;

    autoComplete = callPackage ../applications/editors/emacs-modes/auto-complete { };

    bbdb = callPackage ../applications/editors/emacs-modes/bbdb { };

    cedet = callPackage ../applications/editors/emacs-modes/cedet { };

    calfw = callPackage ../applications/editors/emacs-modes/calfw { };

    coffee = callPackage ../applications/editors/emacs-modes/coffee { };

    colorTheme = callPackage ../applications/editors/emacs-modes/color-theme { };

    cryptol = callPackage ../applications/editors/emacs-modes/cryptol { };

    cua = callPackage ../applications/editors/emacs-modes/cua { };

    darcsum = callPackage ../applications/editors/emacs-modes/darcsum { };

    # ecb = callPackage ../applications/editors/emacs-modes/ecb { };

    jabber = callPackage ../applications/editors/emacs-modes/jabber { };

    emacsClangCompleteAsync = callPackage ../applications/editors/emacs-modes/emacs-clang-complete-async { };

    emacsSessionManagement = callPackage ../applications/editors/emacs-modes/session-management-for-emacs { };

    emacsw3m = callPackage ../applications/editors/emacs-modes/emacs-w3m { };

    emms = callPackage ../applications/editors/emacs-modes/emms { };

    ess = callPackage ../applications/editors/emacs-modes/ess { };

    flymakeCursor = callPackage ../applications/editors/emacs-modes/flymake-cursor { };

    gh = callPackage ../applications/editors/emacs-modes/gh { };

    graphvizDot = callPackage ../applications/editors/emacs-modes/graphviz-dot { };

    gist = callPackage ../applications/editors/emacs-modes/gist { };

    idris = callPackage ../applications/editors/emacs-modes/idris { };

    jade = callPackage ../applications/editors/emacs-modes/jade { };

    jdee = callPackage ../applications/editors/emacs-modes/jdee {
      # Requires Emacs 23, for `avl-tree'.
    };

    js2 = callPackage ../applications/editors/emacs-modes/js2 { };

    stratego = callPackage ../applications/editors/emacs-modes/stratego { };

    haskellMode = callPackage ../applications/editors/emacs-modes/haskell { };

    ocamlMode = callPackage ../applications/editors/emacs-modes/ocaml { };

    structuredHaskellMode = callPackage ../applications/editors/emacs-modes/structured-haskell-mode {
      inherit (haskellPackages) cabal haskellSrcExts;
    };

    tuaregMode = callPackage ../applications/editors/emacs-modes/tuareg { };

    hol_light_mode = callPackage ../applications/editors/emacs-modes/hol_light { };

    htmlize = callPackage ../applications/editors/emacs-modes/htmlize { };

    logito = callPackage ../applications/editors/emacs-modes/logito { };

    loremIpsum = callPackage ../applications/editors/emacs-modes/lorem-ipsum { };

    magit = callPackage ../applications/editors/emacs-modes/magit { };

    maudeMode = callPackage ../applications/editors/emacs-modes/maude { };

    metaweblog = callPackage ../applications/editors/emacs-modes/metaweblog { };

    notmuch = lowPrio (callPackage ../applications/networking/mailreaders/notmuch { });

    offlineimap = callPackage ../applications/editors/emacs-modes/offlineimap {};

    # This is usually a newer version of Org-Mode than that found in GNU Emacs, so
    # we want it to have higher precedence.
    org = hiPrio (callPackage ../applications/editors/emacs-modes/org { });

    org2blog = callPackage ../applications/editors/emacs-modes/org2blog { };

    pcache = callPackage ../applications/editors/emacs-modes/pcache { };

    phpMode = callPackage ../applications/editors/emacs-modes/php { };

    prologMode = callPackage ../applications/editors/emacs-modes/prolog { };

    proofgeneral_4_2 = callPackage ../applications/editors/emacs-modes/proofgeneral/4.2.nix {
      texinfo = texinfo4 ;
      texLive = pkgs.texLiveAggregationFun {
        paths = [ pkgs.texLive pkgs.texLiveCMSuper ];
      };
    };
    proofgeneral_4_3_pre = callPackage ../applications/editors/emacs-modes/proofgeneral/4.3pre.nix {
      texinfo = texinfo4 ;
      texLive = pkgs.texLiveAggregationFun {
        paths = [ pkgs.texLive pkgs.texLiveCMSuper ];
      };
    };
    proofgeneral = self.proofgeneral_4_2;

    quack = callPackage ../applications/editors/emacs-modes/quack { };

    rectMark = callPackage ../applications/editors/emacs-modes/rect-mark { };

    remember = callPackage ../applications/editors/emacs-modes/remember { };

    rudel = callPackage ../applications/editors/emacs-modes/rudel { };

    sbtMode = callPackage ../applications/editors/emacs-modes/sbt-mode { };

    scalaMode1 = callPackage ../applications/editors/emacs-modes/scala-mode/v1.nix { };
    scalaMode2 = callPackage ../applications/editors/emacs-modes/scala-mode/v2.nix { };

    sunriseCommander = callPackage ../applications/editors/emacs-modes/sunrise-commander { };

    writeGood = callPackage ../applications/editors/emacs-modes/writegood { };

    xmlRpc = callPackage ../applications/editors/emacs-modes/xml-rpc { };
  };

  emacs24Packages = recurseIntoAttrs (emacsPackages emacs24 pkgs.emacs24Packages);

  inherit (gnome3) empathy;

  inherit (gnome3) epiphany;

  espeakedit = callPackage ../applications/audio/espeak/edit.nix { };

  etherape = callPackage ../applications/networking/sniffers/etherape {
    inherit (gnome) gnomedocutils libgnome libglade libgnomeui scrollkeeper;
  };

  keepassx2 = callPackage ../applications/misc/keepassx/2.0.nix { };

  inherit (gnome3) evince;
  evolution_data_server = gnome3.evolution_data_server;

  exrdisplay = callPackage ../applications/graphics/exrdisplay {
    fltk = fltk20;
  };

  fetchmail = import ../applications/misc/fetchmail {
    inherit stdenv fetchurl openssl;
  };

  gnuradio = callPackage ../applications/misc/gnuradio {
    inherit (pythonPackages) lxml numpy scipy matplotlib pyopengl;
    fftw = fftwFloat;
  };

  grass = import ../applications/misc/grass {
    inherit (xlibs) libXmu libXext libXp libX11 libXt libSM libICE libXpm
      libXaw libXrender;
    inherit config composableDerivation stdenv fetchurl
      lib flex bison cairo fontconfig
      gdal zlib ncurses gdbm proj pkgconfig swig
      blas liblapack libjpeg libpng mysql unixODBC mesa postgresql python
      readline sqlite tcl tk libtiff freetype makeWrapper wxGTK;
    fftw = fftwSinglePrec;
    ffmpeg = ffmpeg_0_10;
    motif = lesstif;
    opendwg = libdwg;
    wxPython = wxPython28;
  };

  grip = callPackage ../applications/misc/grip {
    inherit (gnome) libgnome libgnomeui vte;
  };

  gtimelog = pythonPackages.gtimelog;

  inherit (gnome3) gucharmap;

  guitarix = callPackage ../applications/audio/guitarix {
    fftw = fftwSinglePrec;
  };

  firefox = pkgs.firefoxPkgs.firefox;

  firefox36Pkgs = callPackage ../applications/networking/browsers/firefox/3.6.nix {
    inherit (gnome) libIDL;
  };

  firefox36Wrapper = wrapFirefox { browser = firefox36Pkgs.firefox; };

  firefox13Pkgs = callPackage ../applications/networking/browsers/firefox/13.0.nix {
    inherit (gnome) libIDL;
  };

  firefox13Wrapper = wrapFirefox { browser = firefox13Pkgs.firefox; };

  firefoxPkgs = callPackage ../applications/networking/browsers/firefox {
    inherit (gnome) libIDL;
    inherit (pythonPackages) pysqlite;
    libpng = libpng.override { apngSupport = true; };
  };

  firefoxWrapper = wrapFirefox { browser = firefoxPkgs.firefox; };

  firefox-bin = callPackage ../applications/networking/browsers/firefox-bin {
    gconf = pkgs.gnome.GConf;
    inherit (pkgs.gnome) libgnome libgnomeui;
    inherit (pkgs.xlibs) libX11 libXScrnSaver libXext
      libXinerama libXrender libXt;
  };

  flashplayer = callPackage ../applications/networking/browsers/mozilla-plugins/flashplayer-11 {
    debug = config.flashplayer.debug or false;
    # !!! Fix the dependency on two different builds of nss.
  };

  freecad = callPackage ../applications/graphics/freecad {
    opencascade = opencascade_6_5;
    inherit (pythonPackages) matplotlib pycollada;
  };

  freemind = callPackage ../applications/misc/freemind {
    jdk = jdk;
    jre = jdk;
  };

  xlsfonts = callPackage ../applications/misc/xlsfonts { };

  freerdp = callPackage ../applications/networking/remote/freerdp {
    ffmpeg = ffmpeg_1;
  };

  freerdpUnstable = callPackage ../applications/networking/remote/freerdp/unstable.nix { };

  fspot = callPackage ../applications/graphics/f-spot {
    inherit (gnome) libgnome libgnomeui;
    gtksharp = gtksharp1;
  };

  gimp_2_8 = callPackage ../applications/graphics/gimp/2.8.nix {
    inherit (gnome) libart_lgpl;
    webkit = null;
    lcms = lcms2;
    wrapPython = pythonPackages.wrapPython;
  };

  gimp = gimp_2_8;

  gimpPlugins = recurseIntoAttrs (import ../applications/graphics/gimp/plugins {
    inherit pkgs gimp;
  });

  gitAndTools = recurseIntoAttrs (import ../applications/version-management/git-and-tools {
    inherit pkgs;
  });
  git = gitAndTools.git;
  gitFull = gitAndTools.gitFull;
  gitSVN = gitAndTools.gitSVN;

  gitRepo = callPackage ../applications/version-management/git-repo {
    python = python27;
  };

  inherit (gnome3) gitg;

  giv = callPackage ../applications/graphics/giv {
    pcre = pcre.override { unicodeSupport = true; };
  };

  gnucash = callPackage ../applications/office/gnucash {
    inherit (gnome2) libgnomeui libgtkhtml gtkhtml libbonoboui libgnomeprint libglade libart_lgpl;
    gconf = gnome2.GConf;
    guile = guile_1_8;
    slibGuile = slibGuile.override { scheme = guile_1_8; };
    goffice = goffice_0_8;
  };

  goffice_0_8 = callPackage ../desktops/gnome-3/3.10/misc/goffice/0.8.nix {
    inherit (gnome2) libglade libgnomeui;
    gconf = gnome2.GConf;
    libart = gnome2.libart_lgpl;
  }; # latest version: gnome3.goffice

  ideas = recurseIntoAttrs (callPackage ../applications/editors/idea { });

  libquvi = callPackage ../applications/video/quvi/library.nix { };

  quvi = callPackage ../applications/video/quvi/tool.nix { };

  quvi_scripts = callPackage ../applications/video/quvi/scripts.nix { };

  gnash = callPackage ../applications/video/gnash {
    xulrunner = firefoxPkgs.xulrunner;
    inherit (gnome) gtkglext;
  };

  gnome_mplayer = callPackage ../applications/video/gnome-mplayer {
    inherit (gnome) GConf;
  };

  gnumeric = callPackage ../applications/office/gnumeric {
    inherit (gnome3) goffice gnome_icon_theme;
  };

  gnunet = callPackage ../applications/networking/p2p/gnunet {
    libgcrypt = libgcrypt_1_6;
  };

  gnunet_svn = lowPrio (callPackage ../applications/networking/p2p/gnunet/svn.nix {
    libgcrypt = libgcrypt_1_6;
  });

  gobby5 = callPackage ../applications/editors/gobby {
    inherit (gnome) gtksourceview;
  };

  gphoto2fs = builderDefsPackage ../applications/misc/gphoto2/gphotofs.nix {
    inherit libgphoto2 fuse pkgconfig glib libtool;
  };

  graphicsmagick_q16 = callPackage ../applications/graphics/graphicsmagick { quantumdepth = 16; };

  graphicsmagick137 = callPackage ../applications/graphics/graphicsmagick/1.3.7.nix {
    libpng = libpng12;
  };

  gtkpod = callPackage ../applications/audio/gtkpod {
    inherit (gnome) libglade;
  };

  jbidwatcher = callPackage ../applications/misc/jbidwatcher {
    java = if stdenv.isLinux then jre else jdk;
  };

  qrdecode = builderDefsPackage (import ../tools/graphics/qrdecode) {
    libpng = libpng12;
    opencv = opencv_2_1;
  };

  gecko_mediaplayer = callPackage ../applications/networking/browsers/mozilla-plugins/gecko-mediaplayer {
    inherit (gnome) GConf;
    browser = firefox;
  };

  gmtk = callPackage ../applications/networking/browsers/mozilla-plugins/gmtk {
    inherit (gnome) GConf;
  };

  googleearth = callPackage_i686 ../applications/misc/googleearth { };

  google_talk_plugin = callPackage ../applications/networking/browsers/mozilla-plugins/google-talk-plugin {
    libpng = libpng12;
  };

  gosmore = builderDefsPackage ../applications/misc/gosmore {
    inherit fetchsvn curl pkgconfig libxml2 gtk;
  };

  hello = callPackage ../applications/misc/hello/ex-2 { };

  htmldoc = callPackage ../applications/misc/htmldoc {
    fltk = fltk13;
  };

  i3lock = callPackage ../applications/window-managers/i3/lock.nix {
    inherit (xorg) libxkbfile;
    cairo = cairo.override { xcbSupport = true; };
  };

  i3status = callPackage ../applications/window-managers/i3/status.nix { };

  icecat3 = lowPrio (callPackage ../applications/networking/browsers/icecat-3 {
    inherit (gnome) libIDL libgnomeui gnome_vfs;
    inherit (xlibs) pixman;
    inherit (pythonPackages) ply;
  });

  icecatXulrunner3 = lowPrio (callPackage ../applications/networking/browsers/icecat-3 {
    application = "xulrunner";
    inherit (gnome) libIDL libgnomeui gnome_vfs;
    inherit (xlibs) pixman;
    inherit (pythonPackages) ply;
  });

  icecat3Xul =
    (symlinkJoin "icecat-with-xulrunner-${icecat3.version}"
       [ icecat3 icecatXulrunner3 ])
    // { inherit (icecat3) gtk isFirefox3Like meta; };

  icecat3Wrapper = wrapFirefox { browser = icecat3Xul; browserName = "icecat"; desktopName = "IceCat"; };

  ikiwiki = callPackage ../applications/misc/ikiwiki {
    inherit (perlPackages) TextMarkdown URI HTMLParser HTMLScrubber
      HTMLTemplate TimeDate CGISession DBFile CGIFormBuilder LocaleGettext
      RpcXML XMLSimple PerlMagick YAML YAMLLibYAML HTMLTree Filechdir
      AuthenPassphrase NetOpenIDConsumer LWPxParanoidAgent CryptSSLeay;
  };

  imagemagick = callPackage ../applications/graphics/ImageMagick {
    tetex = null;
    librsvg = null;
  };

  imagemagickBig = lowPrio (callPackage ../applications/graphics/ImageMagick { });

  # Impressive, formerly known as "KeyJNote".
  impressive = callPackage ../applications/office/impressive {
    # XXX These are the PyOpenGL dependencies, which we need here.
    inherit (pythonPackages) pyopengl;
  };

  inferno = callPackage_i686 ../applications/inferno { };

  inkscape = callPackage ../applications/graphics/inkscape {
    inherit (pythonPackages) lxml;
    lcms = lcms2;
  };

  ion3 = callPackage ../applications/window-managers/ion-3 {
    lua = lua5;
  };

  irssi = callPackage ../applications/networking/irc/irssi {
    # compile with gccApple on darwin to support the -no-cpp-precompile flag
    stdenv = if stdenv.isDarwin
      then stdenvAdapters.overrideGCC stdenv gccApple
      else stdenv;
  };

  irssi_fish = callPackage ../applications/networking/irc/irssi/fish { };

  irssi_otr = callPackage ../applications/networking/irc/irssi/otr { };

  jack_capture = callPackage ../applications/audio/jack-capture { };

  jack_oscrolloscope = callPackage ../applications/audio/jack-oscrolloscope { };

  jack_rack = callPackage ../applications/audio/jack-rack { };

  jbrout = callPackage ../applications/graphics/jbrout {
    inherit (pythonPackages) lxml;
  };

  k3d = callPackage ../applications/graphics/k3d {
    inherit (pkgs.gnome2) gtkglext;
  };

  keepnote = callPackage ../applications/office/keepnote {
    pygtk = pyGtkGlade;
  };

  keymon = callPackage ../applications/video/key-mon { };

  kino = callPackage ../applications/video/kino {
    inherit (gnome) libglade;
  };

  ladspaH = callPackage ../applications/audio/ladspa-plugins/ladspah.nix { };

  ladspaPlugins = callPackage ../applications/audio/ladspa-plugins {
    fftw = fftwSinglePrec;
  };

  ldcpp = callPackage ../applications/networking/p2p/ldcpp {
    inherit (gnome) libglade;
  };

  librecad2 = callPackage ../applications/misc/librecad/2.0.nix { };

  libreoffice = callPackage ../applications/office/libreoffice {
    inherit (perlPackages) ArchiveZip CompressZlib;
    inherit (gnome) GConf ORBit2 gnome_vfs;
    zip = zip.override { enableNLS = false; };
    boost = boost155;
    jdk = openjdk;
    fontsConf = makeFontsConf {
      fontDirectories = [
        freefont_ttf xorg.fontmiscmisc xorg.fontbhttf
      ];
    };
    clucene_core = clucene_core_2;
    lcms = lcms2;
    harfbuzz = harfbuzz.override {
      withIcu = true; withGraphite2 = true;
    };
  };

  lingot = callPackage ../applications/audio/lingot {
    inherit (gnome) libglade;
  };

  ledger = callPackage ../applications/office/ledger/2.6.3.nix { };
  ledger3 = callPackage ../applications/office/ledger/3.0.nix { };

  linphone = callPackage ../applications/networking/instant-messengers/linphone rec {
    inherit (gnome) libglade;
    libexosip = libexosip_3;
    libosip = libosip_3;
  };

  linuxsampler = callPackage ../applications/audio/linuxsampler {
    bison = bison2;
  };

  llpp = callPackage ../applications/misc/llpp { inherit (ocamlPackages) lablgl; };

  mda_lv2 = callPackage ../applications/audio/mda-lv2 { };

  meld = callPackage ../applications/version-management/meld {
    inherit (gnome) scrollkeeper;
    pygtk = pyGtkGlade;
  };

  mercurial = callPackage ../applications/version-management/mercurial {
    inherit (pythonPackages) curses docutils;
    guiSupport = false; # use mercurialFull to get hgk GUI
  };

  mercurialFull = appendToName "full" (pkgs.mercurial.override { guiSupport = true; });

  midoriWrapper = wrapFirefox
    { browser = midori; browserName = "midori"; desktopName = "Midori";
      icon = "${midori}/share/icons/hicolor/22x22/apps/midori.png";
    };

  mixxx = callPackage ../applications/audio/mixxx {
    inherit (vamp) vampSDK;
  };

  monkeysAudio = callPackage ../applications/audio/monkeys-audio { };

  monodevelop = callPackage ../applications/editors/monodevelop {
    inherit (gnome) gnome_vfs libbonobo libglade libgnome GConf;
    mozilla = firefox;
    gtksharp = gtksharp2;
  };

  monodoc = callPackage ../applications/editors/monodoc {
    gtksharp = gtksharp1;
  };

  monotone = callPackage ../applications/version-management/monotone {
    lua = lua5;
    boost = boost149;
  };

  monotoneViz = builderDefsPackage (import ../applications/version-management/monotone-viz/mtn-head.nix) {
    inherit ocaml graphviz pkgconfig autoconf automake libtool glib gtk;
    inherit (ocamlPackages) lablgtk;
    inherit (gnome) libgnomecanvas;
  };

  mozilla = callPackage ../applications/networking/browsers/mozilla {
    inherit (gnome) libIDL;
  };

  mozplugger = builderDefsPackage (import ../applications/networking/browsers/mozilla-plugins/mozplugger) {
    inherit firefox;
    inherit (xlibs) libX11 xproto;
  };

  mpc_cli = callPackage ../applications/audio/mpc { };

  mplayer = callPackage ../applications/video/mplayer {
    pulseSupport = config.pulseaudio or false;
    vdpauSupport = config.mplayer.vdpauSupport or false;
  };

  MPlayerPlugin = browser:
    import ../applications/networking/browsers/mozilla-plugins/mplayerplug-in {
      inherit browser;
      inherit fetchurl stdenv pkgconfig gettext;
      inherit (xlibs) libXpm;
      # !!! should depend on MPlayer
    };

  mpv = callPackage ../applications/video/mpv {
    lua = lua5_1;
    bs2bSupport = true;
    quviSupport = true;
    cacaSupport = true;
  };

  multisync = callPackage ../applications/misc/multisync {
    inherit (gnome) ORBit2 libbonobo libgnomeui GConf;
  };

  mumble = callPackage ../applications/networking/mumble {
    avahi = avahi.override {
      withLibdnssdCompat = true;
    };
    jackSupport = config.mumble.jackSupport or false;
    speechdSupport = config.mumble.speechdSupport or false;
  };

  murmur = callPackage ../applications/networking/mumble/murmur.nix {
    avahi = avahi.override {
      withLibdnssdCompat = true;
    };
    iceSupport = config.murmur.iceSupport or true;
  };

  ruby_gpgme = callPackage ../development/libraries/ruby_gpgme {
    ruby = ruby19;
    hoe = rubyLibs.hoe;
  };

  sup = with rubyLibs; callPackage ../applications/networking/mailreaders/sup {
    ruby = ruby19.override {
      cursesSupport = true;
    };

    inherit gettext highline iconv locale lockfile rmail_sup
      text trollop unicode xapian_ruby which;

    # See https://github.com/NixOS/nixpkgs/issues/1804 and
    # https://github.com/NixOS/nixpkgs/issues/2146
    bundler = pkgs.lib.overrideDerivation pkgs.rubyLibs.bundler (
      oldAttrs: {
        dontPatchShebangs = 1;
      }
    );

    chronic      = chronic_0_9_1;
    gpgme        = ruby_gpgme;
    mime_types   = mime_types_1_25;
    ncursesw_sup = ruby_ncursesw_sup;
    rake         = rubyLibs.rake_10_1_0;
  };

  imapfilter = callPackage ../applications/networking/mailreaders/imapfilter.nix {
    lua = lua5;
 };

  tvtime = callPackage ../applications/video/tvtime {
    kernel = linux;
  };

  nedit = callPackage ../applications/editors/nedit {
    motif = lesstif;
  };

  netsurfBrowser = netsurf.browser;
  netsurf = recurseIntoAttrs (import ../applications/networking/browsers/netsurf { inherit pkgs; });

  notmuch = callPackage ../applications/networking/mailreaders/notmuch {
    # use emacsPackages.notmuch if you want emacs support
    emacs = null;
  };

  novaclient = callPackage ../applications/virtualization/nova/client.nix { };

  opera = callPackage ../applications/networking/browsers/opera {
    inherit (pkgs.kde4) kdelibs;
  };

  opusTools = callPackage ../applications/audio/opus-tools { };

  pan = callPackage ../applications/networking/newsreaders/pan {
    spellChecking = false;
  };

  petrifoo = callPackage ../applications/audio/petrifoo {
    inherit (gnome) libgnomecanvas;
  };

  pidgin = callPackage ../applications/networking/instant-messengers/pidgin {
    openssl = if config.pidgin.openssl or true then openssl else null;
    gnutls = if config.pidgin.gnutls or false then gnutls else null;
    libgcrypt = if config.pidgin.gnutls or false then libgcrypt else null;
    startupnotification = libstartup_notification;
  };

  pidginlatex = callPackage ../applications/networking/instant-messengers/pidgin-plugins/pidgin-latex {
    imagemagick = imagemagickBig;
  };

  pidginlatexSF = builderDefsPackage
    (import ../applications/networking/instant-messengers/pidgin-plugins/pidgin-latex/pidgin-latex-sf.nix)
    {
      inherit pkgconfig pidgin texLive imagemagick which glib gtk;
    };

  pidginmsnpecan = callPackage ../applications/networking/instant-messengers/pidgin-plugins/msn-pecan { };

  pidginotr = callPackage ../applications/networking/instant-messengers/pidgin-plugins/otr { };

  pidginsipe = callPackage ../applications/networking/instant-messengers/pidgin-plugins/sipe { };

  toxprpl = callPackage ../applications/networking/instant-messengers/pidgin-plugins/tox-prpl { };

  pinta = callPackage ../applications/graphics/pinta {
    gtksharp = gtksharp2;
  };

  pommed = callPackage ../os-specific/linux/pommed {
    inherit (xorg) libXpm;
  };

  # perhaps there are better apps for this task? It's how I had configured my preivous system.
  # And I don't want to rewrite all rules
  pythonmagick = callPackage ../applications/graphics/PythonMagick { };

  quodlibet = callPackage ../applications/audio/quodlibet {
    inherit (pythonPackages) mutagen;
  };

  quodlibet-with-gst-plugins = callPackage ../applications/audio/quodlibet {
    inherit (pythonPackages) mutagen;
    withGstPlugins = true;
    gst_plugins_bad = null;
  };

  rakarrack = callPackage ../applications/audio/rakarrack {
    inherit (xorg) libXpm libXft;
    fltk = fltk13;
  };

  rawtherapee = callPackage ../applications/graphics/rawtherapee {
    fftw = fftwSinglePrec;
  };

  retroshare = callPackage ../applications/networking/p2p/retroshare {
    qt = qt4;
  };

  retroshare06 = callPackage ../applications/networking/p2p/retroshare/0.6.nix {
    qt = qt4;
  };

  rsync = callPackage ../applications/networking/sync/rsync {
    enableACLs = !(stdenv.isDarwin || stdenv.isSunOS || stdenv.isFreeBSD);
    enableCopyDevicesPatch = (config.rsync.enableCopyDevicesPatch or false);
  };

  # = urxvt
  rxvt_unicode = callPackage ../applications/misc/rxvt_unicode {
    perlSupport = true;
    gdkPixbufSupport = true;
    unicode3Support = true;
  };

  sakura = callPackage ../applications/misc/sakura {
    inherit (gnome) vte;
  };

  scribus = callPackage ../applications/office/scribus {
    inherit (gnome) libart_lgpl;
  };

  seeks = callPackage ../tools/networking/p2p/seeks {
    opencv = opencv_2_1;
  };

  seg3d = callPackage ../applications/graphics/seg3d {
    wxGTK = wxGTK28.override { unicode = false; };
  };

  sflphone = callPackage ../applications/networking/instant-messengers/sflphone {
    gtk = gtk3;
  };

  skype = callPackage_i686 ../applications/networking/instant-messengers/skype { };

  skype_call_recorder = callPackage ../applications/networking/instant-messengers/skype-call-recorder { };

  st = callPackage ../applications/misc/st {
    conf = config.st.conf or null;
  };

  sweethome3d = recurseIntoAttrs (  (callPackage ../applications/misc/sweethome3d { })
                                 // (callPackage ../applications/misc/sweethome3d/editors.nix {
                                      sweethome3dApp = sweethome3d.application;
                                    })
                                 );

  bittorrentSync = callPackage ../applications/networking/bittorrentsync { };

  lightdm_gtk_greeter = callPackage ../applications/display-managers/lightdm-gtk-greeter { };

  # slic3r 0.9.10b says: "Running Slic3r under Perl >= 5.16 is not supported nor recommended"
  slic3r = callPackage ../applications/misc/slic3r {
    inherit (perl514Packages) EncodeLocale MathClipper ExtUtilsXSpp
            BoostGeometryUtils MathConvexHullMonotoneChain MathGeometryVoronoi
            MathPlanePath Moo IOStringy ClassXSAccessor Wx GrowlGNTP NetDBus;
    perl = perl514;
  };

  slim = callPackage ../applications/display-managers/slim {
    libpng = libpng12;
  };

  sonic_visualiser = callPackage ../applications/audio/sonic-visualiser {
    inherit (pkgs.vamp) vampSDK;
    inherit (pkgs.xlibs) libX11;
    fftw = pkgs.fftwSinglePrec;
  };

  spotify = callPackage ../applications/audio/spotify {
    inherit (gnome) GConf;
    libpng = libpng12;
  };

  libspotify = callPackage ../development/libraries/libspotify {
    apiKey = config.libspotify.apiKey or null;
  };

  stumpwm = lispPackages.stumpwm;

  sublime3 = lowPrio (callPackage ../applications/editors/sublime3 { });

  subversion = callPackage ../applications/version-management/subversion/default.nix {
    bdbSupport = true;
    httpServer = false;
    httpSupport = true;
    pythonBindings = false;
    perlBindings = false;
    javahlBindings = false;
    saslSupport = false;
    httpd = apacheHttpd;
    sasl = cyrus_sasl;
  };

  subversionClient = appendToName "client" (subversion.override {
    bdbSupport = false;
    perlBindings = true;
    pythonBindings = true;
  });

  surf = callPackage ../applications/misc/surf {
    webkit = webkitgtk2;
  };

  svk = perlPackages.SVK;

  swh_lv2 = callPackage ../applications/audio/swh-lv2 { };

  sylpheed = callPackage ../applications/networking/mailreaders/sylpheed {
    sslSupport = true;
    gpgSupport = true;
  };

  # linux only by now
  tahoelafs = callPackage ../tools/networking/p2p/tahoe-lafs {
    inherit (pythonPackages) twisted foolscap simplejson nevow zfec
      pycryptopp sqlite3 darcsver setuptoolsTrial setuptoolsDarcs
      numpy pyasn1 mock;
  };

  tailor = builderDefsPackage (import ../applications/version-management/tailor) {
    inherit makeWrapper python;
  };

  tangogps = callPackage ../applications/misc/tangogps {
    gconf = gnome.GConf;
  };

  teamspeak_client = callPackage ../applications/networking/instant-messengers/teamspeak/client.nix { };
  teamspeak_server = callPackage ../applications/networking/instant-messengers/teamspeak/server.nix { };

  telegram-cli = callPackage ../applications/networking/instant-messengers/telegram-cli/default.nix { };

  telepathy_gabble = callPackage ../applications/networking/instant-messengers/telepathy/gabble {
    inherit (pkgs.gnome) libsoup;
  };

  telepathy_haze = callPackage ../applications/networking/instant-messengers/telepathy/haze {};

  telepathy_logger = callPackage ../applications/networking/instant-messengers/telepathy/logger {};

  telepathy_mission_control = callPackage ../applications/networking/instant-messengers/telepathy/mission-control { };

  telepathy_rakia = callPackage ../applications/networking/instant-messengers/telepathy/rakia { };

  telepathy_salut = callPackage ../applications/networking/instant-messengers/telepathy/salut {};

  terminator = callPackage ../applications/misc/terminator {
    vte = gnome.vte.override { pythonSupport = true; };
    inherit (pythonPackages) notify;
  };

  thinkingRock = callPackage ../applications/misc/thinking-rock { };

  thunderbird = callPackage ../applications/networking/mailreaders/thunderbird {
    inherit (gnome) libIDL;
  };

  thunderbird-bin = callPackage ../applications/networking/mailreaders/thunderbird-bin {
    gconf = pkgs.gnome.GConf;
    inherit (pkgs.gnome3) at_spi2_atk;
    inherit (pkgs.gnome) libgnome libgnomeui;
    inherit (pkgs.xlibs) libX11 libXScrnSaver libXext
      libXinerama libXrender libXt;
  };

  tig = gitAndTools.tig;

  tla = callPackage ../applications/version-management/arch { };

  todo-txt-cli = callPackage ../applications/office/todo.txt-cli { };

  torchat = callPackage ../applications/networking/instant-messengers/torchat {
    wrapPython = pythonPackages.wrapPython;
  };

  transmission_gtk = transmission.override { enableGTK3 = true; };

  transmission_remote_gtk = callPackage ../applications/networking/p2p/transmission-remote-gtk {};

  tree = callPackage ../tools/system/tree {
    # use gccApple to compile on darwin as the configure script adds a
    # -no-cpp-precomp flag, which is not compatible with the default gcc
    stdenv = if stdenv.isDarwin
      then stdenvAdapters.overrideGCC stdenv gccApple
      else stdenv;
  };

  twinkle = callPackage ../applications/networking/instant-messengers/twinkle {
    ccrtp = ccrtp_1_8;
    libzrtpcpp = libzrtpcpp_1_6;
  };

  unison = callPackage ../applications/networking/sync/unison {
    inherit (ocamlPackages) lablgtk;
    enableX11 = config.unison.enableX11 or true;
  };

  uzbl = callPackage ../applications/networking/browsers/uzbl {
    webkit = webkitgtk2;
  };

  viewMtn = builderDefsPackage (import ../applications/version-management/viewmtn/0.10.nix)
  {
    inherit monotone cheetahTemplate highlight ctags
      makeWrapper graphviz which python;
    flup = pythonPackages.flup;
  };

  macvim = callPackage ../applications/editors/vim/macvim.nix { };

  vimHugeX = vim_configurable;

  vim_configurable = callPackage ../applications/editors/vim/configurable.nix {
    inherit (pkgs) fetchurl fetchhg stdenv ncurses pkgconfig gettext
      composableDerivation lib config glib gtk python perl tcl ruby;
    inherit (pkgs.xlibs) libX11 libXext libSM libXpm libXt libXaw libXau libXmu
      libICE;

    features = "huge"; # one of  tiny, small, normal, big or huge
    lua = pkgs.lua5;
    gui = config.vim.gui or "auto";

    # optional features by flags
    flags = [ "python" "X11" ]; # only flag "X11" by now

    # so that we can use gccApple if we're building on darwin
    inherit stdenvAdapters gccApple;
  };

  vimNox = lowPrio (vim_configurable.override { source = "vim-nox"; });

  qvim = lowPrio (callPackage ../applications/editors/vim/qvim.nix {
    inherit (pkgs) fetchgit stdenv ncurses pkgconfig gettext
      composableDerivation lib config python perl tcl ruby qt4;
    inherit (pkgs.xlibs) libX11 libXext libSM libXpm libXt libXaw libXau libXmu
      libICE;

    inherit (pkgs) stdenvAdapters gccApple;

    features = "huge"; # one of  tiny, small, normal, big or huge
    lua = pkgs.lua5;
    flags = [ "python" "X11" ]; # only flag "X11" by now
  });

  virtviewer = callPackage ../applications/virtualization/virt-viewer {
    gtkvnc = gtkvnc.override { enableGTK3 = true; };
    spice_gtk = spice_gtk.override { enableGTK3 = true; };
  };
  virtmanager = callPackage ../applications/virtualization/virt-manager {
    inherit (gnome) gnome_python;
    vte = gnome3.vte;
    dconf = gnome3.dconf;
    gtkvnc = gtkvnc.override { enableGTK3 = true; };
    spice_gtk = spice_gtk.override { enableGTK3 = true; };
  };

  vkeybd = callPackage ../applications/audio/vkeybd {
    inherit (xlibs) libX11;
  };

  vorbisTools = callPackage ../applications/audio/vorbis-tools { };

  vue = callPackage ../applications/misc/vue {
    jre = icedtea7_jre;
  };

  w3m = callPackage ../applications/networking/browsers/w3m {
    graphicsSupport = false;
  };

  weechatDevel = lowPrio (callPackage ../applications/networking/irc/weechat/devel.nix { });

  wings = callPackage ../applications/graphics/wings {
    erlang = erlangR14;
    esdl = esdl.override { erlang = erlangR14; };
  };

  # I'm keen on wmiimenu only  >wmii-3.5 no longer has it...
  wmiimenu = import ../applications/window-managers/wmii31 {
    libixp = libixp_for_wmii;
    inherit fetchurl /* fetchhg */ stdenv gawk;
    inherit (xlibs) libX11;
  };

  wmiiSnap = import ../applications/window-managers/wmii {
    libixp = libixp_for_wmii;
    inherit fetchurl /* fetchhg */ stdenv gawk;
    inherit (xlibs) libX11 xextproto libXt libXext;
    includeUnpack = config.stdenv.includeUnpack or false;
  };

  wrapChromium = browser: wrapFirefox {
    inherit browser;
    browserName = browser.packageName;
    desktopName = "Chromium";
    icon = "${browser}/share/icons/hicolor/48x48/apps/${browser.packageName}.png";
  };

  wrapFirefox =
    { browser, browserName ? "firefox", desktopName ? "Firefox", nameSuffix ? ""
    , icon ? "${browser}/lib/${browser.name}/icons/mozicon128.png" }:
    let
      cfg = stdenv.lib.attrByPath [ browserName ] {} config;
      enableAdobeFlash = cfg.enableAdobeFlash or false;
      enableGnash = cfg.enableGnash or false;
    in
    import ../applications/networking/browsers/firefox/wrapper.nix {
      inherit stdenv lib makeWrapper makeDesktopItem browser browserName desktopName nameSuffix icon;
      plugins =
         assert !(enableGnash && enableAdobeFlash);
         ([ ]
          ++ lib.optional enableGnash gnash
          ++ lib.optional enableAdobeFlash flashplayer
          ++ lib.optional (cfg.enableDjvu or false) (djview4)
          ++ lib.optional (cfg.enableMPlayer or false) (MPlayerPlugin browser)
          ++ lib.optional (cfg.enableGeckoMediaPlayer or false) gecko_mediaplayer
          ++ lib.optional (supportsJDK && cfg.jre or false && jrePlugin ? mozillaPlugin) jrePlugin
          ++ lib.optional (cfg.enableGoogleTalkPlugin or false) google_talk_plugin
          ++ lib.optional (cfg.enableFriBIDPlugin or false) fribid
          ++ lib.optional (cfg.enableGnomeExtensions or false) gnome3.gnome_shell
         );
      libs = [ gstreamer gst_plugins_base ] ++ lib.optionals (cfg.enableQuakeLive or false)
             (with xlibs; [ stdenv.gcc libX11 libXxf86dga libXxf86vm libXext libXt alsaLib zlib ]);
      gtk_modules = [ libcanberra ];
    };

  xaos = builderDefsPackage (import ../applications/graphics/xaos) {
    inherit (xlibs) libXt libX11 libXext xextproto xproto;
    inherit gsl aalib zlib intltool gettext perl;
    libpng = libpng12;
  };

  xbmc = callPackage ../applications/video/xbmc {
    ffmpeg = ffmpeg_1;
  };

  xdg_utils = callPackage ../tools/X11/xdg-utils { };

  xfe = callPackage ../applications/misc/xfe {
    fox = fox_1_6;
  };

  xineUI = callPackage ../applications/video/xine-ui { };

  xneur_0_13 = callPackage ../applications/misc/xneur { };

  xneur_0_8 = callPackage ../applications/misc/xneur/0.8.nix { };

  xneur = xneur_0_13;

  gxneur = callPackage ../applications/misc/gxneur  {
    inherit (gnome) libglade GConf;
  };

  xournal = callPackage ../applications/graphics/xournal {
    inherit (gnome) libgnomeprint libgnomeprintui libgnomecanvas;
  };

  xpdf = callPackage ../applications/misc/xpdf {
    motif = lesstif;
    base14Fonts = "${ghostscript}/share/ghostscript/fonts";
  };

  xkb_switch = callPackage ../tools/X11/xkb-switch { };

  libxpdf = callPackage ../applications/misc/xpdf/libxpdf.nix { };

  xscreensaver = callPackage ../misc/screensavers/xscreensaver {
    inherit (gnome) libglade;
  };

  xsynth_dssi = callPackage ../applications/audio/xsynth-dssi { };

  xnee = callPackage ../tools/X11/xnee {
    # Work around "missing separator" error.
    stdenv = overrideInStdenv stdenv [ gnumake381 ];
  };

  xvidcap = callPackage ../applications/video/xvidcap {
    inherit (gnome) scrollkeeper libglade;
  };

  inherit (gnome3) yelp;

  yoshimi = callPackage ../applications/audio/yoshimi {
    fltk = fltk13;
  };

  zathuraCollection = recurseIntoAttrs
    (let callPackage = newScope pkgs.zathuraCollection; in
      import ../applications/misc/zathura {
        inherit callPackage pkgs fetchurl;
        useMupdf = config.zathura.useMupdf or false;
      });

  zathura = zathuraCollection.zathuraWrapper;

  zeroc_ice = callPackage ../development/libraries/zeroc-ice { };

  girara = callPackage ../applications/misc/girara {
    gtk = gtk3;
  };


  ### GAMES

  andyetitmoves = if stdenv.isLinux then callPackage ../games/andyetitmoves {} else null;

  asc = callPackage ../games/asc {
    lua = lua5;
    libsigcxx = libsigcxx12;
  };

  ballAndPaddle = callPackage ../games/ball-and-paddle {
    guile = guile_1_8;
  };

  bitsnbots = callPackage ../games/bitsnbots {
    lua = lua5;
  };

  castle_combat = callPackage ../games/castle-combat { };

  construoBase = lowPrio (callPackage ../games/construo {
    mesa = null;
    freeglut = null;
  });

  construo = construoBase.override {
    inherit mesa freeglut;
  };

  crack_attack = callPackage ../games/crack-attack { };

  craftyFull = appendToName "full" (crafty.override { fullVariant = true; });

  dwarf_fortress = callPackage_i686 ../games/dwarf-fortress {
    SDL_image = pkgsi686Linux.SDL_image.override {
      libpng = pkgsi686Linux.libpng12;
    };
  };

  dwarf_fortress_modable = appendToName "moddable" (dwarf_fortress.override {
    copyDataDirectory = true;
  });

  d1x_rebirth = callPackage ../games/d1x-rebirth { };

  d2x_rebirth = callPackage ../games/d2x-rebirth { };

  freeciv_gtk = callPackage ../games/freeciv {
    gtkClient = true;
    sdlClient = false;
  };

  fsg = callPackage ../games/fsg {
    wxGTK = wxGTK28.override { unicode = false; };
  };

  gl117 = callPackage ../games/gl-117 {};

  globulation2 = callPackage ../games/globulation {};

  gsmartcontrol = callPackage ../tools/misc/gsmartcontrol {
    inherit (gnome) libglademm;
  };

  instead = callPackage ../games/instead {
    lua = lua5;
  };

  lincity = builderDefsPackage (import ../games/lincity) {
    inherit (xlibs) libX11 libXext xextproto
      libICE libSM xproto;
    inherit libpng zlib;
  };

  lincity_ng = callPackage ../games/lincity/ng.nix {};

  mnemosyne = callPackage ../games/mnemosyne {
    inherit (pythonPackages) matplotlib cherrypy sqlite3;
  };

  openttd = callPackage ../games/openttd {
    zlib = zlibStatic;
  };

  quake3demo = callPackage ../games/quake3/wrapper {
    name = "quake3-demo-${quake3game.name}";
    description = "Demo of Quake 3 Arena, a classic first-person shooter";
    game = quake3game;
    paks = [quake3demodata];
  };

  quake3demodata = callPackage ../games/quake3/demo { };

  quake3game = callPackage ../games/quake3/game { };

  residualvm = callPackage ../games/residualvm {
    openglSupport = mesaSupported;
  };

  rigsofrods = callPackage ../games/rigsofrods {
    mygui = myguiSvn;
  };

  sgtpuzzles = builderDefsPackage (import ../games/sgt-puzzles) {
    inherit pkgconfig fetchsvn perl gtk;
    inherit (xlibs) libX11;
  };

  # You still can override by passing more arguments.
  spaceOrbit = callPackage ../games/orbit { };

  springLobby = callPackage ../games/spring/springlobby.nix { };

  steam = callPackage_i686 ../games/steam {};

  steamChrootEnv = callPackage_i686 ../games/steam/chrootenv.nix {
    zenity = gnome2.zenity;
  };

  superTux = callPackage ../games/super-tux { };

  superTuxKart = callPackage ../games/super-tux-kart { };

  tbe = callPackage ../games/the-butterfly-effect {};

  tpm = callPackage ../games/thePenguinMachine { };

  speed_dreams = callPackage ../games/speed-dreams {
    # Torcs wants to make shared libraries linked with plib libraries (it provides static).
    # i686 is the only platform I know than can do that linking without plib built with -fPIC
    plib = plib.override { enablePIC = !stdenv.isi686; };
    libpng = libpng12;
  };

  torcs = callPackage ../games/torcs {
    # Torcs wants to make shared libraries linked with plib libraries (it provides static).
    # i686 is the only platform I know than can do that linking without plib built with -fPIC
    plib = plib.override { enablePIC = !stdenv.isi686; };
  };

  ultrastardx = callPackage ../games/ultrastardx {
    ffmpeg = ffmpeg_0_6;
    lua = lua5;
  };

  vessel = callPackage_i686 ../games/vessel { };

  warsow = callPackage ../games/warsow {
    libjpeg = libjpeg62;
  };

  widelands = callPackage ../games/widelands {
    lua = lua5_1;
  };

  worldofgoo_demo = callPackage ../games/worldofgoo {
    demo = true;
  };

  # TODO: the corresponding nix file is missing
  # xracer = callPackage ../games/xracer { };

  xsokoban = builderDefsPackage (import ../games/xsokoban) {
    inherit (xlibs) libX11 xproto libXpm libXt;
  };

  zeroad = callPackage ../games/0ad { };

  ### DESKTOP ENVIRONMENTS

  cinnamon = recurseIntoAttrs rec {
    callPackage = newScope pkgs.cinnamon;
    inherit (gnome3) gnome_common libgnomekbd gnome-menus zenity;

    muffin = callPackage ../desktops/cinnamon/muffin.nix { };

    cinnamon-control-center = callPackage ../desktops/cinnamon/cinnamon-control-center.nix { };

    cinnamon-settings-daemon = callPackage ../desktops/cinnamon/cinnamon-settings-daemon.nix { };

    cinnamon-session = callPackage ../desktops/cinnamon/cinnamon-session.nix { };

    cinnamon-desktop = callPackage ../desktops/cinnamon/cinnamon-desktop.nix { };

    cinnamon-translations = callPackage ../desktops/cinnamon/cinnamon-translations.nix { };

    cjs = callPackage ../desktops/cinnamon/cjs.nix { };
  };

  e17 = recurseIntoAttrs (
    let callPackage = newScope pkgs.e17; in
    import ../desktops/e17 { inherit callPackage pkgs; }
  );

  e18 = recurseIntoAttrs (
    let callPackage = newScope pkgs.e18; in
    import ../desktops/e18 { inherit callPackage pkgs; }
  );

  gnome2 = callPackage ../desktops/gnome-2 {
    callPackage = pkgs.newScope pkgs.gnome2;
    self = pkgs.gnome2;
  }  // pkgs.gtkLibs // {
    # Backwards compatibility;
    inherit (pkgs) libsoup libwnck gtk_doc gnome_doc_utils;
  };

  gnome3 = recurseIntoAttrs (callPackage ../desktops/gnome-3/3.10 {
    callPackage = pkgs.newScope pkgs.gnome3;
    self = pkgs.gnome3;
  });

  gnome3_12 = recurseIntoAttrs (callPackage ../desktops/gnome-3/3.12 {
    callPackage = pkgs.newScope pkgs.gnome3_12;
  });

  gnome = recurseIntoAttrs gnome2;

  kde4 = recurseIntoAttrs pkgs.kde412;

  kde4_next = recurseIntoAttrs( lib.lowPrioSet pkgs.kde412 );

  kde412 = kdePackagesFor (pkgs.kde412 // {
      eigen = eigen2;
      libusb = libusb1;
      libcanberra = libcanberra_kde;
    }) ../desktops/kde-4.12;

  kdePackagesFor = self: dir:
    let callPackageOrig = callPackage; in
    let
      callPackage = newScope self;
      kde4 = callPackageOrig dir {
        inherit callPackage callPackageOrig;
      };
    in kde4 // {
      inherit kde4;

      wrapper = callPackage ../build-support/kdewrapper {};

      recurseForRelease = true;

      akunambol = callPackage ../applications/networking/sync/akunambol { };

      amarok = callPackage ../applications/audio/amarok { };

      bangarang = callPackage ../applications/video/bangarang { };

      basket = callPackage ../applications/office/basket { };

      bluedevil = callPackage ../tools/bluetooth/bluedevil { };

      calligra = callPackage ../applications/office/calligra { };

      digikam = if builtins.compareVersions "4.9" kde4.release == 1 then
          callPackage ../applications/graphics/digikam/2.nix { }
        else
          callPackage ../applications/graphics/digikam { };

      eventlist = callPackage ../applications/office/eventlist {};

      k3b = callPackage ../applications/misc/k3b { };

      kadu = callPackage ../applications/networking/instant-messengers/kadu { };

      kbibtex = callPackage ../applications/office/kbibtex { };

      kde_gtk_config = callPackage ../tools/misc/kde-gtk-config { };

      kde_wacomtablet = callPackage ../applications/misc/kde-wacomtablet { };

      kdeconnect = callPackage ../applications/misc/kdeconnect { };

      kdenlive = callPackage ../applications/video/kdenlive { };

      kdesvn = callPackage ../applications/version-management/kdesvn { };

      kdevelop = callPackage ../applications/editors/kdevelop { };

      kdevplatform = callPackage ../development/libraries/kdevplatform { };

      kdiff3 = callPackage ../tools/text/kdiff3 { };

      kile = callPackage ../applications/editors/kile { };

      kmplayer = callPackage ../applications/video/kmplayer { };

      kmymoney = callPackage ../applications/office/kmymoney { };

      kipi_plugins = callPackage ../applications/graphics/kipi-plugins { };

      konversation = callPackage ../applications/networking/irc/konversation { };

      kvirc = callPackage ../applications/networking/irc/kvirc { };

      krename = callPackage ../applications/misc/krename { };

      krusader = callPackage ../applications/misc/krusader { };

      ksshaskpass = callPackage ../tools/security/ksshaskpass {};

      ktorrent = callPackage ../applications/networking/p2p/ktorrent { };

      kuickshow = callPackage ../applications/graphics/kuickshow { };

      libalkimia = callPackage ../development/libraries/libalkimia { };

      libktorrent = callPackage ../development/libraries/libktorrent { };

      libkvkontakte = callPackage ../development/libraries/libkvkontakte { };

      liblikeback = callPackage ../development/libraries/liblikeback { };

      libmm-qt = callPackage ../development/libraries/libmm-qt { };

      libnm-qt = callPackage ../development/libraries/libnm-qt { };

      networkmanagement = callPackage ../tools/networking/networkmanagement { };

      partitionManager = callPackage ../tools/misc/partition-manager { };

      plasma-nm = callPackage ../tools/networking/plasma-nm { };

      polkit_kde_agent = callPackage ../tools/security/polkit-kde-agent { };

      psi = callPackage ../applications/networking/instant-messengers/psi { };

      qtcurve = callPackage ../misc/themes/qtcurve { };

      quassel = callPackage ../applications/networking/irc/quassel { dconf = gnome3.dconf; };

      quasselDaemon = (self.quassel.override {
        monolithic = false;
        daemon = true;
        tag = "-daemon";
      });

      quasselClient = (self.quassel.override {
        monolithic = false;
        client = true;
        tag = "-client";
      });

      rekonq = callPackage ../applications/networking/browsers/rekonq { };

      kwebkitpart = callPackage ../applications/networking/browsers/kwebkitpart { };

      rsibreak = callPackage ../applications/misc/rsibreak { };

      semnotes = callPackage ../applications/misc/semnotes { };

      skrooge = callPackage ../applications/office/skrooge { };

      telepathy = callPackage ../applications/networking/instant-messengers/telepathy/kde {};

      yakuake = callPackage ../applications/misc/yakuake { };

      zanshin = callPackage ../applications/office/zanshin { };

      kwooty = callPackage ../applications/networking/newsreaders/kwooty { };
    };

  redshift = callPackage ../applications/misc/redshift {
    inherit (xorg) libX11 libXrandr libxcb randrproto libXxf86vm
      xf86vidmodeproto;
    inherit (gnome) GConf;
    inherit (pythonPackages) pyxdg;
    geoclue = geoclue2;
  };

  oxygen_gtk = callPackage ../misc/themes/gtk2/oxygen-gtk { };

  gtk_engines = callPackage ../misc/themes/gtk2/gtk-engines { };

  gnome_themes_standard = gnome3.gnome_themes_standard;

  xfce = xfce4_10;
  xfce4_10 = recurseIntoAttrs (import ../desktops/xfce { inherit pkgs newScope; });


  ### SCIENCE

  ### SCIENCE/GEOMETRY

  drgeo = builderDefsPackage (import ../applications/science/geometry/drgeo) {
    inherit (gnome) libglade;
    inherit libxml2 perl intltool libtool pkgconfig gtk;
    guile = guile_1_8;
  };


  ### SCIENCE/BIOLOGY

  alliance = callPackage ../applications/science/electronics/alliance {
    motif = lesstif;
  };

  arb = callPackage ../applications/science/biology/arb {
    lesstif = lesstif93;
  };

  ncbiCTools = builderDefsPackage ../development/libraries/ncbi {
    inherit tcsh mesa lesstif;
    inherit (xlibs) libX11 libXaw xproto libXt libSM libICE
      libXmu libXext;
  };

  ncbi_tools = callPackage ../applications/science/biology/ncbi-tools { };

  plink = callPackage ../applications/science/biology/plink/default.nix { };


  ### SCIENCE/MATH

  atlas = callPackage ../development/libraries/science/math/atlas {
    # The build process measures CPU capabilities and optimizes the
    # library to perform best on that particular machine. That is a
    # great feature, but it's of limited use with pre-built binaries
    # coming from a central build farm.
    tolerateCpuTimingInaccuracy = true;
  };

  content = builderDefsPackage ../applications/science/math/content {
    inherit mesa lesstif;
    inherit (xlibs) libX11 libXaw xproto libXt libSM libICE
      libXmu libXext libXcursor;
  };

  ### SCIENCE/MOLECULAR-DYNAMICS

  gromacs = callPackage ../applications/science/molecular-dynamics/gromacs {
    singlePrec = true;
    fftw = fftwSinglePrec;
    cmake = cmakeCurses;
  };

  gromacsDouble = lowPrio (callPackage ../applications/science/molecular-dynamics/gromacs {
    singlePrec = false;
    fftw = fftw;
    cmake = cmakeCurses;
  });


  ### SCIENCE/LOGIC

  abc-verifier = callPackage ../applications/science/logic/abc {};

  coq = callPackage ../applications/science/logic/coq {
    inherit (ocamlPackages) findlib lablgtk;
    camlp5 = ocamlPackages.camlp5_transitional;
  };

  coq_8_3 = callPackage ../applications/science/logic/coq/8.3.nix {
    inherit (ocamlPackages) findlib lablgtk;
    camlp5 = ocamlPackages.camlp5_transitional;
  };

  eprover = callPackage ../applications/science/logic/eprover {
    texLive = texLiveAggregationFun {
      paths = [
        texLive texLiveExtra
      ];
    };
  };

  hol_light = callPackage ../applications/science/logic/hol_light {
    inherit (ocamlPackages) findlib;
    camlp5 = ocamlPackages.camlp5_strict;
  };

  isabelle = import ../applications/science/logic/isabelle {
    inherit (pkgs) stdenv fetchurl nettools perl polyml;
    inherit (pkgs.emacs24Packages) proofgeneral;
  };

  matita = callPackage ../applications/science/logic/matita {
    ocaml = ocaml_3_11_2;
    inherit (ocamlPackages_3_11_2) findlib lablgtk ocaml_expat gmetadom ocaml_http
            lablgtkmathview ocaml_mysql ocaml_sqlite3 ocamlnet camlzip ocaml_pcre;
    ulex08 = ocamlPackages_3_11_2.ulex08.override { camlp5 = ocamlPackages_3_11_2.camlp5_5_transitional; };
  };

  matita_130312 = lowPrio (callPackage ../applications/science/logic/matita/130312.nix {
    inherit (ocamlPackages) findlib lablgtk ocaml_expat gmetadom ocaml_http
            ocaml_mysql ocamlnet ulex08 camlzip ocaml_pcre;
  });

  prooftree = callPackage ../applications/science/logic/prooftree {
    inherit (ocamlPackages) findlib lablgtk;
    camlp5 = ocamlPackages.camlp5_transitional;
  };

  ssreflect = callPackage ../applications/science/logic/ssreflect {
    camlp5 = ocamlPackages.camlp5_transitional;
  };

  twelf = callPackage ../applications/science/logic/twelf {
    smlnj = if stdenv.isDarwin
      then smlnjBootstrap
      else smlnj;
  };

  boolector   = boolector15;
  boolector15 = callPackage ../applications/science/logic/boolector {};
  boolector16 = lowPrio (callPackage ../applications/science/logic/boolector {
    useV16 = true;
  });

  ### SCIENCE / ELECTRONICS

  eagle = callPackage_i686 ../applications/science/electronics/eagle { };

  kicad = callPackage ../applications/science/electronics/kicad {
    wxGTK = wxGTK29;
  };


  ### SCIENCE / MATH

  eukleides = callPackage ../applications/science/math/eukleides {
    texinfo = texinfo4;
  };

  pspp = callPackage ../applications/science/math/pssp {
    inherit (gnome) libglade gtksourceview;
  };

  scilab = callPackage ../applications/science/math/scilab {
    withXaw3d = false;
    withTk = true;
    withGtk = false;
    withOCaml = true;
    withX = true;
  };

  speedcrunch = callPackage ../applications/science/math/speedcrunch {
    qt = qt4;
    cmake = cmakeCurses;
  };


  ### SCIENCE / MISC

  celestia = callPackage ../applications/science/astronomy/celestia {
    lua = lua5_1;
    inherit (xlibs) libXmu;
    inherit (pkgs.gnome) gtkglext;
  };

  spyder = callPackage ../applications/science/spyder {
    inherit (pythonPackages) pyflakes rope sphinx numpy scipy matplotlib; # recommended
    inherit (pythonPackages) ipython pep8; # optional
    inherit pylint;
  };

  ### MISC

  ataripp = callPackage ../misc/emulators/atari++ { };

  cups = callPackage ../misc/cups { libusb = libusb1; };

  cups_pdf_filter = callPackage ../misc/cups/pdf-filter.nix { };

  gutenprintBin = callPackage ../misc/drivers/gutenprint/bin.nix { };

  cupsBjnp = callPackage ../misc/cups/drivers/cups-bjnp { };

  dblatex = callPackage ../tools/typesetting/tex/dblatex {
    enableAllFeatures = false;
  };

  dblatexFull = appendToName "full" (dblatex.override {
    enableAllFeatures = true;
  });

  ekiga = newScope pkgs.gnome ../applications/networking/instant-messengers/ekiga { };

  foomatic_filters = callPackage ../misc/drivers/foomatic-filters {};

  gensgs = callPackage_i686 ../misc/emulators/gens-gs { };

  ghostscript = callPackage ../misc/ghostscript {
    x11Support = false;
    cupsSupport = config.ghostscript.cups or (!stdenv.isDarwin);
    gnuFork = config.ghostscript.gnu or false;
  };

  ghostscriptX = appendToName "with-X" (ghostscript.override {
    x11Support = true;
  });

  hplipWithPlugin = hplip.override { withPlugin = true; };

  # using the new configuration style proposal which is unstable
  jack1d = callPackage ../misc/jackaudio/jack1.nix { };

  lilypond = callPackage ../misc/lilypond { guile = guile_1_8; };

  maven = maven3;
  maven3 = callPackage ../misc/maven { jdk = openjdk; };

  mess = callPackage ../misc/emulators/mess {
    inherit (pkgs.gnome) GConf;
  };

  mupen64plus1_5 = callPackage ../misc/emulators/mupen64plus/1.5.nix { };

  nix = nixStable;

  nixStable = callPackage ../tools/package-management/nix {
    storeDir = config.nix.storeDir or "/nix/store";
    stateDir = config.nix.stateDir or "/nix/var";
  };

  nixUnstable = callPackage ../tools/package-management/nix/unstable.nix {
    storeDir = config.nix.storeDir or "/nix/store";
    stateDir = config.nix.stateDir or "/nix/var";
  };

  solfege = callPackage ../misc/solfege {
      pysqlite = pkgs.pythonPackages.sqlite3;
  };

  dysnomia = callPackage ../tools/package-management/disnix/dysnomia {
    enableApacheWebApplication = config.disnix.enableApacheWebApplication or false;
    enableAxis2WebService = config.disnix.enableAxis2WebService or false;
    enableEjabberdDump = config.disnix.enableEjabberdDump or false;
    enableMySQLDatabase = config.disnix.enableMySQLDatabase or false;
    enablePostgreSQLDatabase = config.disnix.enablePostgreSQLDatabase or false;
    enableSubversionRepository = config.disnix.enableSubversionRepository or false;
    enableTomcatWebApplication = config.disnix.enableTomcatWebApplication or false;
  };

  latex2html = callPackage ../tools/typesetting/tex/latex2html/default.nix {
    tex = tetex;
  };

  mysqlWorkbench = newScope gnome ../applications/misc/mysql-workbench {
    lua = lua5;
    inherit (pythonPackages) pexpect paramiko;
  };

  pgf = pgf2;

  # Keep the old PGF since some documents don't render properly with
  # the new one.
  pgf1 = callPackage ../tools/typesetting/tex/pgf/1.x.nix { };

  pgf2 = callPackage ../tools/typesetting/tex/pgf/2.x.nix { };

  PPSSPP = callPackage ../misc/emulators/ppsspp { };

  rssglx = callPackage ../misc/screensavers/rss-glx { };

  samsungUnifiedLinuxDriver = import ../misc/cups/drivers/samsung {
    inherit fetchurl stdenv;
    inherit cups ghostscript glibc patchelf;
    gcc = import ../development/compilers/gcc/4.4 {
      inherit stdenv fetchurl gmp mpfr noSysDirs gettext which;
      texinfo = texinfo4;
      profiledCompiler = true;
    };
  };

  saneBackends = callPackage ../applications/graphics/sane/backends.nix {
    gt68xxFirmware = config.sane.gt68xxFirmware or null;
    snapscanFirmware = config.sane.snapscanFirmware or null;
    hotplugSupport = config.sane.hotplugSupport or true;
    libusb = libusb1;
  };

  saneBackendsGit = callPackage ../applications/graphics/sane/backends-git.nix {
    gt68xxFirmware = config.sane.gt68xxFirmware or null;
    snapscanFirmware = config.sane.snapscanFirmware or null;
    hotplugSupport = config.sane.hotplugSupport or true;
  };

  mkSaneConfig = callPackage ../applications/graphics/sane/config.nix { };

  saneFrontends = callPackage ../applications/graphics/sane/frontends.nix { };

  sourceAndTags = import ../misc/source-and-tags {
    inherit pkgs stdenv unzip lib ctags;
    hasktags = haskellPackages.hasktags;
  };

  tetex = callPackage ../tools/typesetting/tex/tetex { libpng = libpng12; };

  texFunctions = import ../tools/typesetting/tex/nix pkgs;

  texLive = builderDefsPackage (import ../tools/typesetting/tex/texlive) {
    inherit builderDefs zlib bzip2 ncurses libpng ed lesstif ruby potrace
      gd t1lib freetype icu perl expat curl xz pkgconfig zziplib texinfo
      libjpeg bison python fontconfig flex poppler libpaper graphite2
      makeWrapper;
    inherit (xlibs) libXaw libX11 xproto libXt libXpm
      libXmu libXext xextproto libSM libICE;
    ghostscript = ghostscriptX;
    harfbuzz = harfbuzz.override {
      withIcu = true; withGraphite2 = true;
    };
  };

  texLiveFull = lib.setName "texlive-full" (texLiveAggregationFun {
    paths = [ texLive texLiveExtra lmodern texLiveCMSuper texLiveLatexXColor
              texLivePGF texLiveBeamer texLiveModerncv tipa tex4ht texinfo
              texLiveModerntimeline ];
  });

  /* Look in configurations/misc/raskin.nix for usage example (around revisions
  where TeXLive was added)

  (texLiveAggregationFun {
    paths = [texLive texLiveExtra texLiveCMSuper
      texLiveBeamer
    ];
  })

  You need to use texLiveAggregationFun to regenerate, say, ls-R (TeX-related file list)
  Just installing a few packages doesn't work.
  */
  texLiveAggregationFun = params:
    builderDefsPackage (import ../tools/typesetting/tex/texlive/aggregate.nix)
      ({inherit poppler perl makeWrapper;} // params);

  texDisser = callPackage ../tools/typesetting/tex/disser {};

  texLiveContext = builderDefsPackage (import ../tools/typesetting/tex/texlive/context.nix) {
    inherit texLive;
  };

  texLiveExtra = builderDefsPackage (import ../tools/typesetting/tex/texlive/extra.nix) {
    inherit texLive xz;
  };

  texLiveCMSuper = builderDefsPackage (import ../tools/typesetting/tex/texlive/cm-super.nix) {
    inherit texLive;
  };

  texLiveLatexXColor = builderDefsPackage (import ../tools/typesetting/tex/texlive/xcolor.nix) {
    inherit texLive;
  };

  texLivePGF = builderDefsPackage (import ../tools/typesetting/tex/texlive/pgf.nix) {
    inherit texLiveLatexXColor texLive;
  };

  texLiveBeamer = builderDefsPackage (import ../tools/typesetting/tex/texlive/beamer.nix) {
    inherit texLiveLatexXColor texLivePGF texLive;
  };

  texLiveModerncv = builderDefsPackage (import ../tools/typesetting/tex/texlive/moderncv.nix) {
    inherit texLive unzip;
  };

  texLiveModerntimeline = builderDefsPackage (import ../tools/typesetting/tex/texlive/moderntimeline.nix) {
    inherit texLive unzip;
  };

  vice = callPackage ../misc/emulators/vice {
    libX11 = xlibs.libX11;
    giflib = giflib_4_1;
  };

  vimPlugins = recurseIntoAttrs (callPackage ../misc/vim-plugins { });

  vimprobable2 = callPackage ../applications/networking/browsers/vimprobable2 {
    webkit = webkitgtk2;
  };

  vimprobable2Wrapper = wrapFirefox
    { browser = vimprobable2; browserName = "vimprobable2"; desktopName = "Vimprobable2";
    };

  vimb = callPackage ../applications/networking/browsers/vimb {
    webkit = webkitgtk2;
  };

  vimbWrapper = wrapFirefox {
    browser = vimb;
    browserName = "vimb";
    desktopName = "Vimb";
  };

  # Wine cannot be built in 64-bit; use a 32-bit build instead.
  wineStable = callPackage_i686 ../misc/emulators/wine/stable.nix {
    bison = bison2;
  };

  wineUnstable = lowPrio (callPackage_i686 ../misc/emulators/wine/unstable.nix {
    bison = bison2;
  });

  wine = wineStable;

  winetricks = callPackage ../misc/emulators/wine/winetricks.nix {
    inherit (gnome2) zenity;
  };

  xsane = callPackage ../applications/graphics/sane/xsane.nix {
    libpng = libpng12;
    saneBackends = saneBackends;
  };

  myEnvFun = import ../misc/my-env {
    inherit substituteAll pkgs;
    inherit (stdenv) mkDerivation;
  };

  # patoline requires a rather large ocaml compilation environment.
  # this is why it is build as an environment and not just a normal package.
  # remark : the emacs mode is also installed, but you have to adjust your load-path.
  PatolineEnv = pack: myEnvFun {
      name = "patoline";
      buildInputs = [ stdenv ncurses mesa freeglut libzip gcc
                                   pack.ocaml pack.findlib pack.camomile
                                   pack.dypgen pack.ocaml_sqlite3 pack.camlzip
                                   pack.lablgtk pack.camlimages pack.ocaml_cairo
                                   pack.lablgl pack.ocamlnet pack.cryptokit
                                   pack.ocaml_pcre pack.patoline
                                   ];
    # this is to circumvent the bug with libgcc_s.so.1 which is
    # not found when using thread
    extraCmds = ''
       LD_LIBRARY_PATH=\$LD_LIBRARY_PATH:${gcc.gcc}/lib
       export LD_LIBRARY_PATH
    '';
  };

  patoline = PatolineEnv ocamlPackages_4_00_1;

  zncModules = recurseIntoAttrs (
    callPackage ../applications/networking/znc/modules.nix { }
  );

  zsnes = callPackage_i686 ../misc/emulators/zsnes { };

  misc = import ../misc/misc.nix { inherit pkgs stdenv; };


  # Attributes for backward compatibility.
  adobeReader = adobe-reader;
  asciidocFull = asciidoc-full;  # added 2014-06-22


}; in self; in pkgs
