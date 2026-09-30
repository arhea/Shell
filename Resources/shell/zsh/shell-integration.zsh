# Shell.app — zsh integration.
#
# Reports prompt/command state to the app over a Unix socket and exposes zle
# widgets the app triggers with private key sequences:
#
#   ESC [ 9001 ~   run the command the app wrote to $SHELL_APP_RUNTIME/<id>.cmd
#   ESC [ 9002 ~   capture completions for the buffer in <id>.req
#   ESC [ 9003 ~   apply settings from <id>.cfg (e.g. prompt style)
#
# It also wraps `claude` so the app can open its native Claude Code view
# instead of the terminal UI (see _shellapp_claude).
#
# Setup is deferred to the first prompt so it runs after your .zshrc, themes
# and plugins. To load it in shells Shell didn't start (tmux, `exec zsh`):
#
#   [[ -n $SHELL_APP_RUNTIME ]] && source "${SHELL_APP_CTL:h:h}/shell/zsh/shell-integration.zsh"

_shellapp_boot() {
    builtin emulate -L zsh -o no_aliases
    [[ -o interactive ]] || builtin return 0
    (( ! $+_shellapp_booted )) || builtin return 0
    [[ -n $SHELL_APP_SESSION && -n $SHELL_APP_SOCKET ]] || builtin return 0
    builtin zmodload zsh/net/socket 2>/dev/null || builtin return 0
    builtin zmodload zsh/datetime 2>/dev/null
    builtin zmodload zsh/zselect 2>/dev/null

    builtin typeset -g _shellapp_booted=1
    builtin typeset -g _shellapp_sid=$SHELL_APP_SESSION
    builtin typeset -g _shellapp_sock=$SHELL_APP_SOCKET
    builtin typeset -g _shellapp_rt=$SHELL_APP_RUNTIME
    builtin typeset -g _shellapp_prompt_style=${SHELL_APP_PROMPT:-shell}
    builtin typeset -gi _shellapp_editor=${SHELL_APP_EDITOR:-0}
    builtin typeset -g _shellapp_claude_mode=${SHELL_APP_CLAUDE:-ask}
    builtin typeset -gi _shellapp_claude_rc=${SHELL_APP_CLAUDE_RC:-0}
    builtin typeset -g _shellapp_block_ps= _shellapp_block_rps=
    builtin typeset -g _shellapp_cmd_start=
    builtin typeset -g _shellapp_branch=
    builtin typeset -gi _shellapp_prompt_count=0
    builtin typeset -gi _shellapp_have_saved=0
    builtin typeset -g _shellapp_saved_ps1= _shellapp_saved_rps1=
    builtin typeset -g _shellapp_marker='%{%}%{%}%{%}'
    builtin typeset -ga _shellapp_out

    builtin typeset -ga precmd_functions
    precmd_functions+=(_shellapp_deferred_init)
}

# --- messaging ---------------------------------------------------------------

