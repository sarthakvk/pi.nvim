# Intent: a human-involved coding harness

I want an agent harness that works *with* my editor rather than taking coding
away from it.

The goal is not autonomous code generation, nor an editor filled with AI
controls. The goal is to stay involved: to understand the code, guide the work,
see what changes, and review decisions while the harness provides investigation,
implementation, and another set of eyes.

## What this should enable

- Neovim remains the primary place where I read, navigate, and make sense of
  code.
- I can select code and attach notes, questions, concerns, or constraints for
  the harness to consider.
- Those notes are editor/review metadata, not source-code comments by default.
- The harness can directly receive the relevant selection and its associated
  note, rather than relying on me to manually restate context.
- Proposed changes are visible and reviewable before they become accepted work.
- I can accept, reject, refine, or discuss individual changes while preserving
  the surrounding conversation and reasoning.
- The harness can return review findings as inline editor annotations without
  changing the source file.
- The editor stays quiet and minimal when this workflow is not being used.

## Relationship with the harness

The harness should be a collaborator with tools, not a black box that owns the
working tree. It may inspect, reason, propose, and carry out work, but I should
be able to observe and intervene at meaningful points.

I want a middle ground between two unsatisfying extremes:

- the harness makes all changes while I only inspect the result afterwards;
- I make every change manually and the harness only answers questions.

## Constraints and preferences

- Reuse the authenticated harness I already use, rather than requiring a
  separate API key or committing to a particular model vendor.
- Keep the integration local and editor-oriented.
- Preserve a minimal Neovim interface; agent and review surfaces should be
  invoked when needed rather than permanently occupying the screen.
- Keep human notes and agent review comments separate from production source by
  default.
- Treat visibility, review, and understanding as first-class requirements, not
  optional polish added after automation.

## Still open

This document records intent, not a design or implementation plan. The transport
between editor and harness, the representation and persistence of annotations,
the review UI, permissions, and the exact scope of agent autonomy are all open
questions.
