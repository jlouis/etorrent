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
     "latex2e"
     "rep10"
     "report"
     "a4paper")))

