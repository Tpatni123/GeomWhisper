---
title: "GeomWhisper: conversational and voice-driven refinement of ggplot visualizations"
tags:
  - R
  - Shiny
  - ggplot2
  - data visualization
  - large language models
  - voice interface
authors:
  - name: Tushar Patni
    # orcid: 0000-0000-0000-0000   # TODO: add ORCID before submission
    corresponding: true
    affiliation: 1
  - name: Jade Wang
    # orcid: 0000-0000-0000-0000   # TODO: add ORCID before submission
    affiliation: 2
  - name: Yimei Li
    # orcid: 0000-0000-0000-0000   # TODO: add ORCID before submission
    affiliation: 1
affiliations:
  - index: 1
    name: St. Jude Children's Research Hospital, United States
  - index: 2
    name: Department of Statistics, Texas A&M University, United States
date: 23 May 2026
bibliography: paper/paper.bib
---

# Summary

Researchers often need to iterate quickly on statistical graphics while talking
through revisions with clinical or scientific collaborators. In practice, small
changes to colors, annotations, smoothing layers, faceting, themes, or chart
types frequently require repeated back-and-forth between a subject-matter expert
and a statistical programmer or biostatistician editing `ggplot2` code
[@wickham2016ggplot2].

GeomWhisper is a locally runnable Shiny application that shortens this loop by
letting users speak or type natural-language requests to modify a `ggplot2`
visualization [@shiny]. The application combines browser-based speech capture,
a multi-provider large language model (LLM) layer built on `ellmer`
[@ellmer2025], and an R tool-calling pipeline that converts user requests into
plot-editing code and updates the visualization through a streaming chat
interface provided by `shinychat` [@shinychat2026]. GeomWhisper is intended for
researchers, scientists, and doctors who need a lower-friction way to refine
figures during collaborative analysis sessions, including teams whose analyses
use `ggplot2`.

# Statement of need

`ggplot2` is widely used in research because it is expressive, reproducible, and
well integrated with data-analysis workflows in R [@wickham2016ggplot2]. Those
same strengths create a practical bottleneck in collaborative figure review.
When a clinician, scientist, or domain collaborator wants to try a different
title, color mapping, smoother, facet variable, or plot type, the change often
depends on direct code edits rather than on the collaborator's own domain
language. This can slow down exploratory work and shift figure refinement into a
serial workflow mediated by the analyst.

GeomWhisper addresses this problem in three complementary ways. First, it ships
as a standalone Windows application with a self-contained installer and launcher
that automatically provisions the R runtime, when needed, and required R
packages in the background. Users do not need to install, open, or use RStudio,
or manage R packages manually; uploading an R script and a data file is
sufficient to produce and refine a publication-quality `ggplot2` figure.
Second, by giving subject-matter experts a direct conversational interface for
requesting changes, it removes the dependency on a biostatistician or
statistical programmer as an intermediary for every incremental revision.
Rather than the current serial workflow—where a collaborator describes a
desired change, an analyst implements it in code, and the updated figure is
returned for review—researchers can request and see the change in the same
conversation, reducing a multi-step relay to a single spoken or typed request.
Third, uploaded datasets remain in the local R session. The standard LLM prompt
does not automatically include data-frame values; it supplies the user's request
and current plot code instead. This prompt-minimization design supports clinical
workflows where sharing patient-level records with external services is often
prohibited or requires burdensome governance approval.

Existing language-assisted and GUI-based tools lower the syntax barrier, but
they usually assume that the person invoking them is already operating inside
the R ecosystem: installing a package, configuring an API key, launching a
Shiny app, or working in an editor such as RStudio or Positron
[@ggplotwithyourdata2026; @ggbot22026; @ggx2021]. GeomWhisper instead targets
collaborators who may never open an IDE at all.

The software is designed for researchers, scientists, and doctors working with
teams whose analyses use R graphics, but who want a faster conversational layer
for changing plots during analysis review, figure design, or collaborative
interpretation. In ongoing use, the software has been applied in collaborative
work involving oncologists, radiation therapists, and other scientific
researchers, where rapid plot revision is valuable for both analysis discussion
and figure preparation.

