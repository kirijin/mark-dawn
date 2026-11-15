<!-- page 1 -->

# Introduction

Document conversion pipelines lose structure at every stage, and the loss is rarely visible until retrieval quality drops. This chapter states the problem in terms a maintainer can test.

<!-- page 2 -->

# Method

We normalise the document in six deterministic stages, each of which is independently testable and free of model inference. Page boundaries survive as HTML comments rather than headings, so the heading tree reflects the document's own ontology.

<!-- page 3 -->

# Results

Running headers and footers are detected by repetition across pages, then removed before paragraph reconstruction runs. Hard-wrapped lines are joined into semantic paragraphs.

<!-- page 4 -->

# Discussion

The gate reports findings as codes, not prose, so a CI job can fail on structure without failing on style. _Figure 1  Pipeline stages and their failure modes._
