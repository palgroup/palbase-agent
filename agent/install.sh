#!/bin/sh
# The engine device agent installer.
#
#   curl -fsSL https://<host>/install.sh | sh
#   AI_ENGINE_VERSION=1.4.2 curl -fsSL https://<host>/install.sh | sh     # pinned, for an image bake
#
# IT INSTALLS THE BINARY AND NOTHING ELSE. It does not enrol, does not ask for a key, does not write or
# load a service. Those belong to `palbase-agent enroll`, and keeping them apart is what lets a machine image be
# baked with no secret in it and enrolled later from provider user-data. An installer that also enrolled
# would force every image to carry a credential.
#
# THE WHOLE SCRIPT IS ONE FUNCTION, INVOKED ON THE LAST LINE. A `curl | sh` whose download is truncated
# mid-flight otherwise executes the half that arrived — a real failure mode on a flaky network, and the
# reason `main "$@"` is the final statement rather than a stylistic choice. Everything above it only
# defines functions, so a truncated copy defines some of them and runs none.
#
# THE CHECKSUM DOES NOT COME FROM THE ARCHIVE. The manifest is fetched as its own request and the
# archive is refused on mismatch. A digest served beside the file it protects, by the same credential
# that served the file, protects nothing: whoever can replace one can replace both.
#
# NO PROMPTS AND NO ELEVATION. A provisioner is not a person. If the install prefix is not writable the
# script says which directory and exits non-zero rather than reaching for sudo, and `palbase-agent enroll` after it needs
# none either.
set -eu

# ‼️ THE DEFAULT IS WHERE THE AGENT IS ACTUALLY PUBLISHED, AND IT USED TO NAME A HOST THAT DOES NOT
# EXIST. `releases.palai.dev` is NXDOMAIN: the documented one-liner — curl this script and pipe it to
# sh — died with "cannot fetch https://releases.palai.dev/latest.txt" on the first Mac that ran it, and
# the only way through was an environment variable nobody reading the fleet instructions would know to
# set. A fleet whose install command needs a second, undocumented argument is not a one-command install.
# The channel is get.palbase.studio/agent (palgroup/palbase-agent's Pages, .github/scripts/publish-agent.sh); the old
# address, palgroup.github.io/palai, answers with a shim that installs from here.
PALBASE_AI_INSTALL_BASE_URL="${PALBASE_AI_INSTALL_BASE_URL:-https://get.palbase.studio/agent}"
PALBASE_AI_INSTALL_PREFIX="${PALBASE_AI_INSTALL_PREFIX:-$HOME/.local/bin}"
AI_ENGINE_VERSION="${AI_ENGINE_VERSION:-latest}"

log()  { printf 'palbase-install: %s\n' "$*" >&2; }
die()  { printf 'palbase-install: %s\n' "$*" >&2; exit 1; }

# need_cmd names the missing tool rather than failing inside a pipeline, where `set -e` would report a
# broken pipe and send the reader looking at the wrong thing.
need_cmd() {
	command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

# detect_triple refuses an unsupported platform BY NAME. Installing a binary that cannot exec produces
# "cannot execute binary file" three steps later, on a machine nobody is logged into.
detect_triple() {
	os_raw="$(uname -s)"
	arch_raw="$(uname -m)"
	case "$os_raw" in
		Darwin) os=darwin ;;
		Linux)  os=linux ;;
		*)      die "unsupported operating system: $os_raw (supported: Darwin, Linux)" ;;
	esac
	case "$arch_raw" in
		arm64|aarch64) arch=arm64 ;;
		x86_64|amd64)  arch=amd64 ;;
		*)             die "unsupported architecture: $arch_raw (supported: arm64, amd64)" ;;
	esac
	printf '%s-%s' "$os" "$arch"
}

fetch() {
	# -f so a 404 is an error rather than an HTML page written to disk, which would then fail the digest
	# check with a message about corruption when the truth is "that version does not exist".
	curl -fsSL "$1" -o "$2" || die "cannot fetch $1"
}

# resolve_version turns "latest" into a concrete version, so what is installed can be REPORTED. A fleet
# of a hundred machines has to be answerable about what it runs without logging into any of them.
resolve_version() {
	if [ "$AI_ENGINE_VERSION" != "latest" ]; then
		printf '%s' "$AI_ENGINE_VERSION"
		return
	fi
	fetch "$PALBASE_AI_INSTALL_BASE_URL/latest.txt" "$work/latest.txt"
	v="$(tr -d ' \t\r\n' < "$work/latest.txt")"
	[ -n "$v" ] || die "the latest-version document is empty at $PALBASE_AI_INSTALL_BASE_URL/latest.txt"
	printf '%s' "$v"
}

verify_digest() {
	archive="$1"
	name="$2"
	manifest="$3"
	# The manifest holds "<sha256>  <filename>" lines for every artifact of this release. Select the line
	# by EXACT filename: a substring match would accept the darwin-arm64 digest for a linux-amd64 archive
	# whenever one name is a prefix of the other.
	want="$(awk -v f="$name" '$2 == f { print $1 }' "$manifest")"
	[ -n "$want" ] || die "the checksum manifest names no artifact called $name"
	if command -v sha256sum >/dev/null 2>&1; then
		got="$(sha256sum "$archive" | awk '{print $1}')"
	elif command -v shasum >/dev/null 2>&1; then
		got="$(shasum -a 256 "$archive" | awk '{print $1}')"
	else
		die "required command not found: sha256sum or shasum"
	fi
	[ "$want" = "$got" ] || die "checksum mismatch for $name: manifest says $want, download is $got — refusing to install"
	printf '%s' "$got"
}

