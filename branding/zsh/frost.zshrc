# FROST zsh aliases & prompt — installed to /etc/frost/frost.zshrc,
# sourced from /etc/zsh/zshrc (system-wide, opt-in: only affects users
# who actually run zsh). See BRANDING.README.md to make it your shell.

# ---- colors on by default ----
autoload -Uz colors && colors
export CLICOLOR=1
export LS_COLORS="di=1;36:ln=1;35:ex=1;32"

# ---- prompt: cyan user@frost, blue cwd, icy ❄ marker ----
setopt PROMPT_SUBST
PROMPT='%F{cyan}%n@frost%f %F{blue}%~%f %F{white}❄%f '

# ---- core shortcuts ----
alias ll='ls -lah --color=auto'
alias la='ls -A --color=auto'
alias ..='cd ..'
alias ...='cd ../..'
alias c='clear'

# ---- git (oh-my-zsh-compatible names, so muscle memory transfers) ----
alias gst='git status'
alias ga='git add'
alias gaa='git add --all'
alias gc='git commit -v'
alias gcmsg='git commit --message'
alias gco='git checkout'
alias gcb='git checkout -b'
alias gcm='git checkout main'
alias gcd='git checkout dev'
alias gd='git diff'
alias gl='git log --oneline --graph --decorate'
alias gp='git push'
alias gpl='git pull'

# ---- docker ----
alias dco='docker compose'
alias dps='docker ps'
alias dlog='docker logs -f'

# ---- FROST itself ----
alias frost-status='frost status'
alias frost-update='frost update'

# frost-check: a friendlier wrapper around `frost doctor`, not just a
# bare alias — worth the extra line for the emoji + non-zero-exit hint.
frost-check() {
    echo "❄  Running FROST diagnostics..."
    if frost doctor; then
        echo "✅  All good."
    else
        echo "⚠️   Something needs attention — see above."
        return 1
    fi
}

# ---- editor ----
export EDITOR=nvim
export VISUAL=nvim
