# SUCCESS
# *INFO* Generating Bash script for testing for GHC versions: 8.0.2 8.2.2 8.4.4 8.6.5 8.8.4 8.10.3
#!/bin/bash
# shellcheck disable=SC2086,SC2016,SC2046
# REGENDATA ["--matrix-extra=abc:1,2,3","--matrix-extra=foo:bar,baz","bash","matrix-extra.project"]

set -o pipefail

# Mode
##############################################################################

if [ "$1" = "indocker" ]; then
    INDOCKER=true
    shift
else
    INDOCKER=false
fi

# Run configuration
##############################################################################

CFG_CABAL_STORE_CACHE=""
CFG_CABAL_REPO_CACHE=""
CFG_JOBS="8.10.3 8.8.4 8.6.5 8.4.4 8.2.2 8.0.2"
CFG_CABAL_UPDATE=false

SCRIPT_NAME=$(basename "$0")
START_TIME="$(date +'%s')"

XDG_CONFIG_HOME=${XDG_CONFIG_HOME:-$HOME/.config}

# Job configuration
##############################################################################

GHC_VERSION="non-existing"
CABAL_VERSION=3.2
HEADHACKAGE=false

# Locale
##############################################################################

export LC_ALL=C.UTF-8

# Utilities
##############################################################################

SGR_RED='\033[1;31m'
SGR_GREEN='\033[1;32m'
SGR_BLUE='\033[1;34m'
SGR_CYAN='\033[1;96m'
SGR_RESET='\033[0m' # No Color

put_info() {
    printf "$SGR_CYAN%s$SGR_RESET\n" "### $*"
}

put_error() {
    printf "$SGR_RED%s$SGR_RESET\n" "!!! $*"
}

run_cmd() {
    local PRETTYCMD="$*"
    local PROMPT
    if $INDOCKER; then
        PROMPT="$(pwd) >>>"
    else
        PROMPT=">>>"
    fi

    printf "$SGR_BLUE%s %s$SGR_RESET\n" "$PROMPT" "$PRETTYCMD"

    local start_time end_time cmd_duration total_duration
    start_time=$(date +'%s')

    "$@"
    local RET=$?

    end_time=$(date +'%s')
    cmd_duration=$((end_time - start_time))
    total_duration=$((end_time - START_TIME))

    cmd_min=$((cmd_duration / 60))
    cmd_sec=$((cmd_duration % 60))

    total_min=$((total_duration / 60))
    total_sec=$((total_duration % 60))

    if [ $RET -eq 0 ]; then
        printf "$SGR_GREEN%s$SGR_RESET (%dm%02ds; %dm%02ds)\n" "<<< $PRETTYCMD" "$cmd_min" "$cmd_sec" "$total_min" "$total_sec"
    else
        printf "$SGR_RED%s$SGR_RESET\n" "!!! $PRETTYCMD"
        exit 1
    fi
}

run_cmd_if() {
    local COND=$1
    shift

    if [ $COND -eq 1 ]; then
        run_cmd "$@"
    else
        local PRETTYCMD="$*"
        local PROMPT
        PROMPT="$(pwd) (skipping) >>>"

        printf "$SGR_BLUE%s %s$SGR_RESET\n" "$PROMPT" "$PRETTYCMD"
    fi
}

run_cmd_unchecked() {
    local PRETTYCMD="$*"
    local PROMPT
    if $INDOCKER; then
        PROMPT="$(pwd) >>>"
    else
        PROMPT=">>>"
    fi

    printf "$SGR_BLUE%s %s$SGR_RESET\n" "$PROMPT" "$PRETTYCMD"

    local start_time end_time cmd_duration total_duration cmd_min cmd_sec total_min total_sec
    start_time=$(date +'%s')

    "$@"

    end_time=$(date +'%s')
    cmd_duration=$((end_time - start_time))
    total_duration=$((end_time - START_TIME))

    cmd_min=$((cmd_duration / 60))
    cmd_sec=$((cmd_duration % 60))

    total_min=$((total_duration / 60))
    total_sec=$((total_duration % 60))

    printf "$SGR_GREEN%s$SGR_RESET (%dm%02ds; %dm%02ds)\n" "<<< $PRETTYCMD" "$cmd_min" "$cmd_sec" "$total_min" "$total_sec"
}

