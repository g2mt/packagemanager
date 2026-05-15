# Bash completions for pm

__pm_packages() {
    pm list --names 2>/dev/null
}

_pm() {
    local cur prev words cword
    _init_completion || return

    local subcommands="install update list docs clean edit list-files uninstall"
    local global_opts="--config --skip-downloads"
    local install_opts="-t --tag -f --force -i --interactive"
    local update_opts="-t --tag --installed"
    local list_opts="--installed --not-installed --names"

    if [[ $cword -eq 1 ]]; then
        if [[ "$cur" == -* ]]; then
            COMPREPLY=($(compgen -W "$global_opts" -- "$cur"))
        else
            COMPREPLY=($(compgen -W "$subcommands" -- "$cur"))
        fi
        return
    fi

    local prev_subcmd=
    for ((i=1; i<cword; i++)); do
        if [[ ! "${words[i]}" == -* ]]; then
            prev_subcmd="${words[i]}"
        fi
    done

    case "$prev_subcmd" in
        install|update)
            case "$prev" in
                install|update|-t|--tag)
                    COMPREPLY=($(compgen -W "$(__pm_packages)" -- "$cur"))
                    return
                    ;;
            esac
            case "$prev_subcmd" in
                install)
                    COMPREPLY=($(compgen -W "$install_opts $(__pm_packages)" -- "$cur"))
                    ;;
                update)
                    COMPREPLY=($(compgen -W "$update_opts $(__pm_packages)" -- "$cur"))
                    ;;
            esac
            ;;
        list)
            COMPREPLY=($(compgen -W "$list_opts" -- "$cur"))
            ;;
        docs|clean|edit|list-files|uninstall)
            case "$prev_subcmd" in
                list-files|uninstall)
                    COMPREPLY=($(compgen -W "$(__pm_packages)" -- "$cur"))
                    ;;
                *)
                    COMPREPLY=()
                    ;;
            esac
            ;;
        *)
            COMPREPLY=($(compgen -W "$global_opts $subcommands" -- "$cur"))
            ;;
    esac
} &&
    complete -F _pm pm
