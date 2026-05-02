FISH_COMPLETIONS_DIR := $(HOME)/.config/fish/completions

.PHONY: install
install: pm completions/pm.fish
	cp pm ~/.local/bin
	mkdir -p $(FISH_COMPLETIONS_DIR)
	cp completions/pm.fish $(FISH_COMPLETIONS_DIR)/pm.fish
