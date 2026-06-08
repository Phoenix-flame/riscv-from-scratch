# RISC-V CPU Core Documentation - LaTeX Multi-File Project

This folder contains a multi-file LaTeX conversion of the concept-first Markdown documentation.

## Structure

- `main.tex`: master LaTeX file
- `sections/*.tex`: one file per major documentation section

## Compile

From this directory:

```bash
pdflatex -interaction=nonstopmode main.tex
pdflatex -interaction=nonstopmode main.tex
```

Running twice updates the table of contents.

## Notes

- Markdown tables were converted to `longtable`.
- Code blocks and Mermaid diagrams were preserved as `lstlisting`.
- Mermaid diagrams are not rendered as graphics; their source is preserved for readability.