change_dir() {
    local DIR=$1
    if [ -d "$DIR" ]; then
        printf "$SGR_BLUE%s$SGR_RESET\n" "change directory to $DIR"
        cd "$DIR" || exit 1
    else
        printf "$SGR_RED%s$SGR_RESET\n" "!!! cd $DIR"
        exit 1
    fi
}

change_dir_if() {
    local COND=$1
    local DIR=$2

    if [ $COND -ne 0 ]; then
        change_dir "$DIR"
    fi
}

echo_to() {
    local DEST=$1
    local CONTENTS=$2

    echo "$CONTENTS" >> "$DEST"
}

echo_if_to() {
    local COND=$1
    local DEST=$2
    local CONTENTS=$3

    if [ $COND -ne 0 ]; then
        echo_to "$DEST" "$CONTENTS"
    fi
}

install_cabalplan() {
    put_info "installing cabal-plan"

    if [ ! -e $CABAL_REPOCACHE/downloads/cabal-plan ]; then
        curl -L https://github.com/haskell-hvr/cabal-plan/releases/download/v0.6.2.0/cabal-plan-0.6.2.0-x86_64-linux.xz > /tmp/cabal-plan.xz || exit 1
        (cd /tmp && echo "de73600b1836d3f55e32d80385acc055fd97f60eaa0ab68a755302685f5d81bc  cabal-plan.xz" | sha256sum -c -)|| exit 1
        mkdir -p $CABAL_REPOCACHE/downloads
        xz -d < /tmp/cabal-plan.xz > $CABAL_REPOCACHE/downloads/cabal-plan || exit 1
        chmod a+x $CABAL_REPOCACHE/downloads/cabal-plan || exit 1
    fi

    mkdir -p $CABAL_DIR/bin || exit 1
    ln -s $CABAL_REPOCACHE/downloads/cabal-plan $CABAL_DIR/bin/cabal-plan || exit 1
}

# Help
##############################################################################

show_usage() {
cat <<EOF
./haskell-ci.sh - build & test

Usage: ./haskell-ci.sh [options]
  A script to run automated checks locally (using Docker)

Available options:
  --jobs JOBS               Jobs to run (default: $CFG_JOBS)
  --cabal-store-cache PATH  Directory to use for cabal-store-cache
  --cabal-repo-cache PATH   Directory to use for cabal-repo-cache
  --skip-cabal-update       Skip cabal update (useful with --cabal-repo-cache)
  --no-skip-cabal-update
  --help                    Print this message

EOF
}

# getopt
#######################################################################

process_cli_options() {
    while [ $# -gt 0 ]; do
        arg=$1
        case $arg in
            --help)
                show_usage
                exit
                ;;
            --jobs)
                CFG_JOBS=$2
                shift
                shift
                ;;
            --cabal-store-cache)
                CFG_CABAL_STORE_CACHE=$2
                shift
                shift
                ;;
            --cabal-repo-cache)
                CFG_CABAL_REPO_CACHE=$2
                shift
                shift
                ;;
            --skip-cabal-update)
                CFG_CABAL_UPDATE=false
                shift
                ;;
            --no-skip-cabal-update)
                CFG_CABAL_UPDATE=true
                shift
                ;;
            *)
                echo "Unknown option $arg"
                exit 1
        esac
    done
}

process_indocker_options () {
    while [ $# -gt 0 ]; do
        arg=$1

        case $arg in
            --ghc-version)
                GHC_VERSION=$2
                shift
                shift
                ;;
            --cabal-version)
                CABAL_VERSION=$2
                shift
                shift
                ;;
            --start-time)
                START_TIME=$2
                shift
                shift
                ;;
            --cabal-update)
                CABAL_UPDATE=$2
                shift
                shift
                ;;
            *)
                echo "Unknown option $arg"
                exit 1
        esac
    done
}

if $INDOCKER; then
    process_indocker_options "$@"

