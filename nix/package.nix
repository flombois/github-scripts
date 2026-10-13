# The ghs command, with every tool it calls on its PATH.
{
  lib,
  stdenvNoCC,
  makeWrapper,
  installShellFiles,
  bash,
  coreutils,
  gh,
  jq,
  glow,
  gum,
  fzf,
  less,
  util-linux,
  ncurses,
  git,
  xdg-utils,
}:

stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "github-scripts";
  version = "0.1.0";

  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../cli.sh
      ../bin
      ../lib
    ];
  };

  strictDeps = true;
  nativeBuildInputs = [
    makeWrapper
    installShellFiles
  ];
  buildInputs = [ bash ];
  dontBuild = true;

  # Every command ghs shells out to. gh, jq and bash are required; glow, gum and fzf are the
  # optional three, always present here so -i and the Markdown rendering just work.
  runtimeInputs = [
    gh
    jq
    glow
    gum
    fzf
    less
    util-linux # column
    ncurses # tput
    coreutils # realpath, stty, date, mktemp
    git
    xdg-utils # xdg-open, for ctrl-o in the browse
  ];

  installPhase = ''
    runHook preInstall

    install -d "$out/share/github-scripts"
    cp -r cli.sh bin lib "$out/share/github-scripts/"
    chmod +x "$out/share/github-scripts/cli.sh" \
      "$out/share/github-scripts"/bin/*.sh \
      "$out/share/github-scripts"/bin/settings/*.sh

    # cli.sh finds bin/ and lib/ next to itself, so both names can be symlinks beside it. The
    # link's name is the one the wrapper runs, and so the one $0 and the usage text show.
    for name in github-scripts ghs; do
      ln -s cli.sh "$out/share/github-scripts/$name"
      makeWrapper "$out/share/github-scripts/$name" "$out/bin/$name" \
        --prefix PATH : ${lib.makeBinPath finalAttrs.runtimeInputs}
    done

    runHook postInstall
  '';

  # bin/completion.sh prints the bash completion; zsh loads the same script through bashcompinit.
  postInstall = ''
    bash bin/completion.sh bash > ghs.bash
    installShellCompletion --bash --name ghs ghs.bash
  '';

  meta = {
    description = "Terminal reports for GitHub repositories, built on the gh CLI";
    homepage = "https://github.com/flombois/github-scripts";
    mainProgram = "ghs";
    platforms = lib.platforms.unix;
  };
})
