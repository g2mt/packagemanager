.PHONY: install
install: pm
	./pm install --skip-clean pm

.PHONY: install_completions
install_completions:
	./pm install --skip-clean pm-completions