else
    if [ -f "$XDG_CONFIG_HOME/haskell-ci/bash.config" ]; then
        process_cli_options $(cat "$XDG_CONFIG_HOME/haskell-ci/bash.config")
    fi

    process_cli_options "$@"

    put_info "jobs:              $CFG_JOBS"
    put_info "cabal-store-cache: $CFG_CABAL_STORE_CACHE"
    put_info "cabal-repo-cache:  $CFG_CABAL_REPO_CACHE"
    put_info "cabal-update:      $CFG_CABAL_UPDATE"
fi

# Constants
##############################################################################

SRCDIR=/hsci/src
BUILDDIR=/hsci/build
CABAL_DIR="$BUILDDIR/cabal"
CABAL_REPOCACHE=/hsci/cabal-repocache
CABAL_STOREDIR=/hsci/store

# Docker invoke
##############################################################################

# if cache directory is specified, use it.
# Otherwise use another tmpfs host
if [ -z "$CFG_CABAL_STORE_CACHE" ]; then
    CABALSTOREARG="--tmpfs $CABAL_STOREDIR:exec"
else
    CABALSTOREARG="--volume $CFG_CABAL_STORE_CACHE:$CABAL_STOREDIR"
fi

if [ -z "$CFG_CABAL_REPO_CACHE" ]; then
    CABALREPOARG="--tmpfs $CABAL_REPOCACHE:exec"
else
    CABALREPOARG="--volume $CFG_CABAL_REPO_CACHE:$CABAL_REPOCACHE"
fi

echo_docker_cmd() {
    local GHCVER=$1

    # TODO: mount /hsci/src:ro (readonly)
    echo docker run \
        --tty \
        --interactive \
        --rm \
        --label haskell-ci \
        --volume "$(pwd):/hsci/src" \
        $CABALSTOREARG \
        $CABALREPOARG \
        --tmpfs /tmp:exec \
        --tmpfs /hsci/build:exec \
        --workdir /hsci/build \
        "phadej/ghc:$GHCVER-bionic" \
        "/bin/bash" "/hsci/src/$SCRIPT_NAME" indocker \
        --ghc-version "$GHCVER" \
        --cabal-update "$CFG_CABAL_UPDATE" \
        --start-time "$START_TIME"
}

# if we are not in docker, loop through jobs
if ! $INDOCKER; then
    for JOB in $CFG_JOBS; do
        put_info "Running in docker: $JOB"
        run_cmd $(echo_docker_cmd "$JOB")
    done

    run_cmd echo "ALL OK"
    exit 0
fi

# Otherwise we are in docker, and the rest of script executes
put_info "In docker"

# Environment
##############################################################################

GHCDIR=/opt/ghc/$GHC_VERSION

HC=$GHCDIR/bin/ghc
HCPKG=$GHCDIR/bin/ghc-pkg
HADDOCK=$GHCDIR/bin/haddock

CABAL=/opt/cabal/$CABAL_VERSION/bin/cabal

CABAL="$CABAL -vnormal+nowrap"

export CABAL_DIR
export CABAL_CONFIG="$BUILDDIR/cabal/config"

PATH="$CABAL_DIR/bin:$PATH"

# HCNUMVER
HCNUMVER=$(${HC} --numeric-version|perl -ne '/^(\d+)\.(\d+)\.(\d+)(\.(\d+))?$/; print(10000 * $1 + 100 * $2 + ($3 == 0 ? $5 != 1 : $3))')
GHCJSARITH=0

put_info "HCNUMVER: $HCNUMVER"

# Args for shorter/nicer commands
if [ 1 -ne 0 ] ; then ARG_TESTS=--enable-tests; else ARG_TESTS=--disable-tests; fi
if [ 1 -ne 0 ] ; then ARG_BENCH=--enable-benchmarks; else ARG_BENCH=--disable-benchmarks; fi
ARG_COMPILER="--ghc --with-compiler=$HC"

put_info "tests/benchmarks: $ARG_TESTS $ARG_BENCH"

# Apt dependencies
##############################################################################


# Cabal config
##############################################################################

mkdir -p $BUILDDIR/cabal

