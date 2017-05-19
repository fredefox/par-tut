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

run: build
	$(EXE) +RTS \
		-N4 \
		-ls \
		-lf 

build: $(MAIN)

$(MAIN): *.hs *.lhs
	ghc $(SOURCE) \
		-main-is $(MAIN) \
		-debug \
		-threaded \
		-rtsopts
