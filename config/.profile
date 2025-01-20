
case $OSTYPE in
	darwin*)
		ANDROID_HOME="$HOME/Library/Android/sdk"
		if [ -e "$ANDROID_HOME" ]; then
			export ANDROID_HOME
			export PATH="$ANDROID_HOME/tools:$ANDROID_HOME/platform-tools:$PATH"
			export ANDROID_NDK_ROOT="$ANDROID_HOME/ndk/$(ls "$ANDROID_HOME/ndk" | sort -V | tail -n1)"
		else
			unset ANDROID_HOME
		fi

		# macports
		export PATH="/opt/local/bin:/opt/local/sbin:$PATH"
		export XDG_CACHE_HOME="$HOME/Library/Caches"

		export PIP_USER=no

		case "$TERM" in
		alacritty)
			export TERM=xterm256-color
			bindkey "^[[3~" delete-char
			;;
		esac

		# default of 256 causes `nix build` for flakes to fail
		ulimit -n 10240
		;;
	*)
		[ -z "$DOCKER_HOST" ] && export DOCKER_HOST="unix:///run/user/$UID/docker.sock"
		[ -z "$XDG_CACHE_HOME" ] && export XDG_CACHE_HOME="$HOME/.cache"
		;;
esac

export IDF_TOOLS_PATH="$XDG_CACHE_HOME/espressif1"
export ESP_IDF_TOOLS_INSTALL_DIR="target"
export CCACHE_DIR="$XDG_CACHE_HOME/ccache"
export SCCACHE_CACHE_SIZE="40G"

if test "$SSH_CONNECTION"; then
	export PINENTRY_USER_DATA="USE_CURSES=1"
fi

if command -v systemctl >/dev/null; then
	VIRT_TYPE=$(systemctl show | awk 'BEGIN{FS="="} /^Virtualization=/{ print $2 }')
	case $VIRT_TYPE in
		oracle)
			# sway's hardware cursors are broken in virtualbox
			export WLR_NO_HARDWARE_CURSORS=1
			;;
	esac
fi

export PATH="$HOME/.local/zigprefix:$PATH"
#export PATH="$HOME/go/bin:$PATH"
export PATH="$HOME/riscv/bin:$PATH"
export PATH="$HOME/.gem/ruby/2.7.0/bin:$PATH"
export PATH="$HOME/d/depot_tools:$PATH"
# allow us to override what rancher desktop provides
export PATH="$PATH:$HOME/.rd/bin"

# FIXME: this can be _really_ slow, we need to generate/cache it instead. In particular: this hits macos's xcodebuild stuff.
#if command -v python >/dev/null; then
#	export PATH="$(python -m site --user-base)/bin:$PATH"
#fi
#if command -v python3 >/dev/null; then
#	export PATH="$(python3 -m site --user-base)/bin:$PATH"
#fi

export FZF_DEFAULT_COMMAND='rg --files'
export FZF_DEFAULT_OPTS='-m --height 50% --border'

export CLICOLOR=1

#export CLUTTER_PAINT=disable-clipped-redraws:disable-culling
#export CLUTTER_VBLANK=True

export GPG_TTY="$(tty)"

export MOZ_ENABLE_WAYLAND=1
export MOZ_USE_XINPUT2=1

export COMPOSE_DOCKER_CLI_BUILD=1
export DOCKER_BUILDKIT=1

alias vim=nvim
alias vi=nvim
alias k=kubectl
#alias cargo='targo wrap-cargo'

if [ -e "/Applications/Tailscale.app/Contents/MacOS/Tailscale" ]; then
	alias tailscale="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
fi

export EDITOR="nvim"
export RUSTC_WRAPPER="sccache"
#export CMAKE="cmake-ccache"
export PATH="$HOME/.local/bin:$PATH"
export PATH="$HOME/.local/bin/ccache.d:$PATH"

pdf-unencrypt () {
    : "Usage: <file>
Uses ghostscript to rewrite the file without encryption."
    local in="$1"
    gs -q -dNOPAUSE -dBATCH -sDEVICE=pdfwrite -sOutputFile="${in:r}_unencrypted.pdf" -c .setpdfwrite -f "$in"
}

if [ -e ~/.config/local/profile ]; then . ~/.config/local/profile; fi
