.PHONY: all dotfiles

all: dotfiles

dotfiles: sup_tree_20110106.png sup_tree_20110106.pdf utp.pdf

clean:
	rm -f sup_tree_20110106.png
	rm -f sup_tree_20110106.pdf
	rm -f sup_tree_20110106.dot

%.dot: %.m4
	m4 $< > $@

%.png: %.dot
	dot -Tpng $< > $@

%.pdf: %.dot
	dot -Tpdf $< > $@