cat > $BUILDDIR/cabal/config <<EOF
remote-build-reporting: anonymous
write-ghc-environment-files: always
remote-repo-cache: $CABAL_REPOCACHE
logs-dir:          $CABAL_DIR/logs
world-file:        $CABAL_DIR/world
extra-prog-path:   $CABAL_DIR/bin
symlink-bindir:    $CABAL_DIR/bin
installdir:        $CABAL_DIR/bin
build-summary:     $CABAL_DIR/logs/build.log
store-dir:         $CABAL_STOREDIR
install-dirs user
  prefix: $CABAL_DIR
repository hackage.haskell.org
  url: http://hackage.haskell.org/
EOF

if $HEADHACKAGE; then
    put_error "head.hackage is not implemented"
    exit 1
fi

run_cmd cat "$BUILDDIR/cabal/config"

# Version
##############################################################################

put_info "Versions"
run_cmd $HC --version
run_cmd_unchecked $HC --print-project-git-commit-id
run_cmd $CABAL --version

# Build script
##############################################################################

# update cabal index
if $CABAL_UPDATE; then
    put_info "Updating Hackage index"
    run_cmd $CABAL v2-update -v
fi

# install cabal-plan
install_cabalplan
run_cmd cabal-plan --version

# initial cabal.project for sdist
put_info "initial cabal.project for sdist"
change_dir "$BUILDDIR"
run_cmd touch cabal.project
echo_to cabal.project "packages: $SRCDIR/notmuch"
run_cmd cat cabal.project

# sdist
put_info "sdist"
run_cmd mkdir -p "$BUILDDIR/sdist"
run_cmd $CABAL sdist all --output-dir "$BUILDDIR/sdist"

# unpack
put_info "unpack"
change_dir "$BUILDDIR"
run_cmd mkdir -p "$BUILDDIR/unpacked"
run_cmd find "$BUILDDIR/sdist" -maxdepth 1 -type f -name '*.tar.gz' -exec tar -C "$BUILDDIR/unpacked" -xzvf {} \;

# generate cabal.project
put_info "generate cabal.project"
PKGDIR_notmuch="$(find "$BUILDDIR/unpacked" -maxdepth 1 -type d -regex '.*/notmuch-[0-9.]*')"
run_cmd touch cabal.project
run_cmd touch cabal.project.local
echo_to cabal.project "packages: ${PKGDIR_notmuch}"
echo_if_to $((HCNUMVER >= 80200)) cabal.project "package notmuch"
echo_if_to $((HCNUMVER >= 80200)) cabal.project "    ghc-options: -Werror=missing-methods"
cat >> cabal.project <<EOF
EOF
$HCPKG list --simple-output --names-only | perl -ne 'for (split /\s+/) { print "constraints: $_ installed\n" unless /^(notmuch)$/; }' >> cabal.project.local
run_cmd cat cabal.project
run_cmd cat cabal.project.local

# dump install plan
put_info "dump install plan"
run_cmd $CABAL v2-build $ARG_COMPILER $ARG_TESTS $ARG_BENCH --dry-run all
run_cmd cabal-plan

# install dependencies
put_info "install dependencies"
run_cmd $CABAL v2-build $ARG_COMPILER --disable-tests --disable-benchmarks --dependencies-only -j all
run_cmd $CABAL v2-build $ARG_COMPILER $ARG_TESTS $ARG_BENCH --dependencies-only -j all

# build w/o tests
put_info "build w/o tests"
run_cmd $CABAL v2-build $ARG_COMPILER --disable-tests --disable-benchmarks all

# build
put_info "build"
run_cmd $CABAL v2-build $ARG_COMPILER $ARG_TESTS $ARG_BENCH all

# tests
put_info "tests"

# cabal check
put_info "cabal check"
change_dir "${PKGDIR_notmuch}"
run_cmd ${CABAL} -vnormal check
change_dir "$BUILDDIR"

# haddock
put_info "haddock"
run_cmd $CABAL v2-haddock $ARG_COMPILER --with-haddock $HADDOCK $ARG_TESTS $ARG_BENCH all

# unconstrained build
put_info "unconstrained build"
run_cmd rm -f cabal.project.local
run_cmd $CABAL v2-build $ARG_COMPILER --disable-tests --disable-benchmarks all


# Done
run_cmd echo OK
