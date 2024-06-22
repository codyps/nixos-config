# ex: ft=sh
#FPATH="/opt/local/share/zsh/site-functions:$FPATH"
PS1="%n@%m %1~ %# "

# use emacs keybinds even though I set EDITOR/VISUAL to vi
bindkey -e
bindkey "^[[3~" delete-char
bindkey "^[[H"  beginning-of-line
bindkey "^[[F"  end-of-line

# tmux interpretation of xterm-kitty
bindkey "^[[1~" beginning-of-line
bindkey "^[[4~" end-of-line

setopt EXTENDED_HISTORY
setopt HIST_EXPIRE_DUPS_FIRST
setopt HIST_FIND_NO_DUPS
setopt HIST_SAVE_NO_DUPS
setopt INC_APPEND_HISTORY_TIME
unsetopt SHARE_HISTORY

# zsh doesn't like `-1` here
# FIXME: we really should make it so up-arrow works with a new shell when using sqlite-history.zsh
HISTFILE=${ZDOTDIR:-$HOME}/.zsh_history

source ~/.profile
alias ls='ls --color'

[ -f "/etc/zshrc_Apple_Terminal" ] && . /etc/zshrc_Apple_Terminal
