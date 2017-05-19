PROJECT = par-tut
TEX = $(PROJECT).tex
PDF = $(PROJECT).pdf
SOURCE = ParTut.lhs

preview: report
	xdg-open $(PDF)

report: $(PDF)

$(PDF): $(SOURCE)
	lhs2TeX $(SOURCE) -o $(TEX)
	xelatex $(TEX)

clean:
	rm \
		*.aux \
		*.log \
		*.pdf \
		*.ptb \
		*.tex