# State of the field

Researchers already have several ways to lower the barrier to working with
`ggplot2` graphics. GUI-based builders such as `esquisse` [@esquisse2026] and
the earlier Shiny application `ggplotwithyourdata` [@ggplotwithyourdata2026]
let users upload data, choose geoms, adjust mappings, and export plots through
widgets rather than code. These tools reduce syntax burden, but they are
centered on GUI-driven plot construction and option selection, not
conversational revision of a user-supplied plotting script that is already under
discussion.

At the other end of the spectrum, `ggx` [@ggx2021] provides a natural-language
interface to common `ggplot2` styling operations such as hiding legends or
rotating axis labels. Its design is intentionally lightweight: it uses keyword
matching rather than an LLM and serves mainly as a helper for users already
writing `ggplot2` code, not as a live multi-turn application with voice input,
maintained plot state, or local tool-calling.

A recent experimental package, `ggbot2` [@ggbot22026], comes closest to
GeomWhisper in interaction style. It launches a Shiny app that lets users create
and modify plots with spoken or typed commands, but its documented workflow
assumes an R user who can install the package, configure an OpenAI API key, and
launch the app from an active R session.

Generic LLM interfaces such as ChatGPT [@chatgpt2026] can also propose plotting
code, but they operate outside the local R session, do not preserve the exact
live plot state under review, and cannot be tested by a reviewer as a
self-contained application.

GeomWhisper sits within this emerging ecosystem but targets a narrower and more
operationally constrained use case. We are not aware of another open-source
tool that combines local-first execution where raw data stay on the user's
machine, multi-provider routing including local models, live editing of
user-supplied `ggplot2` code inside a running Shiny session, both voice and
typed chat interaction, and installer-based desktop distribution for
collaborators who may not use R or RStudio.

# Software design

GeomWhisper follows a local-first architecture in which the user interface,
dataset context, and plot rendering remain inside a Shiny session while the LLM
is used only to propose plot modifications. The standard LLM context contains
the user's request and current plot code, rather than automatically including
uploaded data-frame values. This prompt-minimization boundary protects the
underlying dataset, eliminates round-trips to external rendering services, and
makes the running session directly testable by a reviewer.

**Conversation and voice interface.** Browser speech input is handled through
the Web Speech API via a JavaScript layer that sends voice transcripts to the
Shiny server as custom messages. Typed chat is rendered as streaming chat bubbles
through the `shinychat` package [@shinychat2026] without blocking the Shiny
event loop. This separation between input modality and rendering was an explicit
design choice: voice improves collaborator-facing interaction while typed input
preserves accessibility in non-voice environments such as review settings.

**Multi-provider LLM routing.** The application uses `ellmer` as the LLM
abstraction layer, supporting OpenAI, Anthropic, Google Gemini, and local Ollama
models [@ellmer2025]. This choice lets teams select a provider appropriate to
their cost and connectivity constraints; locally running Ollama models offer a
cost-efficient option when cloud access is unavailable or undesirable. The same
prompt-minimization boundary protects raw data regardless of the selected
provider. A persistent conversation object is created per session and retains
the full multi-turn message history so the LLM can interpret follow-on requests
in context. Provider and model selections are persisted across sessions.

**Plot evaluation pipeline.** When the LLM generates revised R code via a
tool-calling response, it is evaluated in an isolated environment that
automatically collects all `ggplot`, `patchwork`, and `ggbreak` objects produced
during execution. Warning management uses a resumable-handler strategy so that
packages which issue warnings mid-execution and expect to continue are not
prematurely aborted—an important consideration when working with complex
visualization packages. A runtime compatibility shim handles a known interaction
between `ggbreak`'s internal call-stack inspection and the tool dispatcher's
closure context, and a garbage-collection retry path recovers from state-
corruption errors without requiring user intervention.

