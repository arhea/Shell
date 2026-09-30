# Shell.app zsh bootstrap.
#
# Shell points ZDOTDIR here so it can load its integration into interactive
# shells without asking you to edit your dotfiles. This file restores your
# real ZDOTDIR first, so zsh goes on to read YOUR .zprofile/.zshrc/.zlogin
# exactly as it normally would.
#
# Everything is quoted/prefixed with `builtin` because this can run with
# aliases enabled.

if [[ -n "${SHELL_APP_ORIG_ZDOTDIR+X}" ]]; then
    'builtin' 'export' ZDOTDIR="$SHELL_APP_ORIG_ZDOTDIR"
    'builtin' 'unset' 'SHELL_APP_ORIG_ZDOTDIR'
else
    'builtin' 'unset' 'ZDOTDIR'
fi

{
    # Source the user's .zshenv first; it may set fpath and other things
    # the integrations depend on.
    'builtin' 'typeset' _shellapp_file=${ZDOTDIR-$HOME}"/.zshenv"
    [[ ! -r "$_shellapp_file" ]] || 'builtin' 'source' '--' "$_shellapp_file"
} always {
    if [[ -o 'interactive' ]]; then
        # Ghostty's integration: OSC 133 prompt marks (jump between commands),
        # sudo terminfo passthrough, window titles, and ssh TERM handling.
        if [[ -n "$GHOSTTY_RESOURCES_DIR" && -r "$GHOSTTY_RESOURCES_DIR/shell-integration/zsh/ghostty-integration" ]]; then
            'builtin' 'autoload' '-Uz' '--' "$GHOSTTY_RESOURCES_DIR/shell-integration/zsh/ghostty-integration"
            'ghostty-integration'
            'builtin' 'unfunction' '--' 'ghostty-integration'
        fi

        # Shell's own integration: input editor, completions, prompt state.
        _shellapp_file="${${(%):-%x}:A:h}/shell-integration.zsh"
        [[ ! -r "$_shellapp_file" ]] || 'builtin' 'source' '--' "$_shellapp_file"
    fi
    'builtin' 'unset' '_shellapp_file'
}
