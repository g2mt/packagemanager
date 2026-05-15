.PHONY: install
install: pm
	cp pm ~/.local/bin

FISH_COMPLETIONS_DIR := $(HOME)/.config/fish/completions
.PHONY: install_completions_fish
install_completions_fish:
	mkdir -p $(FISH_COMPLETIONS_DIR)
	cp completions/pm.fish $(FISH_COMPLETIONS_DIR)/pm.fish

BASH_COMPLETIONS_DIR := $(HOME)/.bash-completion
.PHONY: install_completions_bash
install_completions_bash:
	mkdir -p $(BASH_COMPLETIONS_DIR)
	cp completions/pm.bash $(BASH_COMPLETIONS_DIR)/pm

.PHONY: install_completions
install_completions: install_completions_fish install_completions_bash
