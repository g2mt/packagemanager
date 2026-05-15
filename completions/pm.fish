# Fish shell completions for pm

# Disable file completions for the main command
complete -c pm -f

# Helper to get package names from `pm list --names`
function __pm_packages
    pm list --names 2>/dev/null
end

# Global options (also available before subcommand)
complete -c pm -n 'not __fish_seen_subcommand_from install update list docs clean edit list-files uninstall' -l config -d 'Path to the config file' -r
complete -c pm -n 'not __fish_seen_subcommand_from install update list docs clean edit list-files uninstall' -l skip-downloads -d 'Skip any actual downloads'

# Subcommands
complete -c pm -n 'not __fish_seen_subcommand_from install update list docs clean edit list-files uninstall' -a install -d 'Install given packages'
complete -c pm -n 'not __fish_seen_subcommand_from install update list docs clean edit list-files uninstall' -a update -d 'Update cached versions of packages'
complete -c pm -n 'not __fish_seen_subcommand_from install update list docs clean edit list-files uninstall' -a list -d 'List all packages with versions'
complete -c pm -n 'not __fish_seen_subcommand_from install update list docs clean edit list-files uninstall' -a docs -d 'Show documentation for Package and Manager classes'
complete -c pm -n 'not __fish_seen_subcommand_from install update list docs clean edit list-files uninstall' -a clean -d 'Delete all files marked for deletion'
complete -c pm -n 'not __fish_seen_subcommand_from install update list docs clean edit list-files uninstall' -a edit -d 'Open the config file in $EDITOR'
complete -c pm -n 'not __fish_seen_subcommand_from install update list docs clean edit list-files uninstall' -a list-files -d 'List installed files for given packages'
complete -c pm -n 'not __fish_seen_subcommand_from install update list docs clean edit list-files uninstall' -a uninstall -d 'Remove all installed files and package directory'

# install options
complete -c pm -n '__fish_seen_subcommand_from install' -a '(__pm_packages)' -d 'Package'
complete -c pm -n '__fish_seen_subcommand_from install' -s t -l tag -d 'Filter by tag' -r
complete -c pm -n '__fish_seen_subcommand_from install' -s f -l force -d 'Force reinstall even if version unchanged'
complete -c pm -n '__fish_seen_subcommand_from install' -s i -l interactive -d 'Prompt before executing any process during install'

# update options
complete -c pm -n '__fish_seen_subcommand_from update' -a '(__pm_packages)' -d 'Package'
complete -c pm -n '__fish_seen_subcommand_from update' -s t -l tag -d 'Filter by tag' -r
complete -c pm -n '__fish_seen_subcommand_from update' -l installed -d 'Only update installed packages'

# list options
complete -c pm -n '__fish_seen_subcommand_from list' -l installed -d 'Only show installed packages'
complete -c pm -n '__fish_seen_subcommand_from list' -l not-installed -d 'Only show packages that are not installed'
complete -c pm -n '__fish_seen_subcommand_from list' -l names -d 'Print only package names'

# list-files options
complete -c pm -n '__fish_seen_subcommand_from list-files' -a '(__pm_packages)' -d 'Package'

# uninstall options
complete -c pm -n '__fish_seen_subcommand_from uninstall' -a '(__pm_packages)' -d 'Package'
complete -c pm -n '__fish_seen_subcommand_from uninstall' -s f -l force -d 'Force uninstall without prompting'
