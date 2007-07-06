(TeX-add-style-hook "documentation"
 (lambda ()
    (LaTeX-add-environments
     "theorem"
     "lemma"
     "example"
     "remark")
    (LaTeX-add-labels
     "chap:requirements")
    (TeX-run-style-hooks
     "amssymb"
     "amsmath"
     "microtype"
     "charter"
     "fontenc"
     "T1"
     "latex2e"
     "memoir10"
     "memoir"
     "a4paper")))