# install_binary writes beside the target and renames, so an interrupted install cannot leave a partial
# executable at the name a service manager is about to exec.
install_binary() {
	src="$1"
	dest="$2"
	dir="$(dirname "$dest")"
	mkdir -p "$dir" 2>/dev/null || die "cannot create $dir"
	[ -w "$dir" ] || die "$dir is not writable by $(id -un) — choose another PALBASE_AI_INSTALL_PREFIX; this installer does not elevate"
	tmp="$dest.incoming.$$"
	cp "$src" "$tmp" || die "cannot write $tmp"
	chmod 0755 "$tmp"
	mv -f "$tmp" "$dest" || die "cannot install $dest"
}

main() {
	need_cmd curl
	need_cmd tar
	need_cmd awk
	need_cmd uname

	triple="$(detect_triple)"
	work="$(mktemp -d)"
	# shellcheck disable=SC2064
	trap "rm -rf '$work'" EXIT INT TERM

	version="$(resolve_version)"
	name="palbase-agent-${version}-${triple}.tar.gz"
	base="$PALBASE_AI_INSTALL_BASE_URL/$version"

	log "installing palbase-agent $version ($triple) from $base"
	fetch "$base/$name" "$work/$name"
	# Separate request, separate document — see the header.
	fetch "$base/checksums.txt" "$work/checksums.txt"
	digest="$(verify_digest "$work/$name" "$name" "$work/checksums.txt")"

	tar -xzf "$work/$name" -C "$work" || die "cannot extract $name"
	[ -f "$work/palbase-agent" ] || die "$name does not contain a palbase-agent binary"

	# THE ACCOUNT DAEMON TRAVELS WITH THE AGENT, and placing the FILE is not installing a service.
	# `palbase-agent enroll` needs it beside this binary — it looks exactly there — and enrolment is the one
	# privileged step, the one that writes the LaunchDaemon and loads it. This script still writes no
	# service, loads nothing, and asks for no privilege: it drops a payload into the same directory it
	# just wrote the agent to.
	#
	# It did NOT, until 2026-08-07, and that made a clean install unable to finish: enrolment found no
	# daemon beside the binary and told the operator to extract one from the tarball by hand — a manual
	# step on a machine that is provisioned unattended and that nobody logs into.
	# ‼️ palbase-toolshim WAS INSTALLED HERE AND IS NOT BUILT ANY MORE (2026-09-18). It was what a
	# confined session found on its PATH under a tool's own name, carrying the invocation to a broker
	# outside the sandbox; a Mac session runs inside a guest now, where the toolchain is simply present,
	# and the broker is deleted. The `if [ -f ]` this block used is why nothing had to be coordinated:
	# an archive without the member is unpacked without complaint.
	#
	# A machine PROVISIONED BY AN EARLIER RELEASE still has the binary in this prefix. It is left alone
	# rather than removed — an installer that deletes files it did not write this run is an installer that
	# can take out a file an operator put there — and nothing executes it: the executor that set
	# AI_ENGINE_TOOL_BROKER went with the broker, so it is an unreachable 2 MB, not a live seam.
	# ‼️ AND THE ENGINE, WHICH IS THE PROGRAM A SESSION ACTUALLY RUNS. The engine is a binary in this
	# same archive rather than a container image the machine pulls, so a machine that
	# installed the agent without it enrols, takes work, and fails at the first model step with nothing
	# to start and no container runtime to fall back to. Same prefix, same terms: placing a file needs
	# no privilege.
	if [ -f "$work/palbase-session-engine" ]; then
		install_binary "$work/palbase-session-engine" "$PALBASE_AI_INSTALL_PREFIX/palbase-session-engine"
	fi
	# AND THE SESSION WORKER, ON THE SAME TERMS AND FOR A SHARPER REASON. The daemon mints the uid; the
	# worker is the process that IS it. Without this member enrolment installs a daemon whose accounts
	# are real and whose every shell command refuses — only uid 0 may become another uid, and the control
	# plane is the operator. Placing the file is still not installing a service: enrolment does that.
	if [ -f "$work/palbase-session-worker" ]; then
		install_binary "$work/palbase-session-worker" "$PALBASE_AI_INSTALL_PREFIX/palbase-session-worker"
	fi

	# ‼️ SET AFTER THE CALL ABOVE, AND THAT ORDER IS LOAD-BEARING. `install_binary` assigns `dest`
	# itself and sh has no locals, so a call made while this variable held the agent's path rewrote it
	# to the daemon's — and the agent then landed on the daemon's filename while the script reported
	# success. The release channel caught it in one run: "install.sh reported success but installed
	# nothing".
	dest="$PALBASE_AI_INSTALL_PREFIX/palbase-agent"
	# IDEMPOTENT: an identical binary already in place is reported and left alone, so a provisioner that
	# runs this on every boot does not churn the file a running service has open.
	if [ -x "$dest" ] && [ "$("$dest" --version 2>/dev/null || true)" = "$version" ]; then
		log "palbase-agent $version is already installed at $dest — nothing to do"
	else
		install_binary "$work/palbase-agent" "$dest"
	fi

	# Report what was installed. This is the line a fleet is audited from.
	printf 'palbase-agent %s installed\n  path:   %s\n  target: %s\n  sha256: %s\n' \
		"$version" "$dest" "$triple" "$digest"

	case ":$PATH:" in
		*":$PALBASE_AI_INSTALL_PREFIX:"*) ;;
		*) log "note: $PALBASE_AI_INSTALL_PREFIX is not on PATH" ;;
	esac

	log "next: palbase-agent enroll --url <controller> --key-file <path> --capacity <sessions at once, default 1>"
	log "      one command, no root: it enrols and installs the service that runs the agent (launchd on"
	log "      macOS, a systemd user unit on Linux). On macOS a machine's sessions are not isolated from each other."
}

main "$@"
