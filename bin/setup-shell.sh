# bin/setup-shell.sh - source this at the start of every practice session:
#
#   source bin/setup-shell.sh
#
# Practicing with these shortcuts is part of the training. Typing
# `kubectl get pods --all-namespaces` by hand is how people run out of time.
#
# Deliberately no `set -e` and no `exit`: this is sourced into an interactive
# shell, and either one would close the user's terminal on a trivial error.

alias k='kubectl'
alias kg='kubectl get'
alias kgp='kubectl get pods'
alias kgd='kubectl get deploy'
alias kdp='kubectl describe pod'
alias kdel='kubectl delete'
alias kns='kubectl config set-context --current --namespace'

# Switch namespace: kn ckad-3-2   (no argument prints the current one)
kn() {
  if [[ -z "${1:-}" ]]; then
    kubectl config view --minify -o jsonpath='{..namespace}'; printf '\n'
  else
    kubectl config set-context --current --namespace="$1" >/dev/null \
      && printf 'namespace: %s\n' "$1"
  fi
}

# Generate a manifest without creating anything:  k run web --image=nginx $do
export do='--dry-run=client -o yaml'
# Delete without waiting:                         k delete pod web $now
export now='--force --grace-period=0'
# Shorthand for inspecting live objects:          k get deploy web $yd
export yd='-o yaml'

export KUBE_EDITOR='vim'

# Completion, including for the `k` alias.
if command -v kubectl >/dev/null 2>&1; then
  source <(kubectl completion bash) 2>/dev/null
  complete -o default -F __start_kubectl k 2>/dev/null
fi

# YAML-friendly vim, appended once. Editing YAML with default tabs loses more
# exam time than any missing alias.
if [[ -n "${HOME:-}" ]] && ! grep -q 'ckad-practice' "$HOME/.vimrc" 2>/dev/null; then
  cat >> "$HOME/.vimrc" <<'VIMEOF'
" ckad-practice: YAML editing defaults
set tabstop=2 shiftwidth=2 expandtab number
autocmd FileType yaml setlocal indentkeys-=0#
VIMEOF
  printf 'added YAML settings to %s/.vimrc\n' "$HOME"
fi

printf 'shell ready: k, kgp, kn, $do, $now, $yd\n'
