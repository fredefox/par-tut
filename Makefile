PROJECT = par-tut
TEX = $(PROJECT).tex
PDF = $(PROJECT).pdf
MAIN = ParTut
SOURCE = $(MAIN).lhs
LATEX_CMD = xelatex -interaction=nonstopmode
EXE = ./$(MAIN)

preview: report
	xdg-open $(PDF)

report: $(PDF)

$(PDF): $(SOURCE) *.tex
	pandoc $(SOURCE) \
		-o $(PDF) \
		--latex-engine=xelatex \
		--variable urlcolor=cyan \
		-V papersize:a4 \
		-V geometry:margin=1.5in

github: README.md

README.md: $(SOURCE)
	pandoc $(SOURCE) \
		-o README.md

run: build
	$(EXE) +RTS \
		-N4 \
		-ls \
		-lf 

build: $(MAIN)

$(MAIN): *.lhs
	ghc $(SOURCE) \
		-main-is $(MAIN) \
		-debug \
		-threaded \
		-rtsopts

dist: report
	tar \
		--transform "s/^/$(PROJECT)\//" \
		-zcvf $(PROJECT).tar.gz \
		$(SOURCE) \
		Makefile \
		$(PDF)