_shellapp_esc() {
    REPLY=${1//\\/\\\\}
    REPLY=${REPLY//$'\n'/\\n}
    REPLY=${REPLY//$'\t'/\\t}
}

# _shellapp_send TYPE [FIELD...] — one record over a fresh connection.
_shellapp_send() {
    [[ -S $_shellapp_sock ]] || builtin return 0
    local msg=$1 f fd
    builtin shift
    msg+=$'\t'$_shellapp_sid
    for f in "$@"; do
        _shellapp_esc "$f"
        msg+=$'\t'$REPLY
    done
    builtin zsocket $_shellapp_sock 2>/dev/null || builtin return 0
    fd=$REPLY
    builtin print -r -u $fd -- "$msg"
    builtin exec {fd}>&-
}

# --- prompt state --------------------------------------------------------------

# Finds the current git branch without forking (reads .git/HEAD).
_shellapp_git_branch() {
    local dir=$PWD gitdir= head= line=
    while :; do
        if [[ -f $dir/.git/HEAD ]]; then
            gitdir=$dir/.git
            builtin break
        elif [[ -f $dir/.git ]]; then
            builtin read -r line < $dir/.git 2>/dev/null
            gitdir=${line#gitdir: }
            [[ $gitdir == /* ]] || gitdir=$dir/$gitdir
            builtin break
        fi
        [[ -z $dir || $dir == / ]] && builtin return 1
        dir=${dir:h}
    done
    [[ -r $gitdir/HEAD ]] || builtin return 1
    builtin read -r head < $gitdir/HEAD 2>/dev/null
    if [[ $head == 'ref: refs/heads/'* ]]; then
        REPLY=${head#ref: refs/heads/}
    else
        REPLY=${head[1,7]}
    fi
}

# What the terminal shows at the prompt.
#
# _shellapp_block_ps/_rps is how an executed command line looks in
# scrollback: Shell's compact header, or the user's own theme prompt.
#
# With the input editor on there must be ONE place to type: the live prompt
# is hidden (no text, no cursor) and the block prompt is swapped in only when
# a command is accepted — a transient prompt — so scrollback still reads as
# "header ❯ command" followed by output.
_shellapp_apply_prompt() {
    # Capture the theme's prompt unless the current one is ours.
    if [[ $PROMPT != *$_shellapp_marker* ]]; then
        _shellapp_saved_ps1=$PROMPT
        _shellapp_saved_rps1=$RPROMPT
        _shellapp_have_saved=1
    fi

    local show=$'%{\e[?25h%}' hide=$'%{\e[?25l%}'
    if [[ $_shellapp_prompt_style == compact ]]; then
        local b=${_shellapp_branch//\%/%%} sep= bpart=
        [[ -n $b ]] && bpart=" %F{5}${b}%f"
        (( _shellapp_prompt_count > 0 )) && sep=$'\n'
        _shellapp_block_ps="${sep}${_shellapp_marker}${show}%F{4}%~%f${bpart} %F{2}❯%f "
        _shellapp_block_rps=
    else
        _shellapp_block_ps="${_shellapp_marker}${show}${_shellapp_saved_ps1}"
        _shellapp_block_rps=$_shellapp_saved_rps1
    fi

    if (( _shellapp_editor )); then
        PROMPT="${_shellapp_marker}${hide}"
        RPROMPT=
    elif [[ $_shellapp_prompt_style == compact ]]; then
        PROMPT=$_shellapp_block_ps
        RPROMPT=
    elif [[ $PROMPT == *$_shellapp_marker* ]] && (( _shellapp_have_saved )); then
        PROMPT=$_shellapp_saved_ps1
        RPROMPT=$_shellapp_saved_rps1
    fi
}

_shellapp_precmd() {
    local ret=$? dur=
    if [[ -n $_shellapp_cmd_start ]]; then
        dur=$(( EPOCHREALTIME - _shellapp_cmd_start ))
        # The header no longer turns red, so mark failures in the output.
        if (( _shellapp_editor )) && [[ $ret != 0 ]]; then
            builtin print -P "%F{1}✗ exit ${ret}%f"
        fi
    else
        ret=
    fi
    _shellapp_cmd_start=
    _shellapp_branch=
    _shellapp_git_branch && _shellapp_branch=$REPLY
    _shellapp_apply_prompt "$ret"
    (( _shellapp_prompt_count++ ))
    _shellapp_send prompt "$ret" "$PWD" "$_shellapp_branch" "$dur"
}

_shellapp_preexec() {
    _shellapp_cmd_start=$EPOCHREALTIME
    # The idle prompt hid the cursor; programs need it back.
    builtin print -n $'\e[?25h'
    _shellapp_send exec "$1" "$PWD"
}

# --- widgets -----------------------------------------------------------------

_shellapp_run_widget() {
    local f=$_shellapp_rt/$_shellapp_sid.cmd
    [[ -r $f ]] || builtin return 0
    BUFFER=$(<$f)
    : >| $f
    CURSOR=$#BUFFER
    if (( _shellapp_editor )); then
        # Transient prompt: redraw the hidden idle prompt as the block header
        # so scrollback shows "header ❯ command".
        PROMPT=$_shellapp_block_ps
        RPROMPT=$_shellapp_block_rps
        zle reset-prompt
    fi
    zle accept-line
}

_shellapp_configure_widget() {
    local f=$_shellapp_rt/$_shellapp_sid.cfg line
    [[ -r $f ]] || builtin return 0
    for line in "${(@f)$(<$f)}"; do
        case $line in
            prompt=*) _shellapp_prompt_style=${line#prompt=} ;;
            editor=*) _shellapp_editor=${line#editor=} ;;
            claude=*) _shellapp_claude_mode=${line#claude=} ;;
            claude_rc=*) _shellapp_claude_rc=${line#claude_rc=} ;;
        esac
    done
    _shellapp_apply_prompt ""
    zle reset-prompt
}

# compadd replacement used while capturing: records matches instead of
# adding them, so nothing is inserted or listed in the terminal.
_shellapp_compadd() {
    # Calls that only fill arrays for the caller pass straight through.
    if [[ ${@[1,(i)(-|--)]} == *-(O|A|D)\ * ]]; then
        builtin compadd "$@"
        builtin return $?
    fi

    local -a __hits __dscr __P __p __S __s __Q __f __slash __W
    local __tmp
    if (( $@[(I)-d] )); then
        __tmp=${@[$[${@[(i)-d]}+1]]}
        if [[ $__tmp == \(* ]]; then
            builtin eval "__dscr=$__tmp"
        else
            __dscr=( "${(@P)__tmp}" )
        fi
    fi
    builtin compadd -A __hits -D __dscr "$@"
    local ret=$?
    (( $#__hits )) || builtin return $ret

    builtin setopt localoptions norcexpandparam extendedglob nonomatch
    builtin zparseopts -E P:=__P p:=__p S:=__S s:=__s Q=__Q f=__f /=__slash W:=__W 2>/dev/null
    local apre=${__P[2]} hpre=${__p[2]} hsuf=${__s[2]} wdir=${__W[2]}
    local tag=${curtag:-} i hit ins d flags p
    for (( i = 1; i <= $#__hits; i++ )); do
        (( $#_shellapp_out > 400 )) && builtin break
        hit=$__hits[i]
        if (( $#__Q )); then ins=$hit; else ins=${(q)hit}; fi
        ins=$IPREFIX$apre$hpre$ins$hsuf
        flags=
        if (( $#__f || $#__slash )); then
            flags=f
            p=$apre$hpre$hit
            [[ -n $wdir && $p != /* && $p != '~'* ]] && p=$wdir/$p
            [[ -d ${~p} ]] 2>/dev/null && flags=d
        fi
        d=
        if (( $#__dscr >= i )); then
            d=${__dscr[i]}
            d=${d#${(b)hit}}
            d=${d##[[:space:]]#}
            d=${d#--}
            d=${d#:}
            d=${d##[[:space:]]#}
        fi
        _shellapp_esc "$ins";   ins=$REPLY
        _shellapp_esc "$hit";   hit=$REPLY
        _shellapp_esc "$d";     d=$REPLY
        _shellapp_out+=("m"$'\t'"$ins"$'\t'"$hit"$'\t'"$d"$'\t'"$tag"$'\t'"$flags")
    done
    builtin return $ret
}

_shellapp_comppost() {
    compstate[insert]=''
    compstate[list]=''
}

_shellapp_complete_widget() {
    local f=$_shellapp_rt/$_shellapp_sid.req
    [[ -r $f ]] || builtin return 0
    local req=$(<$f)
    local reqid=${req%%$'\n'*} buf=
    [[ $req == *$'\n'* ]] && buf=${req#*$'\n'}

    local obuf=$BUFFER ocur=$CURSOR saved_compadd=
    _shellapp_out=()
    (( $+functions[compadd] )) && saved_compadd=$functions[compadd]
    functions[compadd]=$functions[_shellapp_compadd]
    {
        builtin setopt localoptions nobeep nolistbeep
        local -a comppostfuncs
        comppostfuncs=(_shellapp_comppost)
        BUFFER=$buf
        CURSOR=$#BUFFER
        zle _shellapp_complete_word 2>/dev/null
    } always {
        if [[ -n $saved_compadd ]]; then
            functions[compadd]=$saved_compadd
        else
            builtin unfunction compadd 2>/dev/null
        fi
        BUFFER=$obuf
        CURSOR=$ocur
    }

    [[ -S $_shellapp_sock ]] || builtin return 0
    local fd
    builtin zsocket $_shellapp_sock 2>/dev/null || builtin return 0
    fd=$REPLY
    builtin print -r -u $fd -- "comp"$'\t'"$_shellapp_sid"$'\t'"$reqid"
    (( $#_shellapp_out )) && builtin print -r -u $fd -- "${(pj:\n:)_shellapp_out}"
    builtin exec {fd}>&-
    _shellapp_out=()
    zle -R
}

# --- claude ------------------------------------------------------------------

# `claude` asks the app whether to open Shell's native view or Claude Code's
# terminal UI. The app decides from the arguments (print mode, subcommands and
# pickers always use the terminal) and the saved preference, asking the user
# if needed, then writes its answer to <id>.claude. The shell's exported
# environment goes to <id>.env so the native process sees the same PATH,
# credentials and provider settings as a terminal launch would.
_shellapp_claude() {
    builtin emulate -L zsh -o no_aliases
    local bin=${commands[claude]}
    # With Remote Control on, the app still decides which launches get --remote-control.
    if [[ -z $bin || ( $_shellapp_claude_mode == terminal && $_shellapp_claude_rc == 0 ) || ! -t 0 || ! -t 1 || ! -S $_shellapp_sock ]] ||
        (( ! $+builtins[zselect] )); then
        builtin command claude "$@"
        builtin return
    fi
    local reply=$_shellapp_rt/$_shellapp_sid.claude env=$_shellapp_rt/$_shellapp_sid.env k ans= i
    : >| $reply
    {
        for k in ${(k)parameters[(R)*export*]}; do
            builtin print -rn -- "$k=${(P)k}"$'\0'
        done
    } >| $env
    _shellapp_send claude "$PWD" "$bin" "$@"
    # Wait for the answer (the app may be showing a choice sheet).
    for (( i = 0; i < 60000; i++ )); do
        [[ -s $reply ]] && builtin break
        zselect -t 2 2>/dev/null
    done
    [[ -s $reply ]] && ans=$(<$reply)
    : >| $reply
    case $ans in
        native) builtin return 0 ;;
        cancel) builtin return 130 ;;
        terminal-rc) builtin command claude "$@" --remote-control ;;
        *) builtin command claude "$@" ;;
    esac
}

# Restarts this shell (to pick up .zshrc changes) while keeping Shell's
# integration: re-enter through our ZDOTDIR bootstrap.
_shellapp_reload() {
    [[ -n $SHELL_APP_ZDOTDIR ]] || { builtin exec zsh -l; }
    if [[ -n $ZDOTDIR && $ZDOTDIR != $SHELL_APP_ZDOTDIR ]]; then
        builtin export SHELL_APP_ORIG_ZDOTDIR=$ZDOTDIR
    fi
    builtin export ZDOTDIR=$SHELL_APP_ZDOTDIR
    builtin exec zsh -l
}

# --- setup after .zshrc ------------------------------------------------------

_shellapp_deferred_init() {
    builtin emulate -L zsh -o no_aliases
    precmd_functions=(${precmd_functions:#_shellapp_deferred_init})

    # Run our precmd just before Ghostty's so it can wrap our prompt with
    # OSC 133 marks, and after everything else (themes set PROMPT in precmd).
    local idx=${precmd_functions[(I)_ghostty_precmd]}
    if (( idx )); then
        precmd_functions[idx,idx-1]=(_shellapp_precmd)
    else
        precmd_functions+=(_shellapp_precmd)
    fi
    preexec_functions+=(_shellapp_preexec)

    # Completion capture needs the new completion system.
    if (( ! $+functions[compdef] )); then
        builtin autoload -Uz compinit
        compinit -C -d "${XDG_CACHE_HOME:-$HOME/.cache}/shellapp-zcompdump-$ZSH_VERSION" 2>/dev/null
    fi

    # A private completion widget wired straight to compsys, so user
    # rebinds of complete-word (menus, fzf-tab…) don't affect capture.
    zle -C _shellapp_complete_word .complete-word _main_complete
    zle -N _shellapp_run_widget
    zle -N _shellapp_complete_widget
    zle -N _shellapp_configure_widget
    local km
    for km in emacs viins vicmd; do
        builtin bindkey -M $km $'\e[9001~' _shellapp_run_widget
        builtin bindkey -M $km $'\e[9002~' _shellapp_complete_widget
        builtin bindkey -M $km $'\e[9003~' _shellapp_configure_widget
    done
    builtin typeset -ga ZSH_AUTOSUGGEST_IGNORE_WIDGETS
    ZSH_AUTOSUGGEST_IGNORE_WIDGETS+=(_shellapp_run_widget _shellapp_complete_widget _shellapp_configure_widget)

    (( $+functions[claude] )) || claude() { _shellapp_claude "$@"; }

    _shellapp_send init "${HISTFILE:-}" "$ZSH_VERSION" "${ZSH:-}" "${ZSH_THEME:-}" "$PATH" \
        "${(j: :)${(k)aliases}}" "${(j: :)${${(k)functions}:#[_.-+]*}}"
    _shellapp_precmd
}

_shellapp_boot
builtin unfunction _shellapp_boot
