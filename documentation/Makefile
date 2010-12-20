.PHONY: all dotfiles

all: dotfiles

dotfiles: sup_tree_20101220.png sup_tree_20101220.pdf

clean:
	rm -f sup_tree_20101220.png
	rm -f sup_tree_20101220.pdf
	rm -f sup_tree_20101220.dot

%.dot: %.m4
	m4 $< > $@

%.png: %.dot
	dot -Tpng $< > $@

%.pdf: %.dot
	dot -Tpdf $< > $@
