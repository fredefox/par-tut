PROJECT = par-tut
TEX = $(PROJECT).tex
PDF = $(PROJECT).pdf
SOURCE = ParTut.lhs
LATEX_CMD = xelatex -interaction=nonstopmode

preview: report
	xdg-open $(PDF)

report: $(PDF)

$(PDF): $(SOURCE) *.tex
	pandoc $(SOURCE) \
		-o $(PDF) \
		--latex-engine=xelatex \
		--variable urlcolor=cyan