**Multi-plot support and per-plot isolation.** When a script defines multiple
named plot objects, the application splits it into a shared preamble (library
calls, data loading, transformations) and individual per-plot code blocks. The
LLM is given only the active plot's block to revise; the modified block is then
spliced back into the full script before re-evaluation. This isolation prevents
a change to one figure from inadvertently corrupting others.

**Diff-feedback loop and statistical-change annotation.** After a successful
update, the application computes a line-level diff between the previous and
newly generated plot code and includes it in the tool-call response returned to
the LLM. A rule embedded in this response prompts the LLM to surface a visible
warning if the diff touches geom type, aesthetic mappings, statistical methods,
or data filters—changes that can affect the scientific interpretation of the
figure.

**Journal style skills.** Users can upload a plain-text figure-style guide that
is injected into the LLM system prompt, ensuring generated code conforms to
publication-specific requirements. Bundled templates for APA 7th edition and
Nature figure requirements are included in the repository.

**Reproducibility controls.** The application maintains a 20-item code history
for undo behavior and supports reset to a known default plot. The repository
includes an offline smoke test (`tests/offline_smoke.R`) that validates core
helper functions without requiring live API keys. End-to-end LLM-dependent
behavior requires a live provider key; the offline test documents which helpers
are independently verifiable.

**Installation and resilience.** A Windows installer and PowerShell launcher
manage the full bootstrapping sequence for users who may not administer R
directly: they detect the installed R version, terminate any stale server
process occupying the application port, install missing packages by cycling
through multiple CRAN mirrors with an automatic fallback from pre-compiled
binary packages to source builds, and migrate stored provider configurations
from earlier versions without user intervention. A direct `shiny::runApp()` call
remains available for all platforms.

The screenshots below show a complete running example. On launch, GeomWhisper
displays its bundled `mtcars` scatter plot (Figure 1). A user then enters a
request to recolor the points and update the title (Figure 2). The application
evaluates the revision and refreshes the plot preview; the chat reports the
applied changes (Figure 3).

![Figure 1. Initial GeomWhisper session with the default `mtcars` scatter plot.
The left panel shows the active provider, voice shortcut, chat input, and dataset
controls.](paper/images/geomwhisper_initial_state.png)

![Figure 2. A typed request asks GeomWhisper to change the point color to dark
orange and update the plot title.](paper/images/geomwhisper_change_request.png)

![Figure 3. The completed request: the preview shows dark-orange points and the
revised title, while the chat reports the changes applied.](paper/images/geomwhisper_change_applied.png)

# Research impact statement

GeomWhisper's research impact is to keep figure refinement inside an R-based
workflow while making routine plot changes accessible through natural-language
interaction. Rather than moving figure work to a separate chat interface and
manually copying generated code back into an analysis, the application evaluates
requested revisions in the active Shiny session and updates the displayed
`ggplot2` figure directly. The session maintains an undoable history, allowing
collaborators to compare alternative figure revisions without having to write or
edit R code themselves.

The data-governance benefit comes from the application's prompt boundary, not
from the chosen provider: uploaded data-frame values remain local and are not
automatically included in standard LLM context. The multi-provider design has a
separate practical benefit: a locally running Ollama model offers a cost-
efficient option for teams with limited cloud access while retaining the same
conversational interface.

The immediate impact is workflow-level: the software lowers the amount of
direct code editing required for routine figure revisions while preserving an
R-based analysis environment. The repository supports reuse through an offline
smoke test, local launcher support, contribution guidance, and multi-provider
execution paths. These features allow research teams to evaluate the application
in their own analysis settings without requiring RStudio or embedding their
plotting workflow in an external chat service.

# AI usage disclosure

GitHub Copilot (Claude Sonnet 4.6) assisted with portions of software development,
documentation revision, repository preparation, and drafting support for this
manuscript. All AI-assisted outputs were reviewed, edited, and validated by the
human authors, who retained responsibility for the software design, the research
framing, and the correctness of the manuscript.

# Acknowledgements

The authors thank the collaborators whose figure-review workflows helped shape
the design goals for GeomWhisper, especially the need for fast, conversational
iteration on `ggplot2` figures during active research discussions.

# References